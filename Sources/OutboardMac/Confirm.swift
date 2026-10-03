import Foundation
import OutboardCore

/// "Use the move for good?": two journaled steps in one dialog. The decision is recorded (the move becomes Confirmed and rolling
/// back is withdrawn), then `<name>.before-move` goes to the Trash through `Trasher`. Nothing is deleted; the Mac gets its space
/// back when the user empties the Trash. The drive must be present and healthy and the safety copy must still be the object that
/// was renamed. The app is expected to be running here (the user just checked it), so there is no running check; the safety copy
/// is not something an app uses.
enum Confirm {
    static func run(_ record: RelocationRecord, home: String) -> MoveOutcome {
        func stop(_ message: String) -> MoveOutcome { MoveOutcome(action: .confirm, moveID: record.id, state: record.state, ok: false, message: message) }
        guard record.canConfirm else { return stop("There is nothing to confirm for this move.") }
        guard MutationGate.tryEnter() else { return stop(Say.busy) }
        defer { MutationGate.leave() }
        let name = record.volume.label
        guard let mount = VolumeIdentity.currentMountPoint(of: record.volume) else { return stop("Plug \(name) in first, then confirm.") }
        guard Health.check(record, home: home, mountPoint: mount).isHealthy else {
            return stop("The move does not look healthy yet, so it is not confirmed. Check the app, then try again.")
        }
        let facts = JournalFacts(moveID: record.id, all: Journal.loadAll(home: home), home: home)
        let before = Fs.expand(record.macPath, home: home) + Names.beforeMoveSuffix
        guard let stamp = facts.setAsideStamp else { return stop("Outboard has no record of the safety copy, so nothing was changed.") }
        switch Guard.verifyStamp(path: before, expected: stamp) {
        case .unchanged: break
        case .missing: return stop("The safety copy is gone, so there is nothing to move to the Trash. Rolling back is no longer possible.")
        case .changed(let why): return stop("The safety copy changed: \(why)")
        case .unreadable(let e): return stop("The safety copy could not be looked at (error \(e)).")
        }

        let subject = JournalSubject(record)
        guard Journal.intent(.confirm, subject: subject, home: home) else { return stop(Say.journalBlocked) }
        Journal.result(.confirm, subject: subject, home: home, status: .ok, state: .confirmed)

        // The Trash rule wants a record that says Confirmed, so the journal is folded again.
        let current = RelocationFold.records(from: Journal.loadAll(home: home), home: home).first { $0.id == record.id } ?? record
        let item = TrashItem(path: before, expected: stamp, ctx: RuleContext(record: current, home: home, mountPoint: mount), subject: subject,
                             state: .originalTrashed, note: nil, journalPath: Fs.tilde(before, home: home))
        switch Trasher.trash(item, home: home) {
        case .trashed:
            return MoveOutcome(action: .confirm, moveID: record.id, state: .originalTrashed, ok: true,
                               message: "Confirmed. The original is in the Trash. Your Mac gets the space back when you empty the Trash.")
        case .gone:
            return MoveOutcome(action: .confirm, moveID: record.id, state: .confirmed, ok: false,
                               message: "Confirmed. The safety copy was already gone from \(Fs.leaf(of: before)); check the Trash.")
        case .refused(let why), .changed(let why), .notAttempted(let why):
            return MoveOutcome(action: .confirm, moveID: record.id, state: .confirmed, ok: false,
                               message: "Confirmed, but the original is still next to the folder as \(Fs.leaf(of: before)). \(why)")
        case .failed(_, let message):
            return MoveOutcome(action: .confirm, moveID: record.id, state: .confirmed, ok: false,
                               message: "Confirmed, but the original is still next to the folder as \(Fs.leaf(of: before)). \(message)")
        }
    }
}

/// Things Outboard created and did not delete (an incomplete copy, a rolled-back copy, the drive copy after a return, the confirmed
/// safety copy) go to the Trash one at a time, only when the journal names them, the drive is the recorded one and the stamp is still
/// the one the journal took. Items an app made in the gap and Outboard set aside are not moved by Outboard: Finder does that.
enum Leftovers {
    static func trash(_ leftoverID: String, home: String) -> MoveOutcome {
        let entries = Journal.loadAll(home: home)
        let records = RelocationFold.records(from: entries, home: home)
        let all = RelocationFold.leftovers(from: entries, records: records)
        func stop(_ id: String, _ state: MoveState, _ message: String) -> MoveOutcome {
            MoveOutcome(action: .trashLeftover, moveID: id, state: state, ok: false, message: message)
        }
        guard let leftover = all.first(where: { $0.id == leftoverID }), let record = records.first(where: { $0.id == leftover.moveID }) else {
            return stop(leftoverID, .aborted, "That item is no longer in the list.")
        }
        guard MutationGate.tryEnter() else { return stop(record.id, record.state, Say.busy) }
        defer { MutationGate.leave() }
        let facts = JournalFacts(moveID: record.id, all: entries, home: home)
        var mount: String?
        let absolute: String
        var expected: FileStamp?
        var closing: MoveState? = record.state
        if leftover.onDrive {
            guard let m = VolumeIdentity.currentMountPoint(of: record.volume), VolumeIdentity.matches(record.volume, mountPoint: m) else {
                return stop(record.id, record.state, "Plug \(record.volume.label) in first. This copy is on it.")
            }
            mount = m
            absolute = m + "/" + leftover.path
            expected = Fs.leaf(of: leftover.path).hasPrefix(Names.stagingPrefix) ? facts.stagingStamp : (facts.publishedStamp ?? facts.stagingStamp)
        } else if leftover.kind == .safetyCopy {
            mount = VolumeIdentity.currentMountPoint(of: record.volume)
            absolute = Fs.expand(leftover.path, home: home)
            expected = facts.setAsideStamp
            closing = .originalTrashed
        } else {
            return stop(record.id, record.state, "Outboard doesn't move this one. It is next to the folder it came from; move it to the Trash in Finder if you don't need it.")
        }
        var ctx = RuleContext(record: record, home: home, mountPoint: mount)
        ctx.knownLeftovers = RuleContext.leftoverPaths(all, mountPoint: mount)
        // A crash in the middle of a copy leaves no result line, so no stamp. The folder is taken as it is now, but only when it is the
        // staging folder named for this move and the journal lists it as this move's leftover (the rules ask the same again).
        if expected == nil, leftover.onDrive, leftover.kind == .incompleteCopy, Fs.leaf(of: leftover.path) == Names.stagingPrefix + record.id,
           ctx.knownLeftovers.contains(Fs.normalized(absolute)) {
            expected = Fs.stamp(of: absolute)
        }
        let item = TrashItem(path: absolute, expected: expected, ctx: ctx, subject: JournalSubject(record), state: closing, note: "leftover",
                             journalPath: leftover.path)
        switch Trasher.trash(item, home: home) {
        case .trashed:
            return MoveOutcome(action: .trashLeftover, moveID: record.id, state: closing ?? record.state, ok: true,
                               message: "Moved to the Trash. The space comes back when you empty the Trash.")
        case .gone:
            return MoveOutcome(action: .trashLeftover, moveID: record.id, state: record.state, ok: true, message: "It was already gone.")
        case .refused(let why), .changed(let why), .notAttempted(let why):
            return stop(record.id, record.state, why)
        case .failed(_, let message):
            return stop(record.id, record.state, message)
        }
    }
}
