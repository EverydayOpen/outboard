import Darwin
import Foundation
import OutboardCore

/// The Drive Guard's one function (BUILD_PLAN §4.5, §5): look at every watched relocation, classify it with Core's twelve-row
/// `GuardPolicy`, do what the state asks through the single-site verbs, and publish the result. It is idempotent and one pass runs
/// at a time, so a missed notification costs seconds, not correctness. It parks only when the drive is absent *by UUID*, after a
/// debounce, never inside the launch or wake grace; it unparks only when every precondition holds; it never touches a folder that
/// is not Outboard's. While Outboard is not running nothing guards anything (said in the app).
enum Reconcile {
    private static let lock = NSLock()
    private static var busy = false
    private static var launchedAt: Date?
    private static var graceUntil = Date.distantPast
    private static var seen = Set<String>()
    private static var held: [String: HeldReason] = [:]
    private static var lastReturn: [String: ReturnReport] = [:]
    private static var lastFacts: [String: GuardFacts] = [:]
    private static var lastSnapshot = GuardSnapshot.empty
    /// Relocations whose last park attempt failed or was refused. Short-lived: `publish` forgets an entry as soon as the relocation is no
    /// longer waiting to be parked, and a park that works removes it. It only lets the banner say "couldn't" instead of "put a note".
    private static var parkFailed = Set<String>()

    /// A clean return samples at most this many bytes (200 files, but not hundreds of gigabytes of model files).
    static let sampleByteBudget: UInt64 = 4_000_000_000

    private static func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    #if DEBUG
    /// Tests only: forget everything the guard remembers between passes, or pretend the app launched at `date`.
    static func resetForTests() {
        locked {
            busy = false
            launchedAt = nil
            graceUntil = .distantPast
            seen = []
            held = [:]
            lastReturn = [:]
            lastFacts = [:]
            lastSnapshot = .empty
            parkFailed = []
        }
    }

    static func setLaunchedAt(_ date: Date) { locked { launchedAt = date } }
    #endif

    // MARK: - The pass

    static func run(_ trigger: ReconcileTrigger, home: String) async -> GuardSnapshot {
        let proceed = locked { () -> Bool in
            if busy { return false }
            busy = true
            if launchedAt == nil { launchedAt = Date() }
            if trigger == .wake { graceUntil = Date().addingTimeInterval(Limits.wakeGraceSeconds) }
            return true
        }
        guard proceed else { return locked { lastSnapshot } }
        defer { locked { busy = false } }

        let entries = Journal.loadAll(home: home)
        let watched = GuardPolicy.watched(RelocationFold.records(from: entries, home: home))
        guard let mounted = VolumeIdentity.all() else { return locked { lastSnapshot } }
        locked { for m in mounted { if let u = m.uuid { seen.insert(u.uppercased()) } } }
        VolumeWatcher.noteStillMounted(mounted.compactMap(\.uuid))
        var facts = gatherAll(watched, entries: entries, mounted: mounted, home: home)

        // Park only after the debounce: the drive must still be gone five seconds later (a flicker on wake or a re-seat is not a removal).
        let wantPark = watched.filter { r in
            guard let f = facts[r.id], GuardPolicy.action(for: GuardPolicy.classify(f), record: r) == .park else { return false }
            return mayPark(r)
        }
        if !wantPark.isEmpty {
            try? await Task.sleep(nanoseconds: UInt64(Limits.parkDebounceSeconds * 1_000_000_000))
            if let again = VolumeIdentity.all() {
                for r in wantPark { facts[r.id] = gather(r, entries: entries, mounted: again, home: home) ?? facts[r.id] }
            }
        }

        if MutationGate.tryEnter() {
            for record in watched {
                guard let f = facts[record.id] else { continue }
                let state = GuardPolicy.classify(f)
                switch GuardPolicy.action(for: state, record: record) {
                case .none, .reportOnly:
                    break
                case .park:
                    guard mayPark(record) else { break }
                    park(record, facts: f, entries: entries, home: home)
                case .unpark:
                    await unparkIfAllowed(record, facts: f, entries: entries, trigger: trigger, home: home)
                case .recreate:
                    recreate(record, facts: f, home: home)
                case .retarget:
                    retarget(record, facts: f, entries: entries, home: home)
                }
            }
            MutationGate.leave()
            // What the actions changed is read again, so the published state is the state on disk.
            let after = Journal.loadAll(home: home)
            let records = GuardPolicy.watched(RelocationFold.records(from: after, home: home))
            if let again = VolumeIdentity.all() {
                for r in records { facts[r.id] = gather(r, entries: after, mounted: again, home: home) ?? facts[r.id] }
            }
            return publish(records, facts)
        }
        return publish(watched, facts)
    }

