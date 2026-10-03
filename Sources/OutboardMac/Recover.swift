import Darwin
import Foundation
import OutboardCore

/// Crash recovery (BUILD_PLAN §4.4): on every launch and every mount the journal is folded, the disk is looked at with `lstat` and
/// the mount table, Core's `Recovery.decide` (pure, exhaustively tested) says what to do, and the action is carried out through the
/// same single-site verbs and journal rules as a normal move. A crash before the original was renamed aborts the move (no resume in
/// v1); after the rename the disk is observed and the move is finished or rolled back; anything unrecognised shows the facts and
/// touches nothing.
enum Recover {
    /// The eight small facts about one record. `lstat` and mount facts only; no file is opened except our own sentinel.
    static func gatherFacts(_ record: RelocationRecord, home: String) -> RecoveryFacts {
        let all = Journal.loadAll(home: home)
        let journal = JournalFacts(moveID: record.id, all: all, home: home)
        let macPath = Fs.expand(record.macPath, home: home)
        let before = macPath + Names.beforeMoveSuffix
        let mount = VolumeIdentity.currentMountPoint(of: record.volume)
        let driveMatches = mount.map { VolumeIdentity.matches(record.volume, mountPoint: $0) } ?? false
        var sentinelOK = false
        if driveMatches, let mount {
            let found = OutboardRoot.readSentinel(record.volume, relativePath: record.relativePath, moveID: record.id, mountPoint: mount)
            sentinelOK = Sentinel.matches(found, moveID: record.id, recipeID: record.recipeID, volumeToken: record.volume.token, relativePath: record.relativePath)
        }

        // X: what is at the path.
        let at = Fs.info(macPath)
        var path = PathKind.other
        if at.err == ENOENT || at.err == ENOTDIR {
            path = .missing
        } else if at.err == 0 {
            switch Fs.kind(at.st) {
            case .directory:
                let recorded = journal.sourceStamp ?? journal.setAsideStamp
                path = recorded.map { Fs.stamp(at.st).isSameObject(as: $0) ? PathKind.real : .other } ?? .real
            case .symlink:
                if let link = journal.lastLink, Fs.linkTarget(macPath) == link.target { path = .link }
            case .file:
                if Redirect.isNote(at.st), let note = journal.lastPlaceholder, Fs.stamp(at.st).isSameObject(as: note) { path = .placeholder }
            case .other:
                break
            }
        }

        // B: the renamed original.
        let b = Fs.info(before)
        let beforePresent = b.err == 0 && Fs.kind(b.st) == .directory
            && (journal.setAsideStamp.map { Fs.stamp(b.st).isSameObject(as: $0) } ?? true)

        // S and F: the copy on the drive.
        var staging = false
        var published = false
        if driveMatches, let mount {
            staging = Fs.exists(mount + "/" + Fs.parent(of: record.relativePath) + "/" + Names.stagingPrefix + record.id)
            published = Fs.isPlainDirectory(mount + "/" + record.relativePath)
        }

        // K: the setting, for a `defaults` relocation.
        var setting = SettingFact.notApplicable
        if record.method == .defaults, let domain = record.defaultsDomain {
            setting = settingFact(record, domain: domain, mount: mount, home: home) ?? .other
        }

        var healthy = false
        if driveMatches, sentinelOK, let mount { healthy = Health.check(record, home: home, mountPoint: mount).isHealthy }
        let parked = Fs.exists(Park.parkedFolder(moveID: record.id, home: home) + "/link")
        // R: a later return of this very relocation (same path, same copy on the same drive) that reached Swapped.
        let returnSwapped = record.direction == .toDrive && RelocationFold.records(from: all).contains {
            $0.direction == .returnToMac && $0.state == .swapped && $0.createdAt >= record.createdAt && $0.macPath == record.macPath
                && $0.relativePath == record.relativePath && VolumeIdentity.same($0.volume.uuid, record.volume.uuid)
        }
        return RecoveryFacts(drivePresent: driveMatches && sentinelOK, path: path, beforeMovePresent: beforePresent, stagingPresent: staging,
                             publishedPresent: published, setting: setting, healthPasses: healthy, parkedLinkPresent: parked,
                             returnSwapped: returnSwapped)
    }

    /// `new` = every key reads as the value the move wrote (at the drive's current mount point, or as recorded); `prior` = every key
    /// that putting it back writes reads as that (a key with nothing to write is left out of the comparison, because the keys that are
    /// written back, like Xcode's mode key, are what select the default location; only when nothing at all is written back must the
    /// keys be absent); anything else is `other`.
    /// nil = a key could not be read (the tool did not answer): the caller does not guess.
    static func settingFact(_ record: RelocationRecord, domain: String, mount: String?, home: String? = nil) -> SettingFact? {
        settingState(record, domain: domain, mount: mount, home: home)?.fact
    }

