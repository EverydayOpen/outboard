import Darwin
import Foundation
import OutboardCore

enum ParkResult {
    /// The link is in `Parked/<id>/` and the note is where the folder was.
    case parked
    /// A `defaults` relocation: the setting was put back to its prior (or neutral) value.
    case reverted
    /// This recipe is only reported on (a stale setting is harmless, a rewrite is not).
    case leftAlone
    case notNeeded(String)
    case refused(String)
    case failed(String)
}

/// Parking: the drive is gone, so the link is moved out of the way into `~/Library/Application Support/Outboard/Parked/<id>/`
/// (kept as evidence, never deleted) and a read-only note stands where the folder was, so an app that looks there stops instead of
/// starting fresh on the Mac. Only for a relocation whose drive is absent by UUID (a mount table that cannot be read parks
/// nothing), only for the link Outboard made (stamp checked), and journaled first.
enum Park {
    static func park(_ record: RelocationRecord, facts: JournalFacts, removal: RemovalKind, home: String) -> ParkResult {
        guard VolumeIdentity.absent(record.volume) else { return .notNeeded("The drive is connected.") }
        switch record.onDriveMissing {
        case .parkPlaceholder: break
        case .revertSetting: return revertSetting(record, removal: removal, home: home)
        case .leaveAlone, .none: return .leftAlone
        }
        guard record.method == .symlink else { return .leftAlone }
        let macPath = Fs.expand(record.macPath, home: home)
        guard let link = facts.lastLink else { return .refused("Outboard has no record of the link it made, so it leaves the path alone.") }
        switch Guard.verifyStamp(path: macPath, expected: link.stamp) {
        case .unchanged: break
        case .missing: return .notNeeded("The link is already gone.")
        case .changed(let why): return .refused(why)
        case .unreadable(let e): return .failed("The path could not be looked at (error \(e)).")
        }
        let subject = JournalSubject(record)
        // Ask the rules before the intent line: a refusal must not add a line to the journal on every pass.
        let ctx = RuleContext(record: record, home: home, mountPoint: nil)
        let slot = nextName("link", moveID: record.id, home: home)
        if case .refused(let why) = RenameRules.check(.park, from: macPath, to: slot, ctx: ctx) { return .refused(why) }
        guard Journal.intent(.park, subject: subject, home: home, src: macPath, stamp: link.stamp, note: "park") else {
            return .refused(Say.journalBlocked)
        }
        var problem: String?
        if ensureFolder(moveID: record.id, home: home) {
            let moved = Renamer.perform(.park, from: macPath, to: slot, ctx: ctx, subject: subject,
                                        home: home, expected: link.stamp, note: JournalNote.park(removal))
            if moved.isRenamed {
                let made = Placeholder.create(at: macPath, driveName: record.volume.name, removal: removal, subject: subject, home: home)
                if case .created = made {} else { problem = made.text }
            } else {
                problem = moved.text
            }
        } else {
            problem = "The Parked folder could not be prepared."
        }
        // One closing line for the whole step, after everything above has been tried.
        Journal.result(.park, subject: subject, home: home, status: problem == nil ? .ok : .failed, src: macPath,
                       note: problem == nil ? JournalNote.park(removal) : "park")
        if let problem { return .failed(problem) }
        return .parked
    }

    /// `defaults` relocations are not parked with a note: the setting is written back. If the app is running the write is refused
    /// and the banner says what is pending.
    private static func revertSetting(_ record: RelocationRecord, removal: RemovalKind, home: String) -> ParkResult {
        guard let recipe = Catalogue.recipe(record.recipeID), let domain = record.defaultsDomain else {
            return .failed("This relocation has no recorded setting.")
        }
        // Journaled as a park (not as `undoRedirect`, which is a rollback's step), with how the drive left, like a link's park.
        switch DefaultsRedirect.revert(domain: domain, writes: record.defaultsRevert, subject: JournalSubject(record), recipe: recipe, home: home,
                                       step: .park, mark: JournalNote.park(removal)) {
        case .applied: return .reverted
        case .refused(let why), .notAttempted(let why): return .refused(why)
        case .exists: return .failed("Something is already there.")
        case .failed(_, let message): return .failed(message)
        }
    }

    // MARK: - The Parked folder

    static func parkedFolder(moveID: String, home: String) -> String {
        Journal.directory(home: home) + "/" + Names.parkedFolder + "/" + moveID
    }

    /// `Parked/<id>/` (0700). Everything parked keeps its own name here; nothing in it is ever removed by Outboard.
    static func ensureFolder(moveID: String, home: String) -> Bool {
        guard Journal.prepare(home: home) else { return false }
        for dir in [Journal.directory(home: home) + "/" + Names.parkedFolder, parkedFolder(moveID: moveID, home: home)] {
            let i = Fs.info(dir)
            if i.err == 0 {
                guard Fs.kind(i.st) == .directory else { return false }
                continue
            }
            guard i.err == ENOENT,
                  (try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: false,
                                                            attributes: [.posixPermissions: 0o700])) != nil else { return false }
        }
        return true
    }

    /// `Parked/<id>/link`, or `link-2`, `link-3` ... when an earlier cycle left one there: an old parked link is evidence and stays.
    static func nextName(_ base: String, moveID: String, home: String) -> String {
        let folder = parkedFolder(moveID: moveID, home: home)
        var candidate = folder + "/" + base
        var n = 1
        while Fs.exists(candidate) {
            n += 1
            candidate = folder + "/" + base + "-" + String(n)
        }
        return candidate
    }

    /// The newest of those: the one `nextName` would have chosen last time (`link` when there is only one).
    static func latestName(_ base: String, moveID: String, home: String) -> String {
        let folder = parkedFolder(moveID: moveID, home: home)
        var latest = folder + "/" + base
        var n = 1
        while Fs.exists(folder + "/" + base + "-" + String(n + 1)) {
            n += 1
            latest = folder + "/" + base + "-" + String(n)
        }
        return latest
    }
}