    private static func publish(_ records: [RelocationRecord], _ facts: [String: GuardFacts]) -> GuardSnapshot {
        locked {
            for (id, f) in facts { lastFacts[id] = f }
            parkFailed = parkFailed.filter { id in facts[id].map { GuardPolicy.classify($0) == .park } ?? false }
            let snapshot = GuardPolicy.snapshot(records: records, facts: facts, held: held, lastReturn: lastReturn, parkFailed: parkFailed)
            lastSnapshot = snapshot
            return snapshot
        }
    }

    private static func mayPark(_ record: RelocationRecord) -> Bool {
        let now = Date()
        let (grace, launched, wasSeen) = locked { (graceUntil, launchedAt, seen.contains(record.volume.uuid.uppercased())) }
        if now < grace { return false }
        if !wasSeen, let launched, now.timeIntervalSince(launched) < Limits.launchGraceSeconds { return false }
        return true
    }

    // MARK: - Facts

    private static func gatherAll(_ records: [RelocationRecord], entries: [JournalEntry], mounted: [VolumeIdentity.Mounted], home: String) -> [String: GuardFacts] {
        var out: [String: GuardFacts] = [:]
        for r in records { if let f = gather(r, entries: entries, mounted: mounted, home: home) ?? locked({ lastFacts[r.id] }) { out[r.id] = f } }
        return out
    }

    /// `lstat` and mount facts about one relocation. nil = something could not be read (a setting did not answer): the caller keeps the
    /// last facts instead of guessing.
    static func gather(_ record: RelocationRecord, entries: [JournalEntry], mounted: [VolumeIdentity.Mounted], home: String) -> GuardFacts? {
        let journal = JournalFacts(moveID: record.id, all: entries, home: home)
        let macPath = Fs.expand(record.macPath, home: home)
        let drive = mounted.first { VolumeIdentity.same($0.uuid, record.volume.uuid) }

        var presence = DrivePresence.absent
        var mountPoint: String?
        if let drive {
            mountPoint = drive.mountPoint
            if drive.isReadOnly {
                presence = .mountedReadOnlyOrLocked
            } else if let link = journal.lastLink {
                presence = link.target == drive.mountPoint + "/" + record.relativePath ? .mountedAtRecordedPath : .mountedElsewhere
            } else {
                presence = .mountedAtRecordedPath
            }
        }

        var sentinel = SentinelFact.missing
        if let mountPoint {
            let path = OutboardRoot.sentinelPath(mountPoint: mountPoint, relativePath: record.relativePath, moveID: record.id)
            if Fs.exists(path) {
                let found = OutboardRoot.readSentinel(record.volume, relativePath: record.relativePath, moveID: record.id, mountPoint: mountPoint)
                sentinel = Sentinel.matches(found, moveID: record.id, recipeID: record.recipeID, volumeToken: record.volume.token,
                                            relativePath: record.relativePath) ? .ok : .wrong
            }
        }

        // What stands at the path. For a `defaults` relocation the path is the setting: link = the value the move wrote,
        // placeholder = the prior (or neutral) value, other = something else (GuardPolicy documents the mapping).
        var path = PathKind.missing
        var foreign = false
        var resolvedOnDrive = Tri.unknown
        if record.method == .defaults, let domain = record.defaultsDomain {
            guard let state = Recover.settingState(record, domain: domain, mount: mountPoint, home: home) else { return nil }
            let setting = state.fact
            // No link text to compare: the drive is "mounted elsewhere" when the setting still holds the old mount path.
            if setting == .new, !state.atMount, presence == .mountedAtRecordedPath { presence = .mountedElsewhere }
            switch setting {
            case .new: path = .link
            case .prior: path = .placeholder
            case .other, .notApplicable: path = .other
            }
            if let mountPoint { resolvedOnDrive = Tri(Fs.isPlainDirectory(mountPoint + "/" + record.relativePath)) }
        } else {
            let at = Fs.info(macPath)
            if at.err == 0 {
                switch Fs.kind(at.st) {
                case .symlink:
                    if let link = journal.lastLink, Fs.linkTarget(macPath) == link.target {
                        path = .link
                    } else {
                        path = .other
                        foreign = true
                    }
                    if mountPoint != nil, let resolved = VolumeIdentity.volumeUUID(ofResolved: macPath) {
                        resolvedOnDrive = Tri(VolumeIdentity.same(resolved, record.volume.uuid))
                    }
                case .file:
                    path = Redirect.isNote(at.st) && journal.lastPlaceholder.map({ Fs.stamp(at.st).isSameObject(as: $0) }) == true ? .placeholder : .other
                default:
                    path = .other
                }
            } else if at.err != ENOENT && at.err != ENOTDIR {
                return nil
            }
        }

        var blockedCode: Int32?
        if let mountPoint {
            let code = record.method == .defaults || path != .link ? Fs.targetErrno(mountPoint + "/" + record.relativePath) : Fs.targetErrno(macPath)
            if code != 0 { blockedCode = code }
        }

        // The journal's word on how the drive left only counts while the note it was written with still stands; a drive that is
        // gone with no live notification is `.unknown` (a full check), never assumed to have been ejected.
        let journaled = path == .placeholder ? journal.lastRemoval : nil
        let removal = (VolumeWatcher.removal(of: record.volume.uuid) ?? journaled) ?? (presence == .absent ? RemovalKind.unknown : nil)
        var app = RunState.notRunning
        if let recipe = Catalogue.recipe(record.recipeID) {
            app = RunningCheck.state(recipe: recipe, snapshot: RunningApps.snapshot(for: recipe, home: home, includeHandles: false))
        } else {
            app = .unknown
        }
        return GuardFacts(path: path, drive: presence, sentinel: sentinel, targetOnRecordedVolume: resolvedOnDrive, targetErrno: blockedCode, hasOurMarker: false,
                          placeholderUnchanged: path == .placeholder, linkIsForeign: foreign, removal: removal, targetApp: app,
                          sameNameDifferentDrive: VolumeIdentity.sameNameDifferentDrive(record.volume))
    }

