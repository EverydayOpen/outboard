import Foundation

/// Folds the journal into `RelocationRecord`s: the one model every state and count on screen comes from (invariant I10).
/// Tolerant of unknown steps (they are skipped for the state and shown raw in the Activity screen) and of a torn last line (the
/// reader already dropped it, so the step simply has no record and recovery looks at the disk).
public enum RelocationFold {
    /// Newest first. A move whose `begin` line is missing is skipped: there is nothing to rebuild it from.
    ///
    /// `home` expands the `~` that the journal keeps in a setting's values (`defaultsWrites`, `defaultsRevert`); without it they stay as journaled.
    public static func records(from entries: [JournalEntry], home: String? = nil) -> [RelocationRecord] {
        var order: [String] = []
        var byMove: [String: [JournalEntry]] = [:]
        for e in entries where e.id != JournalSubject.app.moveID {
            if byMove[e.id] == nil { order.append(e.id) }
            byMove[e.id, default: []].append(e)
        }
        var out: [RelocationRecord] = []
        for id in order {
            guard let lines = byMove[id], let record = fold(lines, home: home) else { continue }
            out.append(record)
        }
        return out.sorted { a, b in
            a.createdAt != b.createdAt ? a.createdAt > b.createdAt : a.id > b.id
        }
    }

    private static func fold(_ lines: [JournalEntry], home: String?) -> RelocationRecord? {
        guard let begin = lines.first(where: { $0.moveStep == .begin && $0.plan != nil }), let plan = begin.plan else { return nil }
        var state = MoveState.planned
        var safety = SafetyCopyState.none
        var verification: VerificationSummary?
        var abort: AbortReason?
        var swappedAt: Date?, confirmedAt: Date?, trashedAt: Date?
        var parked = false
        var needsCheck = false
        var removal: RemovalKind?
        var rollbackStarted = false
        var last = JournalMark(step: .begin, phase: begin.phase, status: begin.status)
        var updatedAt = begin.ts
        var problems: [String] = []
        let names = [plan.recipeID: plan.recipeName]

        func addProblem(_ s: String) { if !problems.contains(s) { problems.append(s) } }

        let beginIndex = lines.firstIndex(of: begin)
        for (index, line) in lines.enumerated() where index != beginIndex {
            updatedAt = max(updatedAt, line.ts)
            if let step = line.moveStep { last = JournalMark(step: step, phase: line.phase, status: line.status) }
            let next = MoveMachine.apply(line, current: state)
            state = next.state
            if let problem = next.problem { addProblem(problem) }
            let ok = line.status == nil || line.status == .ok
            if line.isProblem || line.moveStep == nil { addProblem(ActivityText.entry(for: line, recipeNames: names).text) }
            guard let step = line.moveStep else { continue }
            switch (step, line.phase) {
            case (.setAside, .result) where ok: safety = .kept
            case (.undoSetAside, .result) where ok: safety = .none
            case (.trash, .result) where ok: safety = .inTrash; trashedAt = line.ts
            case (.swapped, .result) where ok: swappedAt = line.ts
            case (.confirm, .result) where ok: confirmedAt = line.ts
            case (.verify, .result) where ok: verification = line.verification ?? verification
            case (.abort, _): abort = line.abort ?? .unknown
            case (.park, .result) where ok:
                parked = true
                let kind = RemovalKind.fromParkNote(line.note)
                removal = kind
                needsCheck = kind.needsCheckBeforeReconnect
            case (.unpark, .result) where ok:
                parked = false
                needsCheck = false
                removal = nil
            case (.checkAndReconnect, .result) where ok: needsCheck = false
            case (.rollback, .intent): rollbackStarted = true
            default: break
            }
        }
        if state == .aborted || state == .rolledBack { safety = .none }
        if state == .returned || state == .aborted || state == .rolledBack { parked = false }
        if !parked { removal = nil }
        func expanded(_ writes: [DefaultsWrite]) -> [DefaultsWrite] {
            guard let home else { return writes }
            return writes.map { DefaultsWrite(key: $0.key, type: $0.type, value: PathText.expandTilde($0.value, home: home)) }
        }

        return RelocationRecord(
            id: begin.id, direction: plan.direction, recipeID: plan.recipeID, recipeVersion: plan.recipeVersion,
            recipeName: plan.recipeName, method: plan.method, risk: plan.risk, onDriveMissing: plan.onDriveMissing, state: state,
            macPath: plan.macPath, volume: plan.volume, relativePath: plan.relativePath, defaultsDomain: plan.defaultsDomain,
            defaultsWrites: expanded(plan.defaultsWrites), defaultsRevert: expanded(plan.defaultsRevert), logicalBytes: plan.logicalBytes,
            fileCount: plan.fileCount, safetyCopy: safety, verification: verification, abort: abort, last: last,
            createdAt: begin.ts, updatedAt: updatedAt, swappedAt: swappedAt, confirmedAt: confirmedAt, trashedAt: trashedAt,
            isParked: parked, needsCheckBeforeReconnect: needsCheck, removalKind: removal, groupID: plan.groupID, problems: problems,
            rollbackStarted: rollbackStarted)
    }

