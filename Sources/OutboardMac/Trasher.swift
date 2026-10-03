import Darwin
import Foundation
import OutboardCore

enum TrashResult {
    /// In the Trash; the path is where `trashItem` says it went (nil when it did not say).
    case trashed(String?)
    /// Already gone from where it was.
    case gone
    case refused(String)
    case changed(String)
    case failed(errno: Int32?, message: String)
    case notAttempted(String)
}

/// What the Trasher is asked to move to the Trash: a path, the stamp the journal recorded for it, and the rule context that
/// says whether Core allows it. Only `<name>.before-move` of a confirmed move, or a staging or published folder the journal names as
/// a leftover of an aborted or rolled-back move, passes `TrashRules`.
struct TrashItem {
    var path: String
    var expected: FileStamp?
    var ctx: RuleContext
    var subject: JournalSubject
    /// The state the closing line carries: `originalTrashed` for the confirmed safety copy, the record's own state for a leftover (so
    /// the fold does not read the line as a state change).
    var state: MoveState?
    var note: String?
    /// How the journal names the item, so the leftovers list can tell it was trashed: `~`-relative on the Mac, drive-relative on a drive.
    var journalPath: String?
}

/// The only `trashItem`. Deleting means the Trash, after the user said so; nothing in Outboard removes a file. Rules, a fresh stamp
/// check, the journal intent, the move with its `resultingItemURL` kept, the result line, in that order, without a suspension point
/// between the stamp check and the move. A folder on a drive goes to that drive's own Trash (space returns when it is emptied).
enum Trasher {
    static func trash(_ item: TrashItem, home: String) -> TrashResult {
        switch TrashRules.allows(path: item.path, ctx: item.ctx) {
        case .allowed: break
        case .refused(let why): return .refused(why)
        }
        guard let expected = item.expected else { return .refused("Outboard has no record of this item, so it is not moved.") }
        switch Guard.verifyStamp(path: item.path, expected: expected) {
        case .unchanged: break
        case .missing: return .gone
        case .changed(let why): return .changed(why)
        case .unreadable(let e): return .failed(errno: e, message: "It could not be looked at (error \(e)).")
        }
        let named = item.journalPath ?? item.path
        guard Journal.intent(.trash, subject: item.subject, home: home, src: named, stamp: expected, note: item.note) else {
            return .notAttempted(Say.journalBlocked)
        }
        let url = URL(fileURLWithPath: item.path, isDirectory: expected.type == .directory)
        var resulting: NSURL?
        var failure: Error?
        do { try FileManager.default.trashItem(at: url, resultingItemURL: &resulting) } catch { failure = error }
        let code = failure.flatMap { Fs.posix($0) }
        let trashed = failure == nil ? (resulting as URL?)?.path : nil
        let status: StepStatus = failure == nil ? .ok : .failed
        Journal.result(.trash, subject: item.subject, home: home, status: status, errno: code, state: failure == nil ? item.state : nil,
                       src: named, note: item.note, trashedPath: trashed)
        if let failure {
            return .failed(errno: code, message: "It could not be moved to the Trash: \(failure.localizedDescription)")
        }
        return .trashed(trashed)
    }
}
