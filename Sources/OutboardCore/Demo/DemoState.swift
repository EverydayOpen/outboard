import Foundation

/// A top-level object in the demo's in-memory tree: the folder, its renamed original, a link, a note, a staging or published
/// copy on the drive. Only the objects a move touches are tracked; the contents are the fingerprint.
struct DemoNode: Hashable {
    enum Kind: Hashable { case directory, link, note }
    var kind: Kind
    var stamp: FileStamp
    var target: String?
    var fingerprint: TreeFingerprint
    /// Carries our marker: our staging and published copies, our notes. A folder without it is somebody else's.
    var ours: Bool
}

/// The in-memory stand-in for the disk. A path holds at most one node; a rename needs the destination to be free (the real
/// `Renamer` refuses otherwise). There is no verb that deletes a node.
struct DemoTree {
    static let macDevice: Int64 = 16_777_234
    static let driveDevice: Int64 = 16_777_240

    private(set) var nodes: [String: DemoNode] = [:]
    private var inode: UInt64 = 5_000_000

    func node(_ path: String) -> DemoNode? { nodes[path] }
    func has(_ path: String) -> Bool { nodes[path] != nil }

    private mutating func nextStamp(_ path: String, type: FileType, size: UInt64, mtime: Int64, links: UInt32) -> FileStamp {
        inode += 1
        return FileStamp(device: path.hasPrefix("/Volumes/") ? Self.driveDevice : Self.macDevice, inode: inode, type: type, size: size,
                         mtimeSeconds: mtime, linkCount: links)
    }

    /// A directory with a fresh identity (a copy, or a folder an app made).
    @discardableResult
    mutating func addDirectory(_ path: String, fingerprint: TreeFingerprint, ours: Bool, mtime: Int64) -> DemoNode {
        let n = DemoNode(kind: .directory, stamp: nextStamp(path, type: .directory, size: 0, mtime: mtime, links: 2), target: nil,
                         fingerprint: fingerprint, ours: ours)
        nodes[path] = n
        return n
    }

    /// A directory the size scan stamped: the tree keeps that identity so the plan's source stamp matches.
    mutating func adopt(_ path: String, stamp: FileStamp, fingerprint: TreeFingerprint) {
        nodes[path] = DemoNode(kind: .directory, stamp: stamp, target: nil, fingerprint: fingerprint, ours: false)
    }

    @discardableResult
    mutating func addLink(_ path: String, target: String, mtime: Int64) -> DemoNode {
        let n = DemoNode(kind: .link, stamp: nextStamp(path, type: .symlink, size: UInt64(target.utf8.count), mtime: mtime, links: 1),
                         target: target, fingerprint: TreeFingerprint(symlinks: 1), ours: true)
        nodes[path] = n
        return n
    }

    @discardableResult
    mutating func addNote(_ path: String, text: String, mtime: Int64) -> DemoNode {
        let n = DemoNode(kind: .note, stamp: nextStamp(path, type: .file, size: UInt64(text.utf8.count), mtime: mtime, links: 1), target: nil,
                         fingerprint: TreeFingerprint(files: 1, logicalBytes: UInt64(text.utf8.count)), ours: true)
        nodes[path] = n
        return n
    }

    /// A small file of ours (a sentinel, a manifest).
    mutating func addMarker(_ path: String, mtime: Int64) {
        _ = addNote(path, text: "marker", mtime: mtime)
    }

    /// The rename: keeps the object (and its identity). False when the source is missing or the destination is taken.
    @discardableResult
    mutating func relocate(_ from: String, to: String) -> Bool {
        guard let n = nodes[from], nodes[to] == nil else { return false }
        nodes[to] = n
        nodes.removeValue(forKey: from)
        return true
    }

    mutating func setFingerprint(_ path: String, _ fingerprint: TreeFingerprint) {
        nodes[path]?.fingerprint = fingerprint
    }

    /// Something outside Outboard replaces what is at a path (an app writing, the user in Finder). Test and scenario scaffolding.
    mutating func replaceFromOutside(_ path: String, with node: DemoNode?) {
        if let node { nodes[path] = node } else { nodes.removeValue(forKey: path) }
    }
}

/// Failures the tests (and a demo that wants one) can inject into the next move. Each goes through the real Core check that
/// catches it: the compare, the running check, the freshness check, the foreign-folder handling.
public enum DemoFailure: String, CaseIterable, Sendable {
    /// One file on the drive differs from the original (V2).
    case mismatch
    /// An app wrote to the folder while it was copied (V3).
    case sourceChanged
    /// The target app opened after the copy (W1).
    case appLaunched
    /// The drive was unplugged between the plan and the switch (E18).
    case driveChanged
    /// An app made a folder at the path between the rename and the link (W3).
    case foreignFolder
}