    /// Things Outboard created and did not delete: an incomplete copy, the published copy of a rolled-back move, the renamed original
    /// of a confirmed move, the drive copy left by a return, an item an app created in the gap. Newest first. Anything the journal
    /// shows as already moved to the Trash is left out.
    public static func leftovers(from entries: [JournalEntry], records: [RelocationRecord]) -> [Leftover] {
        var trashed: Set<String> = []
        var pendingTrashSrc: [String: String] = [:]
        var foreign: [String: [(path: String, at: Date)]] = [:]
        var copyStarted: Set<String> = []
        var published: Set<String> = []
        var pendingForeignTo: [String: String] = [:]
        for e in entries {
            switch (e.moveStep, e.phase) {
            case (.trash, .intent): pendingTrashSrc[e.id] = e.src.map(PathNorm.normalize)
            case (.trash, .result):
                if e.status == nil || e.status == .ok, let src = pendingTrashSrc[e.id] { trashed.insert(e.id + "|" + src) }
            case (.copy, .intent): copyStarted.insert(e.id)
            case (.publish, .result) where e.status == nil || e.status == .ok: published.insert(e.id)
            case (.setAsideForeign, .intent): pendingForeignTo[e.id] = e.to
            case (.setAsideForeign, .result):
                if e.status == nil || e.status == .ok, let to = e.to ?? pendingForeignTo[e.id] {
                    foreign[e.id, default: []].append((to, e.ts))
                }
            default: break
            }
        }
        var out: [Leftover] = []
        func add(_ r: RelocationRecord, _ kind: LeftoverKind, _ path: String, onDrive: Bool, at: Date) {
            let normalized = PathNorm.normalize(path)
            if trashed.contains(r.id + "|" + normalized) { return }
            out.append(Leftover(id: "\(r.id)|\(kind.rawValue)|\(normalized)", moveID: r.id, kind: kind, path: normalized, onDrive: onDrive,
                                volume: onDrive ? r.volume : nil, bytes: r.logicalBytes, createdAt: at))
        }
        for r in records {
            let recipeFolder = PathNorm.parent(r.relativePath)
            switch r.state {
            case .aborted:
                if r.direction == .toDrive, copyStarted.contains(r.id) {
                    let path = published.contains(r.id) ? r.relativePath : recipeFolder + "/" + Names.stagingPrefix + r.id
                    add(r, .incompleteCopy, path, onDrive: true, at: r.updatedAt)
                } else if r.direction == .returnToMac, copyStarted.contains(r.id) {
                    add(r, .incompleteCopy, r.macPath + Names.returningInfix + r.id, onDrive: false, at: r.updatedAt)
                }
            case .rolledBack:
                if r.direction == .toDrive, published.contains(r.id) { add(r, .rolledBackCopy, r.relativePath, onDrive: true, at: r.updatedAt) }
            case .confirmed:
                if r.direction == .toDrive, r.safetyCopy == .kept { add(r, .safetyCopy, r.macPath + Names.beforeMoveSuffix, onDrive: false, at: r.confirmedAt ?? r.updatedAt) }
            case .returned:
                if r.direction == .toDrive { add(r, .driveCopyAfterReturn, r.relativePath, onDrive: true, at: r.updatedAt) }
            default: break
            }
            for item in foreign[r.id] ?? [] {
                add(r, .setAsideForeign, item.path, onDrive: false, at: item.at)
            }
        }
        return out.sorted { a, b in a.createdAt != b.createdAt ? a.createdAt > b.createdAt : a.id > b.id }
    }
}
