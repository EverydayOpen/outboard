import Darwin
import Foundation
import OutboardCore

/// Points an app at the copy, and undoes it. No verb of its own: a link goes through `Linker` (and `Renamer` to undo), a setting
/// through `DefaultsRedirect`. Kept apart so the engine and the rollback ask for "redirect" and "undo the redirect" without knowing
/// which method a recipe uses.
enum Redirect {
    static func apply(_ plan: MovePlan, home: String) -> RedirectResult {
        switch plan.redirect {
        case .symbolicLink(let linkPath, let target):
            let d = plan.destination
            let made = Linker.create(linkPath: linkPath, target: target, ctx: RuleContext(plan: plan, home: home),
                                     volume: VolumeRef(uuid: d.volumeUUID, name: d.volumeName, token: d.volumeToken), mountPoint: d.mountPoint,
                                     subject: JournalSubject(plan), home: home, step: .redirect)
            switch made {
            case .created: return .applied
            case .exists: return .exists
            case .refused(let why), .notAttempted(let why): return .refused(why)
            case .failed(let code, let message): return .failed(errno: code, message: message)
            }
        case .defaults:
            guard let recipe = Catalogue.recipe(plan.recipeID) else { return .refused("Outboard does not know this recipe.") }
            return DefaultsRedirect.apply(plan, recipe: recipe, home: home)
        }
    }

    /// Takes the redirect away without touching the data: the link (or the note that stands in for it) moves into `Parked/<id>/`, or
    /// the setting is written back. `.exists` means something that is not ours is at the path; the caller sets it aside.
    ///
    /// The link and the note are looked up in the journal under `factsMoveID`, the move that made them. A "Return to Mac" is a move of
    /// its own with its own id and no link lines, so it passes the id of the move it brings back; the renames are still journaled
    /// under `t.subject`.
    static func revert(_ t: RollbackTarget, home: String, factsMoveID: String? = nil) -> RedirectResult {
        if t.method == .defaults {
            guard let domain = t.defaultsDomain else { return .refused("This move has no recorded setting.") }
            return DefaultsRedirect.revert(domain: domain, writes: t.defaultsRevert, subject: t.subject, recipe: t.recipe, home: home)
        }
        let at = Fs.info(t.macPath)
        if at.err == ENOENT { return .applied }
        guard at.err == 0 else { return .failed(errno: at.err, message: "The path could not be looked at (error \(at.err)).") }
        let facts = JournalFacts(moveID: factsMoveID ?? t.subject.moveID, all: Journal.loadAll(home: home), home: home)
        let op: RenameOp
        let expected: FileStamp?
        let base: String
        switch Fs.kind(at.st) {
        case .symlink:
            op = .park
            expected = facts.lastLink?.stamp
            base = "link"
        case .file where isNote(at.st):
            op = .unpark
            expected = facts.lastPlaceholder
            base = "note"
        default:
            return .exists
        }
        guard Park.ensureFolder(moveID: t.subject.moveID, home: home) else { return .failed(errno: nil, message: "The Parked folder could not be prepared.") }
        let moved = Renamer.perform(op, from: t.macPath, to: Park.nextName(base, moveID: t.subject.moveID, home: home), ctx: t.ctx,
                                    subject: t.subject, home: home, expected: expected)
        return moved.isRenamed ? .applied : .failed(errno: nil, message: moved.text)
    }

    /// Our note: a small regular file, read-only.
    static func isNote(_ st: stat) -> Bool {
        Fs.kind(st) == .file && st.st_size <= Int64(Limits.placeholderMaxBytes) && (st.st_mode & 0o777) == 0o444
    }
}
