import Darwin
import Foundation
import OutboardCore

/// What a rollback or a forget needs to know about a move, from either a plan (an automatic rollback in the middle of a move) or a
/// record (the user's rollback later). Paths are absolute.
struct RollbackTarget {
    var subject: JournalSubject
    var recipe: Recipe
    var method: MethodKind
    var macPath: String
    var beforeMovePath: String
    var defaultsDomain: String?
    var defaultsRevert: [DefaultsWrite]
    var ctx: RuleContext
    var volume: VolumeRef
    var relativePath: String
    var name: String

    init?(plan: MovePlan, home: String) {
        guard let recipe = Catalogue.recipe(plan.recipeID) else { return nil }
        self.subject = JournalSubject(plan)
        self.recipe = recipe
        self.method = plan.method
        self.macPath = plan.macPath
        self.beforeMovePath = plan.beforeMovePath
        self.ctx = RuleContext(plan: plan, home: home)
        self.volume = VolumeRef(uuid: plan.destination.volumeUUID, name: plan.destination.volumeName, token: plan.destination.volumeToken)
        self.relativePath = plan.destination.relativePath
        self.name = plan.recipeName
        if case .defaults(let domain, _, _, let revert) = plan.redirect {
            self.defaultsDomain = domain
            self.defaultsRevert = revert
        } else {
            self.defaultsDomain = nil
            self.defaultsRevert = []
        }
    }

    init?(record: RelocationRecord, home: String, mountPoint: String?) {
        guard let recipe = Catalogue.recipe(record.recipeID) else { return nil }
        let mac = Fs.expand(record.macPath, home: home)
        self.subject = JournalSubject(record)
        self.recipe = recipe
        self.method = record.method
        self.macPath = mac
        self.beforeMovePath = mac + Names.beforeMoveSuffix
        self.defaultsDomain = record.defaultsDomain
        self.defaultsRevert = record.defaultsRevert
        self.ctx = RuleContext(record: record, home: home, mountPoint: mountPoint)
        self.volume = record.volume
        self.relativePath = record.relativePath
        self.name = record.recipeName
    }
}

/// Rolling back and forgetting. A rollback (R1 to R4, safety-ux 2.6) puts the original back where it was: the app must not be
/// running, the redirect is taken away, anything else that is at the path is set aside (never merged), the safety copy is renamed
/// back, and what changed on the drive since is counted and left there. It runs for a Swapped move (the user's choice) and, with
/// the same steps, right after a swap that went wrong.
enum Rollback {
    enum Mode {
        case user
        case automatic(AbortReason)
        /// Finishing a rollback or an undo that a crash interrupted (the state it ends in comes from Core's `Recovery`).
        case recovery(final: MoveState, abort: AbortReason?)

        var finalState: MoveState {
            switch self {
            case .user: return .rolledBack
            case .automatic: return .aborted
            case .recovery(let final, _): return final
            }
        }

        var abort: AbortReason? {
            switch self {
            case .user: return nil
            case .automatic(let reason): return reason
            case .recovery(_, let reason): return reason
            }
        }

        /// The app must not be running (R1). An automatic rollback runs in the same breath as the swap and puts the original back
        /// even if an app has just started: leaving the path empty would be worse, and a folder the app made is set aside.
        var checksRunning: Bool {
            if case .automatic = self { return false }
            return true
        }

        /// The foreign folder is named for the moment it appeared: while the move ran, or while the user was rolling back.
        var duringMove: Bool { abort != nil }
    }

    /// The user's "Roll back": the record is Swapped and its safety copy is still on the Mac.
    static func run(_ record: RelocationRecord, home: String) -> MoveOutcome {
        guard record.canRollBack else {
            return outcome(.rollback, record.id, record.state, ok: false, "Rolling back is no longer possible: the safety copy is gone or the move was confirmed.")
        }
        guard MutationGate.tryEnter() else { return outcome(.rollback, record.id, record.state, ok: false, Say.busy) }
        defer { MutationGate.leave() }
        guard let target = RollbackTarget(record: record, home: home, mountPoint: VolumeIdentity.currentMountPoint(of: record.volume)) else {
            return outcome(.rollback, record.id, record.state, ok: false, "Outboard does not know this recipe, so nothing was changed.")
        }
        return execute(target, mode: .user, home: home, current: record.state)
    }

    /// The same steps right after a swap that went wrong (a folder appeared in the gap, the health check failed). The engine holds the gate.
    static func automatic(_ plan: MovePlan, reason: AbortReason, home: String) -> MoveOutcome {
        guard let target = RollbackTarget(plan: plan, home: home) else {
            return outcome(.rollback, plan.id, .verifying, ok: false, "Outboard does not know this recipe. Check the activity log before using the app.")
        }
        return execute(target, mode: .automatic(reason), home: home, current: .verifying)
    }

