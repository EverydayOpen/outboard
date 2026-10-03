import Darwin
import Foundation
import OutboardCore

enum UnparkResult {
    case unparked
    /// A precondition is not met yet (the app runs, the removal was not clean, the sample differs ...). Nothing was changed.
    case held(HeldReason)
    case refused(String)
    case failed(String)
}

/// Unparking: the drive is back, so the note stands aside and the link returns. Every precondition has to hold (the drive's UUID and
/// sentinel match, nothing holds the unpark back, the note is still the one Outboard made, and afterwards the redirect resolves to
/// the recorded volume). The target is recomputed from the drive's current mount point plus the recorded relative path: a parked link
/// whose text already says that returns by rename; anything else gets a fresh link. Nothing is deleted.
enum Unpark {
    static func unpark(_ record: RelocationRecord, facts: GuardFacts, journal: JournalFacts, check: ReturnCheckResult?, home: String) -> UnparkResult {
        guard let mount = VolumeIdentity.currentMountPoint(of: record.volume), VolumeIdentity.matches(record.volume, mountPoint: mount) else {
            return .refused("The drive is not connected.")
        }
        let sentinel = OutboardRoot.readSentinel(record.volume, relativePath: record.relativePath, moveID: record.id, mountPoint: mount)
        guard Sentinel.matches(sentinel, moveID: record.id, recipeID: record.recipeID, volumeToken: record.volume.token, relativePath: record.relativePath) else {
            return .refused("The drive's check file is missing or different.")
        }
        switch Held.evaluate(facts: facts, record: record, check: check) {
        case .clear: break
        case .hold(let reason): return .held(reason)
        }
        if record.method == .defaults { return unparkSetting(record, mount: mount, home: home) }

        let macPath = Fs.expand(record.macPath, home: home)
        guard let note = journal.lastPlaceholder else { return .refused("Outboard has no record of the note it left, so it leaves the path alone.") }
        switch Guard.verifyStamp(path: macPath, expected: note) {
        case .unchanged: break
        case .missing: return .refused("The note is gone from the path.")
        case .changed(let why): return .refused(why)
        case .unreadable(let e): return .failed("The path could not be looked at (error \(e)).")
        }
        let subject = JournalSubject(record)
        guard Journal.intent(.unpark, subject: subject, home: home, src: macPath, stamp: note, note: "unpark") else { return .refused(Say.journalBlocked) }

        var problem: String?
        var code: Int32?
        let ctx = RuleContext(record: record, home: home, mountPoint: mount)
        let target = mount + "/" + record.relativePath
        let away = Renamer.perform(.unpark, from: macPath, to: Park.nextName("note", moveID: record.id, home: home), ctx: ctx, subject: subject,
                                   home: home, expected: note)
        if away.isRenamed {
            let parkedLink = Park.latestName("link", moveID: record.id, home: home)
            if Fs.linkTarget(parkedLink) == target {
                // The parked link already says where the drive is: it returns by rename.
                let back = Renamer.perform(.unpark, from: parkedLink, to: macPath, ctx: ctx, subject: subject, home: home, expected: journal.lastLink?.stamp)
                if !back.isRenamed { problem = back.text }
                if case .failed(let e, _) = back { code = e }
            } else {
                let made = Linker.create(linkPath: macPath, target: target, ctx: ctx, volume: record.volume, mountPoint: mount, subject: subject,
                                         home: home, step: .redirect)
                if case .created = made {} else { problem = made.text }
                if case .failed(let e, _) = made { code = e }
            }
            // The note is already out of the way: if the link did not come, the path must not stay empty (an app would start fresh on
            // the Mac), so a new note stands in again and the next pass tries once more. (It refuses if anything is at the path now.)
            if problem != nil, Fs.info(macPath).err == ENOENT {
                let planted = Placeholder.create(at: macPath, driveName: record.volume.name, removal: journal.lastRemoval ?? facts.removal ?? .unknown,
                                                 subject: subject, home: home)
                if case .created = planted { problem = (problem ?? "") + " A note stands at the path again." }
                else { problem = (problem ?? "") + " The note could not be put back: " + planted.text }
            }
        } else {
            problem = away.text
        }
        if problem == nil, case .failed(let why) = Health.check(record, home: home, mountPoint: mount) { problem = why }
        Journal.result(.unpark, subject: subject, home: home, status: problem == nil ? .ok : .failed, errno: code, src: macPath, to: target, note: "unpark")
        if let problem { return .failed(problem) }
        VolumeWatcher.clearRemoval(of: record.volume.uuid)
        return .unparked
    }

    /// A `defaults` relocation has no note: the setting is written again with the path under the drive's current mount point.
    private static func unparkSetting(_ record: RelocationRecord, mount: String, home: String) -> UnparkResult {
        guard let recipe = Catalogue.recipe(record.recipeID), let domain = record.defaultsDomain else {
            return .failed("This relocation has no recorded setting.")
        }
        let writes = Health.recomputedWrites(record, mountPoint: mount)
        switch DefaultsRedirect.reapply(domain: domain, writes: writes, subject: JournalSubject(record), recipe: recipe, home: home) {
        case .applied: break
        case .refused(let why), .notAttempted(let why): return .refused(why)
        case .exists: return .failed("Something is already there.")
        case .failed(_, let message): return .failed(message)
        }
        if case .failed(let why) = Health.check(record, home: home, mountPoint: mount, writes: writes) { return .failed(why) }
        VolumeWatcher.clearRemoval(of: record.volume.uuid)
        return .unparked
    }
}