/// The mutable world behind one demo backend: the tree, the drives, the settings, the in-memory journal and the guard's memory.
/// Nothing here touches the real system. Every public entry point takes the lock; the helpers assume it is held.
final class DemoState: @unchecked Sendable {
    let world: DemoWorld
    let now: Date
    let home = DemoScenarios.home
    /// The demo shows the moves that are not yet tried on a real Mac (every automated recipe is one), so its sheets carry the note.
    static let prefs = Preferences(showUnverifiedMoves: true)
    private let lock = NSRecursiveLock()

    var tree = DemoTree()
    var journal: [JournalEntry] = []
    var seqs: [String: Int] = [:]
    /// The time of the next journal line. Moves forward only; history starts in the past and ends at `now`.
    var cursor: Date
    var volumes: [String: DriveFacts] = [:]
    var mounted: Set<String> = []
    /// How each drive left, for the guard (set when it goes, cleared once its relocations are connected again).
    var removal: [String: RemovalKind] = [:]
    /// Moves whose unchanged files were hashed since the drive came back ("Check and reconnect" passed).
    var checked: Set<String> = []
    var plans: [String: MovePlan] = [:]
    var defaultsStore: [String: [String: String]] = [:]
    /// Defaults relocations whose setting was put back while the drive is away.
    var settingReverted: Set<String> = []
    var running: Set<RecipeID>
    var loginItem: LoginItemState = .notRegistered
    /// Moves running now; the runner claims one, so more than one fails preflight P14 (one mutation in flight).
    var flights = 0
    var reports: [String: PreflightReport] = [:]
    var summaries: [String: VerificationSummary] = [:]
    /// Moves started since launch; the next `plan` takes the next move id.
    var started = 0
    var failure: DemoFailure?
    var lastSnapshot = GuardSnapshot.empty
    var justUnparked: [RelocationRecord] = []
    /// What each reconnected relocation was checked with: the banner "Drive is back" and its sample come from these.
    var returns: [String: ReturnReport] = [:]
    var checks: [String: ReturnCheckResult] = [:]

    init(_ world: DemoWorld, now: Date, failure: DemoFailure?) {
        self.world = world
        self.now = now
        self.cursor = now
        self.running = world.running
        for v in world.volumes { volumes[v.id] = v }
        mounted = Set(world.attached)
        seedTree()
        // History starts in the past and is played oldest first; the clock only moves forward from here.
        cursor = now.addingTimeInterval(-Double((world.history.map(\.secondsAgo).max() ?? 0) + 60))
        // The history is played with the same code a live move runs, then the launch recovery and the drive's events.
        for spec in world.history { play(spec) }
        recoverAtLaunch()
        for event in world.events { apply(event) }
        cursor = max(cursor, now)
        self.failure = failure
        lastSnapshot = snapshot()
    }

    func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: Paths and time

    var nowSeconds: Int64 { Int64(cursor.timeIntervalSince1970) }

    func tilde(_ path: String) -> String { PathText.tilde(path, home: home) }
    func absolute(_ path: String) -> String { PathText.expandTilde(path, home: home) }

    func advance(_ seconds: Int64) { cursor = cursor.addingTimeInterval(Double(seconds)) }

    var supportFolder: String { home + "/Library/Application Support/" + Names.supportFolder }
    func parkedLink(_ moveID: String) -> String { supportFolder + "/" + Names.parkedFolder + "/" + moveID + "/link" }
    func parkedNote(_ moveID: String) -> String { supportFolder + "/" + Names.parkedFolder + "/" + moveID + "/note" }
    var trashFolder: String { home + "/.Trash" }

    func leafName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    func mountPoint(of uuid: String) -> String? { volumes[uuid]?.mountPoint }

    func nextMoveID() -> String { DemoScenarios.userMoveID(now: now, index: started) }

    // MARK: The Mac at launch