    /// Finishes an undo a crash interrupted. The caller (Recover) holds the gate.
    static func recover(_ record: RelocationRecord, final: MoveState, abort: AbortReason?, message: String, home: String) -> MoveOutcome {
        guard let target = RollbackTarget(record: record, home: home, mountPoint: VolumeIdentity.currentMountPoint(of: record.volume)) else {
            return outcome(.recover, record.id, record.state, ok: false, "Outboard does not know this recipe, so nothing was changed.")
        }
        return execute(target, mode: .recovery(final: final, abort: abort), home: home, current: record.state, message: message)
    }

    /// R1: why the rollback cannot start, nil when the app is not running.
    private static func runningProblem(_ t: RollbackTarget, home: String) -> String? {
        switch RunningCheck.state(recipe: t.recipe, snapshot: RunningApps.snapshot(for: t.recipe, home: home)) {
        case .notRunning: break
        case .running: return "\(t.name) is running. Quit it and try again."
        case .unknown: return Say.unknownRunning
        }
        return nil
    }

    private static func execute(_ t: RollbackTarget, mode: Mode, home: String, current: MoveState, message override: String? = nil) -> MoveOutcome {
        let id = t.subject.moveID
        // The user's own rollback asks R1 before it writes anything: a refusal leaves no `rollback` line, so a later launch cannot
        // mistake it for a rollback that was started and finish it. (Recovery asks after its line: it is retried until it can run.)
        if case .user = mode, let why = runningProblem(t, home: home) { return outcome(.rollback, id, current, ok: false, why) }
        switch mode {
        case .user, .recovery:
            guard Journal.begin(.rollback, subject: t.subject, home: home) else { return outcome(.rollback, id, current, ok: false, Say.journalBlocked) }
        case .automatic:
            guard Journal.intent(.rollback, subject: t.subject, home: home, note: "automatic") else {
                return outcome(.rollback, id, current, ok: false, Say.journalBlocked)
            }
        }
        // R1: the app is not running. An automatic rollback runs in the same breath as the swap and puts the original back even if an
        // app has just started: leaving the path empty would be worse, and a folder the app made is set aside below.
        if mode.checksRunning, let why = runningProblem(t, home: home) { return stopped(t, current, why, home: home) }
        let facts = JournalFacts(moveID: id, all: Journal.loadAll(home: home), home: home)
        // R2: take the redirect away (the link or note moves into Parked/, or the setting is written back).
        // Something that is not ours at the path is set aside, never merged.
        func setAsideForeign() -> String? {
            let suffix = mode.duringMove ? Names.createdWhileMovingSuffix : Names.createdWhileRollingBackSuffix
            let aside = Renamer.perform(.setAsideForeign, from: t.macPath, to: t.macPath + suffix, ctx: t.ctx, subject: t.subject, home: home, expected: nil)
            return aside.isRenamed ? nil : "Something new is at the path and could not be set aside: " + aside.text
        }
        var reverted = Redirect.revert(t, home: home)
        if case .exists = reverted {
            if let why = setAsideForeign() { return stopped(t, current, why, home: home) }
            reverted = .applied
        }
        guard reverted.isApplied else { return stopped(t, current, reverted.text, home: home) }
        // A setting leaves the path itself to the app (`Redirect.revert` never looks at it), so a folder an app made there, in the
        // gap or since, is not ours either and would block R3 (only while the safety copy is still waiting to go back). Recovery's `setAsideForeignThenRollback` is this same step.
        if t.method == .defaults, Fs.exists(t.beforeMovePath), Fs.exists(t.macPath), let why = setAsideForeign() { return stopped(t, current, why, home: home) }
        // R3: the original goes back to its own name.
        let back = Renamer.perform(.undoSetAside, from: t.beforeMovePath, to: t.macPath, ctx: t.ctx, subject: t.subject, home: home,
                                   expected: facts.setAsideStamp)
        guard back.isRenamed else {
            return stopped(t, current, "The original could not be put back: " + back.text + " It is still next to the path as " + Fs.leaf(of: t.beforeMovePath) + ".", home: home)
        }
        // R4: what changed on the drive since the move stays on the drive; only the count is reported.
        let changed = changesOnDrive(t, home: home)
        let counts = changed.map { JournalCounts(differences: $0) }
        if mode.finalState == .aborted {
            // A move that never reached Swapped ends Aborted, with the reason; the original is back, so net nothing on the Mac changed.
            Journal.result(.abort, subject: t.subject, home: home, status: .ok, abort: mode.abort ?? .interrupted, state: .aborted,
                           note: "original restored", counts: counts)
        } else {
            Journal.result(.rolledBack, subject: t.subject, home: home, status: .ok, state: mode.finalState, note: "rolled back", counts: counts)
        }
        let tail = (changed ?? 0) > 0 ? " \(Format.count(changed ?? 0, "file")) changed on the drive since the move; they stay there and were not copied back." : ""
        var message = mode.duringMove ? "The move was undone. Your original is back where it was." : "Rolled back. Your original is back where it was." + tail
        if let override { message = override }
        let action: MoveActionKind
        switch mode {
        case .user: action = .rollback
        case .automatic: action = .move
        case .recovery: action = .recover
        }
        return MoveOutcome(action: action, moveID: id, state: mode.finalState, ok: true, abort: mode.abort, message: message)
    }