    /// `settingFact`, and whether the setting holds the values for the drive's *current* mount point (false: it still holds the path
    /// the drive had before it came back under another name, so the guard has to write it again).
    ///
    /// The journal keeps a value under the home folder as `~/...`; with `home` those are expanded here (`RelocationFold` already does it
    /// for a record folded with `home`, and expanding twice changes nothing).
    static func settingState(_ record: RelocationRecord, domain: String, mount: String?, home: String? = nil) -> (fact: SettingFact, atMount: Bool)? {
        var record = record
        if let home {
            record.defaultsWrites = record.defaultsWrites.map { DefaultsWrite(key: $0.key, type: $0.type, value: PathText.expandTilde($0.value, home: home)) }
            record.defaultsRevert = record.defaultsRevert.map { DefaultsWrite(key: $0.key, type: $0.type, value: PathText.expandTilde($0.value, home: home)) }
        }
        var current: [String: String?] = [:]
        for w in record.defaultsWrites {
            guard let value = DefaultsRedirect.currentValue(domain: domain, key: w.key, type: w.type) else { return nil }
            current[w.key] = .some(value)
        }
        func matches(_ expected: [DefaultsWrite]) -> Bool {
            !expected.isEmpty && expected.allSatisfy { w in current[w.key].map { $0 == w.value } ?? false }
        }
        let atMount = mount.map { matches(Health.recomputedWrites(record, mountPoint: $0)) } ?? false
        if atMount || matches(record.defaultsWrites) { return (.new, atMount) }
        let revert = Dictionary(record.defaultsRevert.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        let writtenBack = record.defaultsWrites.contains { revert[$0.key] != nil }
        let isPrior = record.defaultsWrites.allSatisfy { w in
            guard let seen = current[w.key] else { return false }
            if let want = revert[w.key] { return seen == want }
            return writtenBack || seen == nil
        }
        return (isPrior ? .prior : .other, false)
    }

    // MARK: - Doing what the table says

    /// One pass over every record that is not finished. Skipped entirely while a mutation is in flight (the move that is running
    /// would look interrupted). Returns the outcomes of the actions taken, for the activity log and the screens.
    @discardableResult
    static func run(home: String) -> [MoveOutcome] {
        guard MutationGate.tryEnter() else { return [] }
        defer { MutationGate.leave() }
        var outcomes: [MoveOutcome] = []
        let entries = Journal.loadAll(home: home)
        for record in RelocationFold.records(from: entries, home: home) where !record.state.isTerminal {
            let facts = gatherFacts(record, home: home)
            let action = Recovery.decide(record: record, facts: facts)
            if let outcome = apply(action, record: record, facts: facts, home: home) { outcomes.append(outcome) }
        }
        return outcomes
    }

    /// Carries out one action. nil = nothing to do or nothing Outboard may do (the guard's own pass handles notes, links and unparking).
    static func apply(_ action: RecoveryAction, record: RelocationRecord, facts: RecoveryFacts, home: String) -> MoveOutcome? {
        let subject = JournalSubject(record)
        let message = Recovery.message(for: action, record: record)
        func done(_ state: MoveState, ok: Bool = true) -> MoveOutcome {
            MoveOutcome(action: .recover, moveID: record.id, state: state, ok: ok, message: message)
        }
        switch action {
        case .noop, .remainSwapped, .remainConfirmed, .createPlaceholder, .unpark, .recreateLink:
            return nil
        case .markReturned:
            // The return swapped its copy in; this record's closing line was cut off.
            guard Journal.result(.returned, subject: subject, home: home, status: .ok, state: .returned, note: "closed after an interruption") else { return nil }
            return done(.returned)
        case .needsAttention:
            return done(record.state, ok: false)
        case .abort(let reason, _):
            guard Journal.result(.abort, subject: subject, home: home, status: .ok, abort: reason, state: .aborted, note: message) else { return nil }
            return MoveOutcome(action: .recover, moveID: record.id, state: .aborted, ok: true, abort: reason, message: message)
        case .rollbackOriginal, .continueRollback, .setAsideForeignThenRollback:
            let final = Recovery.resultingState(of: action, record: record)
            return Rollback.recover(record, final: final, abort: final == .aborted ? .interrupted : nil, message: message, home: home)
        case .adoptSwapped:
            // The redirect is in place and healthy: the lines the crash cut off are written now.
            guard Journal.result(.redirect, subject: subject, home: home, status: .ok, note: "adopted after an interruption") else { return nil }
            Journal.result(.swapped, subject: subject, home: home, status: .ok, state: .swapped, note: "adopted after an interruption")
            return done(.swapped)
        case .markTrashedUnrecorded:
            Journal.result(.trash, subject: subject, home: home, status: .ok, state: .originalTrashed, note: "result not recorded")
            return done(.originalTrashed)
        case .finishPark:
            Journal.result(.park, subject: subject, home: home, status: .ok, src: Fs.expand(record.macPath, home: home),
                           note: JournalNote.park(VolumeWatcher.removal(of: record.volume.uuid) ?? .unknown))
            return done(record.state)
        }
    }
}