    private func seedTree() {
        for (i, seed) in world.seeds.enumerated() {
            guard let recipe = Catalogue.recipe(seed.recipeID), let path = recipe.absoluteSource(home: home) else { continue }
            let fp = TreeFingerprint(files: seed.files, directories: seed.directories, symlinks: seed.symlinks, logicalBytes: seed.bytes,
                                     allocatedBytes: seed.bytes)
            let stamp = FileStamp(device: DemoTree.macDevice, inode: 4_100_000 + UInt64(i), type: .directory, size: 0,
                                  mtimeSeconds: Int64(now.timeIntervalSince1970) - 7_200 - Int64(i) * 331, linkCount: 2)
            tree.adopt(path, stamp: stamp, fingerprint: fp)
        }
    }

    // MARK: Journal

    @discardableResult
    func put(_ subject: JournalSubject, _ phase: JournalPhase, _ step: MoveStep, state: MoveState? = nil, src: String? = nil, to: String? = nil,
             stamp: FileStamp? = nil, volume: VolumeRef? = nil, status: StepStatus? = nil, errno: Int32? = nil, abort: AbortReason? = nil,
             note: String? = nil, plan: JournalPlan? = nil, counts: JournalCounts? = nil, verification: VerificationSummary? = nil,
             trashedPath: String? = nil) -> Bool {
        if world.journalBlocked { return false }
        let seq = (seqs[subject.moveID] ?? 0) + 1
        seqs[subject.moveID] = seq
        journal.append(JournalEntry(id: subject.moveID, seq: seq, ts: cursor, phase: phase, step: step,
                                    recipe: subject.recipe.isEmpty ? nil : subject.recipe, state: state, src: src, to: to, stamp: stamp,
                                    vol: volume?.uuid, volName: volume?.name, fsName: volume == nil ? nil : "APFS", status: status,
                                    errno: errno, abort: abort, note: note, plan: plan, counts: counts, verification: verification,
                                    trashedPath: trashedPath))
        advance(1)
        return true
    }

    func records() -> [RelocationRecord] { RelocationFold.records(from: journal, home: home) }
    func record(_ id: String) -> RelocationRecord? { records().first { $0.id == id } }

    func leftovers() -> [Leftover] {
        RelocationFold.leftovers(from: journal, records: records())
    }

    // MARK: Reads

    func currentVolumes() -> [DriveFacts] { world.volumes.compactMap { mounted.contains($0.id) ? volumes[$0.id] : nil } }
    func drive(_ id: String) -> DriveFacts? { mounted.contains(id) ? volumes[id] : nil }

    func scans(_ ids: [RecipeID]) -> [SizeScan] {
        if world.measuresNothing { return [] }
        let active = records().filter { $0.direction == .toDrive && $0.state.isActive }
        var out: [SizeScan] = []
        for id in ids {
            guard let recipe = Catalogue.recipe(id), let source = recipe.source, let path = recipe.absoluteSource(home: home) else { continue }
            if let reason = world.unmeasured[id] {
                out.append(SizeScan(recipeID: id, path: source, state: .notMeasured, reason: reason, errnoCode: reason == .needsFullDiskAccess ? 1 : nil,
                                    measuredAt: now))
                continue
            }
            let node = tree.node(path)
            if let r = active.first(where: { $0.recipeID == id }), node == nil || node?.kind != .directory {
                let target = (mountPoint(of: r.volume.uuid) ?? "/Volumes/" + r.volume.name) + "/" + r.relativePath
                out.append(SizeScan(recipeID: id, path: source, state: .notMeasured, reason: .alreadyRedirected, isLink: node?.kind == .link,
                                    linkTarget: target, stamp: node?.stamp, measuredAt: now))
                continue
            }
            guard let node, node.kind == .directory else {
                out.append(SizeScan(recipeID: id, path: source, state: .absent, measuredAt: now))
                continue
            }
            out.append(SizeScan(recipeID: id, path: source, state: .measured, fingerprint: node.fingerprint, stamp: node.stamp, measuredAt: now))
        }
        return out
    }

    func needs(_ recipe: Recipe) -> SourceNeeds? {
        guard let path = recipe.absoluteSource(home: home), let node = tree.node(path), node.kind == .directory else { return nil }
        return SourceNeeds(logicalBytes: node.fingerprint.logicalBytes, isCaseSensitive: .no, hasHardLinks: node.fingerprint.hardLinkedFiles > 0,
                           hasSymlinks: node.fingerprint.symlinks > 0)
    }

