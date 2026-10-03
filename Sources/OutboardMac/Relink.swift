import Darwin
import Foundation
import OutboardCore

/// The two guard repairs that are not park or unpark: **retarget** (the drive is mounted under another name or path than the link
/// says, so the link is replaced by one that points at the drive's current mount point) and **recreate** (nothing is at the path any
/// more: a link is rebuilt from the journal if the drive is here, otherwise the note is put back). Both go through the same
/// single-site verbs as everything else, and neither runs while the target app runs. Nothing is deleted: the old link moves into
/// `Parked/<id>/link` and stays there as evidence.
enum Relink {
    static func retarget(_ record: RelocationRecord, facts: GuardFacts, journal: JournalFacts, home: String) -> UnparkResult {
        guard facts.targetApp == .notRunning else { return .held(.appRunning) }
        guard let mount = VolumeIdentity.currentMountPoint(of: record.volume), VolumeIdentity.matches(record.volume, mountPoint: mount) else {
            return .refused("The drive is not connected.")
        }
        let sentinel = OutboardRoot.readSentinel(record.volume, relativePath: record.relativePath, moveID: record.id, mountPoint: mount)
        guard Sentinel.matches(sentinel, moveID: record.id, recipeID: record.recipeID, volumeToken: record.volume.token, relativePath: record.relativePath) else {
            return .refused("The drive's check file is missing or different.")
        }
        if record.method == .defaults { return retargetSetting(record, mount: mount, home: home) }
        let macPath = Fs.expand(record.macPath, home: home)
        guard let link = journal.lastLink else { return .refused("Outboard has no record of the link it made.") }
        let ctx = RuleContext(record: record, home: home, mountPoint: mount)
        let subject = JournalSubject(record)
        let target = mount + "/" + record.relativePath
        guard Journal.intent(.retarget, subject: subject, home: home, src: macPath, to: target, stamp: link.stamp, note: "retarget") else {
            return .refused(Say.journalBlocked)
        }
        var problem: String?
        let aside = Renamer.perform(.park, from: macPath, to: Park.nextName("link", moveID: record.id, home: home), ctx: ctx, subject: subject,
                                    home: home, expected: link.stamp)
        if aside.isRenamed {
            let made = Linker.create(linkPath: macPath, target: target, ctx: ctx, volume: record.volume, mountPoint: mount, subject: subject,
                                     home: home, step: .retarget)
            if case .created = made {} else { problem = made.text }
        } else {
            problem = aside.text
        }
        if problem == nil, case .failed(let why) = Health.check(record, home: home, mountPoint: mount) { problem = why }
        Journal.result(.retarget, subject: subject, home: home, status: problem == nil ? .ok : .failed, src: macPath, to: target, note: "retarget")
        if let problem { return .failed(problem) }
        return .unparked
    }

    /// A setting that still holds the path the drive had before: it is written again with the drive's current mount point. The
    /// write checks that the app is not running, journals first and reads the value back, like every other write of a setting.
    private static func retargetSetting(_ record: RelocationRecord, mount: String, home: String) -> UnparkResult {
        guard let recipe = Catalogue.recipe(record.recipeID), let domain = record.defaultsDomain else {
            return .failed("This relocation has no recorded setting.")
        }
        let writes = Health.recomputedWrites(record, mountPoint: mount)
        switch DefaultsRedirect.reapply(domain: domain, writes: writes, subject: JournalSubject(record), recipe: recipe, home: home, step: .retarget) {
        case .applied: break
        case .refused(let why), .notAttempted(let why): return .refused(why)
        case .exists: return .failed("Something is already there.")
        case .failed(_, let message): return .failed(message)
        }
        if case .failed(let why) = Health.check(record, home: home, mountPoint: mount, writes: writes) { return .failed(why) }
        return .unparked
    }

    /// Nothing is at the path. With the drive here, the link is rebuilt; without it, the note stands in.
    static func recreate(_ record: RelocationRecord, facts: GuardFacts, home: String) -> UnparkResult {
        guard record.method == .symlink else { return .refused("Only a link is rebuilt.") }
        guard facts.targetApp == .notRunning else { return .held(.appRunning) }
        let macPath = Fs.expand(record.macPath, home: home)
        let subject = JournalSubject(record)
        if let mount = VolumeIdentity.currentMountPoint(of: record.volume), VolumeIdentity.matches(record.volume, mountPoint: mount) {
            let sentinel = OutboardRoot.readSentinel(record.volume, relativePath: record.relativePath, moveID: record.id, mountPoint: mount)
            guard Sentinel.matches(sentinel, moveID: record.id, recipeID: record.recipeID, volumeToken: record.volume.token, relativePath: record.relativePath) else {
                return .refused("The drive's check file is missing or different.")
            }
            let made = Linker.create(linkPath: macPath, target: mount + "/" + record.relativePath, ctx: RuleContext(record: record, home: home, mountPoint: mount),
                                     volume: record.volume, mountPoint: mount, subject: subject, home: home, step: .recreate)
            if case .created = made { return .unparked }
            // macOS says no: leaving the path empty would let the app start fresh on the Mac and would retry on every pass. A note
            // stands in, and the guard then reports "needs permission" from the drive's side.
            if case .failed(let code, _) = made, code == EPERM || code == EACCES, Fs.info(macPath).err == ENOENT {
                let journal = JournalFacts(moveID: record.id, all: Journal.loadAll(home: home), home: home)
                let planted = Placeholder.create(at: macPath, driveName: record.volume.name, removal: journal.lastRemoval ?? facts.removal ?? .unknown,
                                                 subject: subject, home: home)
                if case .created = planted { return .failed(made.text + " A note stands at the path until macOS allows it.") }
            }
            return .failed(made.text)
        }
        guard VolumeIdentity.absent(record.volume) else { return .refused("The drive's state could not be read.") }
        let note = Placeholder.create(at: macPath, driveName: record.volume.name, removal: .unknown, subject: subject, home: home)
        if case .created = note { return .unparked }
        return .failed(note.text)
    }
}