    // MARK: - Actions

    private static func park(_ record: RelocationRecord, facts: GuardFacts, entries: [JournalEntry], home: String) {
        let journal = JournalFacts(moveID: record.id, all: entries, home: home)
        let result = Park.park(record, facts: journal, removal: facts.removal ?? .unknown, home: home)
        let failed: Bool
        switch result {
        case .refused, .failed: failed = true
        case .parked, .reverted, .leftAlone, .notNeeded: failed = false
        }
        locked {
            if failed { parkFailed.insert(record.id) } else { parkFailed.remove(record.id) }
            return
        }
    }

    private static func recreate(_ record: RelocationRecord, facts: GuardFacts, home: String) {
        // A rebuild with the drive here must not skip the check an unclean removal asks for.
        if record.needsCheckBeforeReconnect, facts.drive != .absent {
            locked { held[record.id] = .uncleanRemoval }
            return
        }
        _ = Relink.recreate(record, facts: facts, home: home)
    }

    private static func retarget(_ record: RelocationRecord, facts: GuardFacts, entries: [JournalEntry], home: String) {
        let journal = JournalFacts(moveID: record.id, all: entries, home: home)
        if case .held(let reason) = Relink.retarget(record, facts: facts, journal: journal, home: home) {
            locked { held[record.id] = reason }
        }
    }

    /// The drive is back and the note is still ours. The cheap preconditions are judged first (a probe result that passes), so a
    /// running app costs nothing; only then are files hashed. After an unclean removal nothing is hashed or reconnected until the user
    /// presses "Check and reconnect".
    private static func unparkIfAllowed(_ record: RelocationRecord, facts: GuardFacts, entries: [JournalEntry], trigger: ReconcileTrigger, home: String) async {
        let needsFull = record.needsCheckBeforeReconnect || (facts.removal?.needsCheckBeforeReconnect ?? false)
        let probe = ReturnCheckResult(quickPassed: true, hashed: 0, mismatches: 0, fullCheck: needsFull)
        if case .hold(let reason) = Held.evaluate(facts: facts, record: record, check: probe) {
            locked { held[record.id] = reason }
            return
        }
        if needsFull {
            locked { held[record.id] = .uncleanRemoval }
            return
        }
        guard let mount = VolumeIdentity.currentMountPoint(of: record.volume) else { return }
        let check = await Task.detached(priority: .utility) { Reconcile.returnCheck(record, mount: mount, full: false, home: home, isCancelled: { false }, progress: { _, _ in }) }.value
        let journal = JournalFacts(moveID: record.id, all: entries, home: home)
        finish(record, Unpark.unpark(record, facts: facts, journal: journal, check: check, home: home), check: check, mount: mount, journal: journal)
    }

