import Darwin
import Foundation
import OutboardCore

enum RenameResult {
    /// Done; the stamp is what `lstat` says about the item at its new path.
    case renamed(FileStamp?)
    /// A rule said no; nothing happened.
    case refused(String)
    /// The item is not the object that was recorded (or is gone); nothing happened.
    case changed(String)
    case failed(errno: Int32?, message: String)
    /// The journal would not take the intent; nothing happened.
    case notAttempted(String)

    var isRenamed: Bool {
        if case .renamed = self { return true }
        return false
    }

    var text: String {
        switch self {
        case .renamed: return "Done."
        case .refused(let why), .changed(let why), .notAttempted(let why): return why
        case .failed(_, let message): return message
        }
    }
}

/// The only `moveItem`. It takes a closed `RenameOp` and two paths that Core's `RenameRules` must approve as that op's exact shape
/// (same parent for set-aside, staging to final on the recorded drive, into or out of `Parked/<id>/`), so a call site cannot
/// invent a rename. The destination must not exist; the item must still be the object that was recorded; the journal has the
/// intent before anything moves.
enum Renamer {
    static func step(for op: RenameOp) -> MoveStep {
        switch op {
        case .setAside: return .setAside
        case .undoSetAside: return .undoSetAside
        case .publish: return .publish
        case .park: return .park
        case .unpark: return .unpark
        case .setAsideForeign: return .setAsideForeign
        }
    }

    static func perform(_ op: RenameOp, from: String, to: String, ctx: RuleContext, subject: JournalSubject, home: String,
                        expected: FileStamp?, state: MoveState? = nil, note: String? = nil) -> RenameResult {
        switch RenameRules.check(op, from: from, to: to, ctx: ctx) {
        case .allowed: break
        case .refused(let why): return .refused(why)
        }
        let found: FileStamp
        switch Guard.verifyStamp(path: from, expected: expected) {
        case .unchanged(let stamp): found = stamp
        case .missing: return .changed("It is no longer there.")
        case .changed(let why): return .changed(why)
        case .unreadable(let e): return .failed(errno: e, message: "It could not be looked at (error \(e)).")
        }
        // Both ends are looked at through their parents' links: a rename must not cross out of the place the rules approved.
        if let why = Fs.ancestorProblem(from, home: home) ?? Fs.ancestorProblem(to, home: home) { return .refused(why) }
        guard !Fs.exists(to) else { return .refused("Something is already at the new name.") }
        guard Journal.intent(step(for: op), subject: subject, home: home, src: from, to: to, stamp: found, state: state, note: note) else {
            return .notAttempted(Say.journalBlocked)
        }
        var failure: Error?
        do {
            try FileManager.default.moveItem(at: URL(fileURLWithPath: from), to: URL(fileURLWithPath: to))
        } catch {
            failure = error
        }
        let code = failure.flatMap { Fs.posix($0) }
        let after = failure == nil ? Fs.stamp(of: to) : nil
        Journal.result(step(for: op), subject: subject, home: home, status: failure == nil ? .ok : .failed, errno: code, src: from, to: to,
                       stamp: after, note: note)
        if let failure {
            return .failed(errno: code, message: "It could not be renamed: \(failure.localizedDescription)")
        }
        return .renamed(after)
    }
}
