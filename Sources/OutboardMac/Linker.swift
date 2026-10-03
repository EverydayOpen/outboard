import Darwin
import Foundation
import OutboardCore

enum LinkResult {
    /// The link exists; the stamp is what `lstat` says about it.
    case created(FileStamp)
    /// Something is already at the path (an app made a folder, or a link is there); nothing was changed.
    case exists
    case refused(String)
    case failed(errno: Int32?, message: String)
    case notAttempted(String)

    var text: String {
        switch self {
        case .created: return "Done."
        case .exists: return "Something is already at that path."
        case .refused(let why), .notAttempted(let why): return why
        case .failed(_, let message): return message
        }
    }
}

/// The only `createSymbolicLink`. The link goes where Core's `LinkRules` allow (the plan's path, pointing inside the recorded
/// drive's mount point), only while that drive is mounted with the recorded UUID, only where nothing is, and only after the
/// journal has the intent. It never replaces anything: a path that is not free is `exists`.
enum Linker {
    static func create(linkPath: String, target: String, ctx: RuleContext, volume: VolumeRef, mountPoint: String, subject: JournalSubject,
                       home: String, step: MoveStep = .redirect) -> LinkResult {
        switch LinkRules.check(linkPath: linkPath, target: target, ctx: ctx) {
        case .allowed: break
        case .refused(let why): return .refused(why)
        }
        if let why = Fs.ancestorProblem(linkPath, home: home) { return .refused(why) }
        guard VolumeIdentity.matches(volume, mountPoint: mountPoint) else { return .refused("The drive is not where it was.") }
        let before = Fs.info(linkPath)
        guard before.err == ENOENT else {
            return before.err == 0 ? .exists : .failed(errno: before.err, message: "The path could not be looked at (error \(before.err)).")
        }
        guard Journal.intent(step, subject: subject, home: home, src: linkPath, to: target, note: JournalNote.link) else {
            return .notAttempted(Say.journalBlocked)
        }
        var failure: Error?
        do {
            try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: target)
        } catch {
            failure = error
        }
        let code = failure.flatMap { Fs.posix($0) }
        let made = failure == nil ? Fs.stamp(of: linkPath) : nil
        let confirmed = made != nil && Fs.linkTarget(linkPath) == target
        Journal.result(step, subject: subject, home: home, status: confirmed ? .ok : .failed, errno: code, src: linkPath, to: target, stamp: made,
                       note: JournalNote.link)
        if let made, confirmed { return .created(made) }
        if code == EEXIST { return .exists }
        return .failed(errno: code, message: "The link could not be created.")
    }
}