    private static func finish(_ record: RelocationRecord, _ result: UnparkResult, check: ReturnCheckResult, mount: String, journal: JournalFacts) {
        locked {
            switch result {
            case .unparked:
                held[record.id] = nil
                let renamed = journal.lastLink.map { $0.target != mount + "/" + record.relativePath } ?? false
                lastReturn[record.id] = ReturnReport(check, driveRenamed: renamed)
            case .held(let reason):
                held[record.id] = reason
                lastReturn[record.id] = ReturnReport(check)
            case .refused, .failed:
                break
            }
        }
    }

    // MARK: - The checks on return

    /// Looks at what the drive holds now against the manifest taken at copy time, and hashes files that have not changed since: the
    /// bounded sample after a clean return, every unchanged file after "Check and reconnect". Reads the drive; changes nothing. Files that
    /// apps have written since are counted, never compared.
    static func returnCheck(_ record: RelocationRecord, mount: String, full: Bool, home: String, isCancelled: () -> Bool,
                            progress: (Int, Int) -> Void) -> ReturnCheckResult {
        let folder = mount + "/" + record.relativePath
        guard let manifest = ManifestStore.load(moveID: record.id, home: home, driveFolder: Fs.parent(of: folder)),
              let now = SizeScanner.walk(folder, xattrs: false) else {
            return ReturnCheckResult(quickPassed: false, hashed: 0, mismatches: 0, fullCheck: full)
        }
        let paths = full ? ReturnCheck.unchanged(manifest: manifest.entries, current: now.entries)
                         : ReturnCheck.sample(manifest: manifest.entries, current: now.entries, limit: Limits.returnSampleFiles, seed: seed(for: record.id))
        let hashed = Verifier.compareHashes(root: folder, manifest: manifest.entries, paths: paths, byteBudget: full ? nil : sampleByteBudget,
                                            isCancelled: isCancelled, progress: progress)
        return ReturnCheck.listingResult(manifest: manifest.entries, current: now.entries, hashed: hashed.hashed,
                                         hashMismatches: hashed.mismatched.count + hashed.unreadable.count, fullCheck: full)
    }