    private static func stopped(_ t: RollbackTarget, _ state: MoveState, _ why: String, home: String) -> MoveOutcome {
        Journal.result(.rollback, subject: t.subject, home: home, status: .refused, note: "refused")
        return outcome(.rollback, t.subject.moveID, state, ok: false, why)
    }

    private static func outcome(_ action: MoveActionKind, _ id: String, _ state: MoveState, ok: Bool, _ message: String) -> MoveOutcome {
        MoveOutcome(action: action, moveID: id, state: state, ok: ok, message: message)
    }

    /// Files added, changed or removed on the drive since the manifest, or nil when the drive or the manifest is not available.
    private static func changesOnDrive(_ t: RollbackTarget, home: String) -> Int? {
        guard let mount = VolumeIdentity.currentMountPoint(of: t.volume), VolumeIdentity.matches(t.volume, mountPoint: mount) else { return nil }
        let folder = mount + "/" + t.relativePath
        guard let manifest = ManifestStore.load(moveID: t.subject.moveID, home: home, driveFolder: Fs.parent(of: folder)),
              let now = SizeScanner.walk(folder, xattrs: false) else { return nil }
        let before = Dictionary(manifest.entries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var changed = 0
        var seen = Set<String>()
        for e in now.entries where e.type == .file {
            seen.insert(e.path)
            if let old = before[e.path] {
                if old.size != e.size || old.mtimeSeconds != e.mtimeSeconds { changed += 1 }
            } else {
                changed += 1
            }
        }
        changed += manifest.entries.filter { $0.type == .file && !seen.contains($0.path) }.count
        return changed
    }

    // MARK: - Forget

    /// "Forget" for a drive that is gone for good: if the safety copy is still next to the path the caller offers a rollback instead.
    /// Otherwise the link or note (or the setting) is taken away so the app can make its own default, and the record is closed. Two
    /// steps in the UI, never the default button. Nothing on the drive is touched.
    static func forget(_ record: RelocationRecord, home: String) -> MoveOutcome {
        guard record.state.isActive else { return outcome(.forget, record.id, record.state, ok: false, "This move is not active, so there is nothing to forget.") }
        guard MutationGate.tryEnter() else { return outcome(.forget, record.id, record.state, ok: false, Say.busy) }
        defer { MutationGate.leave() }
        guard let t = RollbackTarget(record: record, home: home, mountPoint: nil) else {
            return outcome(.forget, record.id, record.state, ok: false, "Outboard does not know this recipe, so nothing was changed.")
        }
        guard Journal.begin(.forget, subject: t.subject, home: home) else { return outcome(.forget, record.id, record.state, ok: false, Say.journalBlocked) }
        switch RunningCheck.state(recipe: t.recipe, snapshot: RunningApps.snapshot(for: t.recipe, home: home)) {
        case .notRunning: break
        case .running, .unknown:
            Journal.result(.forget, subject: t.subject, home: home, status: .refused, note: "app running")
            return outcome(.forget, record.id, record.state, ok: false, "\(t.name) is running. Quit it and try again.")
        }
        let reverted = Redirect.revert(t, home: home)
        guard reverted.isApplied else {
            Journal.result(.forget, subject: t.subject, home: home, status: .failed, note: "not put back")
            return outcome(.forget, record.id, record.state, ok: false, reverted.text)
        }
        Journal.result(.forget, subject: t.subject, home: home, status: .ok, state: .forgotten)
        return outcome(.forget, record.id, .forgotten, ok: true, "Forgotten. Outboard no longer watches this move. The data on the drive was not touched.")
    }
}