    func eligibility(_ volumeID: String, _ recipeID: RecipeID?) -> EligibilityReport {
        let recipe = recipeID.flatMap { Catalogue.recipe($0) }
        guard let v = drive(volumeID) else {
            let verdict = Eligibility.freshness(plannedUUID: volumeID, plannedMountPoint: "", now: nil)
                ?? EligibilityVerdict(rule: .e18, outcome: .refuse, message: "The drive changed while we were getting ready. Nothing was changed.")
            return EligibilityReport(volumeID: volumeID, recipeID: recipeID, verdicts: [verdict])
        }
        return Eligibility.evaluate(volume: v, recipe: recipe, source: recipe.flatMap { needs($0) }, policy: .release)
    }

    func runningSnapshot(_ recipe: Recipe) -> RunningSnapshot {
        // Only the app itself is open (its first bundle id), not every helper the recipe lists.
        let on = running.contains(recipe.id)
        return RunningSnapshot(readable: true, bundleIDs: on ? Set(recipe.bundleIDs.prefix(1)) : [])
    }

    func blockers(_ recipeID: RecipeID) -> [Blocker] {
        guard let recipe = Catalogue.recipe(recipeID) else { return [] }
        return RunningCheck.blockers(recipe: recipe, snapshot: runningSnapshot(recipe))
    }

    func prior(_ recipe: Recipe) -> [PriorValue] {
        guard case .defaults(let domain, let keys, _) = recipe.method else { return [] }
        return keys.map { PriorValue(key: $0.name, type: $0.type, value: defaultsStore[domain]?[$0.name]) }
    }

    func planMove(_ recipeID: RecipeID, _ volumeID: String, _ consent: ConsentRecord) -> MovePlanResult {
        guard let recipe = Catalogue.recipe(recipeID) else { return MovePlanResult(refusal: "Outboard doesn't know that app.") }
        guard let scan = scans([recipeID]).first else { return MovePlanResult(refusal: "That folder hasn't been measured yet.") }
        guard let drive = drive(volumeID) else { return MovePlanResult(refusal: "The drive changed while we were getting ready. Nothing was changed.") }
        let report = eligibility(volumeID, recipeID)
        return MovePlanner.plan(recipe: recipe, folder: scan, drive: drive, report: report, consent: consent, prior: prior(recipe), home: home,
                                now: cursor, moveID: nextMoveID(), groupID: nil, prefs: DemoState.prefs)
    }

    func useDrive(_ volumeID: String) -> UseDriveResult {
        guard var v = drive(volumeID) else { return UseDriveResult(ok: false, message: "That drive isn't connected.") }
        let report = Eligibility.evaluate(volume: v, recipe: nil, source: nil, policy: .release)
        if let refusal = report.firstRefusal { return UseDriveResult(ok: false, message: refusal.message, facts: v) }
        let token = v.markerToken ?? "demo-marker-" + String(v.id.suffix(4)).lowercased()
        let ref = VolumeRef(uuid: v.id, name: v.name, token: token)
        guard put(.app, .intent, .useDrive, volume: ref) else { return UseDriveResult(ok: false, message: DemoScenarios.journalBlockedMessage) }
        v.hasOutboardMarker = true
        v.markerToken = token
        volumes[volumeID] = v
        put(.app, .result, .useDrive, volume: ref, status: .ok)
        return UseDriveResult(ok: true, message: "Your Outboard drive is ready. Outboard wrote one small file on it and nothing else.", facts: v)
    }

    func recordGuideViewed(_ recipeID: RecipeID) {
        let subject = Catalogue.recipe(recipeID).map { JournalSubject(moveID: "app", recipe: $0.versionedID) } ?? .app
        if put(subject, .intent, .guideViewed) { put(subject, .result, .guideViewed, status: .ok) }
    }

    func diagnostics() -> String {
        DiagnosticsText.text(volumes: currentVolumes(), scans: scans(Catalogue.all.map(\.id)), osVersion: DemoScenarios.osVersion,
                             appVersion: DemoScenarios.appVersion)
    }

    func setLoginItem(_ enabled: Bool) -> LoginItemState {
        loginItem = enabled ? .enabled : .notRegistered
        return loginItem
    }

    // MARK: Text helpers

    func names(_ records: [RelocationRecord]) -> String {
        var seen: [String] = []
        for r in records where !seen.contains(r.recipeName) { seen.append(r.recipeName) }
        switch seen.count {
        case 0: return ""
        case 1: return seen[0]
        default: return seen.dropLast().joined(separator: ", ") + " and " + seen[seen.count - 1]
        }
    }

    func grouped(_ n: Int) -> String {
        var s = String(n)
        var i = s.count - 3
        while i > 0 {
            s.insert(",", at: s.index(s.startIndex, offsetBy: i))
            i -= 3
        }
        return s
    }
}