    /// The same sample for the same move every time (FNV-1a over the move id).
    private static func seed(for id: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x0000_0100_0000_01b3
        }
        return h
    }

    // MARK: - What the user asks for

    /// "Check and reconnect": after a drive was removed without ejecting, every file that has not changed since the copy is hashed, and
    /// only if all match is the redirect put back. The hashing reads the drive and changes nothing; the unpark afterwards is one
    /// journaled mutation.
    static func checkAndReconnect(_ moveID: String, home: String, progress: @escaping @Sendable (MoveProgress) -> Void) async -> MoveOutcome {
        let entries = Journal.loadAll(home: home)
        guard let record = RelocationFold.records(from: entries, home: home).first(where: { $0.id == moveID }), record.state.isActive else {
            return MoveOutcome(action: .checkAndReconnect, moveID: moveID, state: .aborted, ok: false, message: "That move is not active.")
        }
        func stop(_ message: String) -> MoveOutcome { MoveOutcome(action: .checkAndReconnect, moveID: moveID, state: record.state, ok: false, message: message) }
        guard let mount = VolumeIdentity.currentMountPoint(of: record.volume), VolumeIdentity.matches(record.volume, mountPoint: mount) else {
            return stop("Plug \(record.volume.label) in first.")
        }
        guard MutationGate.tryEnter() else { return stop(Say.busy) }
        defer { MutationGate.leave() }
        let subject = JournalSubject(record)
        guard Journal.intent(.checkAndReconnect, subject: subject, home: home, vol: record.volume.uuid, volName: record.volume.name) else { return stop(Say.journalBlocked) }

        let started = Date()
        let cancel = Flag()
        let check: ReturnCheckResult = await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                Reconcile.returnCheck(record, mount: mount, full: true, home: home, isCancelled: { cancel.isSet }, progress: { done, total in
                    progress(MoveProgress(moveID: moveID, phase: .verifying, filesDone: done, filesTotal: total, elapsedSeconds: Date().timeIntervalSince(started)))
                })
            }.value
        } onCancel: {
            cancel.set()
        }
        Journal.result(.checkAndReconnect, subject: subject, home: home, status: check.passed ? .ok : .mismatch,
                       counts: JournalCounts(differences: check.mismatches, sampled: check.hashed, sampleOf: check.sampleOf))

        // The result line cleared the "check first" mark; the records and facts are read again before anything is reconnected.
        let after = Journal.loadAll(home: home)
        guard let fresh = RelocationFold.records(from: after, home: home).first(where: { $0.id == moveID }), let mounted = VolumeIdentity.all(),
              var facts = gather(fresh, entries: after, mounted: mounted, home: home) else {
            return stop("The check ran, but the move could not be read again.")
        }
        facts.removal = nil
        let journal = JournalFacts(moveID: moveID, all: after, home: home)
        let result: UnparkResult
        if facts.path == .missing && fresh.method == .symlink {
            result = Relink.recreate(fresh, facts: facts, home: home)
        } else {
            result = Unpark.unpark(fresh, facts: facts, journal: journal, check: check, home: home)
        }
        finish(fresh, result, check: check, mount: mount, journal: journal)
        switch result {
        case .unparked:
            return MoveOutcome(action: .checkAndReconnect, moveID: moveID, state: fresh.state, ok: true,
                               message: "Checked \(Format.count(check.hashed, "file")) that haven't changed since they were copied: all matched. \(Format.count(check.changedSince, "file")) have changed since and weren't compared. Connected again.")
        case .held(let reason):
            return MoveOutcome(action: .checkAndReconnect, moveID: moveID, state: fresh.state, ok: false, message: heldText(reason, name: fresh.recipeName, mismatches: check.mismatches))
        case .refused(let why), .failed(let why):
            return stop(why)
        }
    }

    /// Why an unpark waits, in a sentence.
    static func heldText(_ reason: HeldReason, name: String, mismatches: Int) -> String {
        switch reason {
        case .uncleanRemoval: return "Not reconnected: Outboard did not see the drive being ejected, so the files have to be checked first."
        case .appRunning: return "\(name) is running. Quit it and Outboard connects it again."
        case .sampleMismatch: return "\(Format.count(mismatches, "file")) differ from when they were copied. Nothing was reconnected."
        case .wrongDrive: return "The drive that is connected is not the one the data was moved to. Nothing was changed."
        case .quickCheckFailed: return "The files on the drive don't match the list made when they were copied. Nothing was reconnected."
        case .needsPermission: return "macOS blocked access to the drive."
        case .readOnlyOrLocked: return "The drive is read-only or locked, so nothing was reconnected."
        }
    }

    /// "Set it aside and reconnect" for a Conflict: what appeared at the path while the drive was away is renamed
    /// `<name>.while-away-<date>` (never merged, never deleted), then the guard puts things back on its next pass.
    static func setAsideAndReconnect(_ moveID: String, home: String, now: Date = Date()) async -> MoveOutcome {
        let entries = Journal.loadAll(home: home)
        guard let record = RelocationFold.records(from: entries, home: home).first(where: { $0.id == moveID }), record.state.isActive else {
            return MoveOutcome(action: .setAsideAndReconnect, moveID: moveID, state: .aborted, ok: false, message: "That move is not active.")
        }
        func stop(_ message: String) -> MoveOutcome { MoveOutcome(action: .setAsideAndReconnect, moveID: moveID, state: record.state, ok: false, message: message) }
        guard let recipe = Catalogue.recipe(record.recipeID) else { return stop("Outboard does not know this recipe, so nothing was changed.") }
        guard record.method == .symlink else { return stop("This move uses a setting, not a folder, so there is nothing to set aside.") }
        guard MutationGate.tryEnter() else { return stop(Say.busy) }
        defer { MutationGate.leave() }
        switch RunningCheck.state(recipe: recipe, snapshot: RunningApps.snapshot(for: recipe, home: home)) {
        case .notRunning: break
        case .running: return stop("\(record.recipeName) is running. Quit it and try again.")
        case .unknown: return stop(Say.unknownRunning)
        }
        let macPath = Fs.expand(record.macPath, home: home)
        let mount = VolumeIdentity.currentMountPoint(of: record.volume)
        let ctx = RuleContext(record: record, home: home, mountPoint: mount)
        var target = macPath + Names.whileAwayInfix + dateStamp(now)
        var n = 1
        while Fs.exists(target) {
            n += 1
            target = macPath + Names.whileAwayInfix + dateStamp(now) + "-" + String(n)
        }
        let moved = Renamer.perform(.setAsideForeign, from: macPath, to: target, ctx: ctx, subject: JournalSubject(record), home: home, expected: nil)
        guard moved.isRenamed else { return stop(moved.text) }
        return MoveOutcome(action: .setAsideAndReconnect, moveID: moveID, state: record.state, ok: true,
                           message: "Set it aside as \(Fs.leaf(of: target)). Outboard will connect \(record.recipeName) again when the drive is ready.")
    }

    private static func dateStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Forget what the guard knows about a relocation that was closed.
    static func forgetState(of moveID: String) {
        locked {
            held[moveID] = nil
            lastReturn[moveID] = nil
            lastFacts[moveID] = nil
            parkFailed.remove(moveID)
        }
    }
}
