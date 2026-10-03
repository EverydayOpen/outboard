import Foundation

/// The Drive Guard and the launch recovery of the demo, written against the in-memory tree. The decisions are the real Core ones
/// (`GuardPolicy.classify`, `GuardPolicy.action`, `GuardPolicy.snapshot` with its `BannerText`, `Held.evaluate`, `Recovery.decide`);
/// this file only gathers the facts from the tree and carries the chosen action out through the same rules and the same journal
/// lines a live reconcile writes.
extension DemoState {
    // MARK: Facts

    func guardFacts(_ r: RelocationRecord) -> GuardFacts {
        let macPath = absolute(r.macPath)
        let present = mounted.contains(r.volume.uuid)
        let node = tree.node(macPath)
        let path: PathKind
        if r.method == .defaults {
            // A setting has no link to look at: it points at the drive until it was put back (GuardPolicy's note on defaults).
            path = settingReverted.contains(r.id) ? .placeholder : .link
        } else {
            switch node?.kind {
            case .link?: path = .link
            case .note?: path = .placeholder
            case .directory?: path = .other
            case nil: path = .missing
            }
        }
        let mount = mountPoint(of: r.volume.uuid) ?? ""
        let recipeFolder = r.relativePath.split(separator: "/").dropLast().joined(separator: "/")
        let sentinelPath = mount + "/" + recipeFolder + "/" + Names.sentinelPrefix + r.id + Names.sentinelSuffix
        var onVolume: Tri = .unknown
        if present {
            if r.method == .defaults { onVolume = .yes } else if let t = node?.target { onVolume = Tri(t.hasPrefix(mount + "/")) }
        }
        return GuardFacts(path: path, drive: present ? .mountedAtRecordedPath : .absent,
                          sentinel: present ? (tree.has(sentinelPath) ? .ok : .missing) : .ok,
                          targetOnRecordedVolume: onVolume, hasOurMarker: node?.ours ?? false, removal: removal[r.volume.uuid],
                          targetApp: running.contains(r.recipeID) ? .running : .notRunning,
                          sameNameDifferentDrive: mounted.contains { $0 != r.volume.uuid && volumes[$0]?.name == r.volume.name })
    }

    /// What the checks on return found for this relocation: the full check once "Check and reconnect" passed, otherwise the quick
    /// check and the bounded sample, run against the manifest the move took (the demo's synthetic list stands in for the listing).
    func returnCheck(_ r: RelocationRecord) -> ReturnCheckResult? {
        if let full = checks[r.id] { return full }
        guard let plan = plans[r.id] else { return nil }
        let entries = DemoEntries.source(plan)
        return ReturnCheckResult(quickPassed: ReturnCheck.quick(manifest: entries, current: entries), hashed: min(Limits.returnSampleFiles, r.fileCount),
                                 mismatches: 0, fullCheck: false, sampleOf: r.fileCount)
    }

    /// Why an unpark has to wait, from the real `Held.evaluate`; nil when it may go ahead (or when nothing is waiting).
    func heldReason(_ r: RelocationRecord, _ f: GuardFacts) -> HeldReason? {
        guard GuardPolicy.classify(f) == .restore else { return nil }
        if case .hold(let why) = Held.evaluate(facts: f, record: r, check: returnCheck(r)) { return why }
        return nil
    }

    func active() -> [RelocationRecord] { GuardPolicy.watched(records()) }

    // MARK: One pass

    func guardPass() {
        justUnparked = []
        for r in active() {
            let f = guardFacts(r)
            switch GuardPolicy.action(for: GuardPolicy.classify(f), record: r) {
            case .park: park(r)
            case .unpark: if heldReason(r, f) == nil { unpark(r) }
            case .recreate: recreate(r, f)
            case .retarget, .reportOnly, .none: break
            }
        }
        // A drive's removal is forgotten once nothing of it is waiting any more.
        for uuid in Set(justUnparked.map(\.volume.uuid)) where !active().contains(where: { $0.volume.uuid == uuid && guardFacts($0).path == .placeholder }) {
            removal.removeValue(forKey: uuid)
        }
    }

    func snapshot() -> GuardSnapshot {
        let watched = active()
        var facts: [String: GuardFacts] = [:]
        var held: [String: HeldReason] = [:]
        for r in watched {
            let f = guardFacts(r)
            facts[r.id] = f
            if let h = heldReason(r, f) { held[r.id] = h }
        }
        var snap = GuardPolicy.snapshot(records: watched, facts: facts, held: held, lastReturn: returns)
        if world.journalBlocked { snap.banners.append(BannerText.journalNotWritable) }
        return snap
    }

    func reconcile(_ trigger: ReconcileTrigger) -> GuardSnapshot {
        let outboard = DemoScenarios.outboardVolumeID
        switch trigger {
        case .willUnmount: if mounted.contains(outboard) { eject(.ejected) }
        case .unmount: if mounted.contains(outboard) { eject(.unclean) }
        case .mount: if volumes[outboard] != nil { mounted.insert(outboard) }
        default: break
        }
        guardPass()
        let s = snapshot()
        if s != lastSnapshot { lastSnapshot = s }
        return lastSnapshot
    }

    func eject(_ kind: RemovalKind) {
        mounted.remove(DemoScenarios.outboardVolumeID)
        removal[DemoScenarios.outboardVolumeID] = kind
        returns = [:]
        checks = [:]
    }

    // MARK: The guard's acts

    func park(_ r: RelocationRecord) {
        let subject = JournalSubject(r)
        let macPath = absolute(r.macPath)
        let why = "park:" + (removal[r.volume.uuid] ?? .unknown).rawValue
        if r.method == .defaults {
            // revertSetting: the prior value is written back, never deleted. The app must be closed (the banner says what is pending).
            guard let domain = r.defaultsDomain, !settingReverted.contains(r.id), running.contains(r.recipeID) == false,
                  put(subject, .intent, .park, src: domain, note: "Put the setting back to its default.") else { return }
            for w in r.defaultsRevert { defaultsStore[domain, default: [:]][w.key] = w.value }
            settingReverted.insert(r.id)
            put(subject, .result, .park, status: .ok, note: why + ",defaults")
            return
        }
        guard let node = tree.node(macPath), node.kind == .link else { return }
        let parked = parkedLink(r.id)
        // The parked link of an earlier cycle is kept as evidence, and the rules allow one name for it: a second cycle waits.
        guard !tree.has(parked) else { return }
        let ctx = RuleContext(record: r, home: home, mountPoint: mountPoint(of: r.volume.uuid))
        guard reason(RenameRules.check(.park, from: macPath, to: parked, ctx: ctx)) == nil,
              put(subject, .intent, .park, src: tilde(macPath), to: tilde(parked), stamp: node.stamp) else { return }
        guard tree.relocate(macPath, to: parked) else {
            put(subject, .result, .park, status: .failed)
            return
        }
        tree.addNote(macPath, text: PlaceholderText.body(driveName: r.volume.name), mtime: nowSeconds)
        put(subject, .result, .park, status: .ok, note: why)
    }

    func unpark(_ r: RelocationRecord) {
        let subject = JournalSubject(r)
        let macPath = absolute(r.macPath)
        guard let mount = mountPoint(of: r.volume.uuid) else { return }
        let check = returnCheck(r)
        let full = check?.fullCheck == true
        let counts = JournalCounts(files: check?.hashed, differences: check?.mismatches, sampled: check?.hashed,
                                   sampleOf: full ? (check?.hashed ?? 0) + (check?.changedSince ?? 0) : r.fileCount)
        let report = check.map { c in c.fullCheck ? ReturnReport(c) : ReturnReport(sampled: c.hashed, sampleOf: r.fileCount) }
        if r.method == .defaults {
            guard let domain = r.defaultsDomain, put(subject, .intent, .unpark, src: domain) else { return }
            for w in r.defaultsWrites { defaultsStore[domain, default: [:]][w.key] = w.value }
            settingReverted.remove(r.id)
            put(subject, .result, .unpark, status: .ok, counts: counts)
            returns[r.id] = report
            justUnparked.append(r)
            return
        }
        let target = mount + "/" + r.relativePath   // recomputed from the current mount point, never taken from the parked link
        let note = parkedNote(r.id)
        let ctx = RuleContext(record: r, home: home, mountPoint: mount)
        guard let n = tree.node(macPath), n.kind == .note, !tree.has(note),
              reason(RenameRules.check(.unpark, from: macPath, to: note, ctx: ctx)) == nil,
              put(subject, .intent, .unpark, src: tilde(macPath), to: target) else { return }
        guard tree.relocate(macPath, to: note) else {
            put(subject, .result, .unpark, status: .failed)
            return
        }
        if reason(LinkRules.check(linkPath: macPath, target: target, ctx: ctx)) != nil {
            _ = tree.relocate(note, to: macPath)
            put(subject, .result, .unpark, status: .refused)
            return
        }
        tree.addLink(macPath, target: target, mtime: nowSeconds)
        put(subject, .result, .unpark, status: .ok, counts: counts)
        returns[r.id] = report
        justUnparked.append(r)
    }

    /// Nothing at the path: the link is rebuilt from the journal when the drive is there (the target comes from the current mount point).
    func recreate(_ r: RelocationRecord, _ f: GuardFacts) {
        guard f.drive != .absent, r.method != .defaults, let mount = mountPoint(of: r.volume.uuid) else { return }
        let macPath = absolute(r.macPath)
        let target = mount + "/" + r.relativePath
        let ctx = RuleContext(record: r, home: home, mountPoint: mount)
        let subject = JournalSubject(r)
        // A relocation that was parked is connected again (an unpark); one that only lost its link is rebuilt.
        let step: MoveStep = r.isParked ? .unpark : .recreate
        guard reason(LinkRules.check(linkPath: macPath, target: target, ctx: ctx)) == nil,
              put(subject, .intent, step, src: tilde(macPath), to: target) else { return }
        tree.addLink(macPath, target: target, mtime: nowSeconds)
        put(subject, .result, step, status: .ok)
        justUnparked.append(r)
    }

    // MARK: The person's choices

    struct Check {
        var record: RelocationRecord
        var unchanged: Int
        var changed: Int
        var total: Int { unchanged + changed }
    }

    /// "Check and reconnect" needs the drive back, the note in place and an unclean removal to answer for.
    func prepareCheck(_ moveID: String) -> (check: Check?, refusal: MoveOutcome?) {
        guard let r = record(moveID), r.direction == .toDrive, r.state.isActive else {
            return (nil, refusedAction(.checkAndReconnect, moveID, .aborted, "That move isn't waiting for a check."))
        }
        let f = guardFacts(r)
        guard f.drive != .absent else {
            return (nil, refusedAction(.checkAndReconnect, moveID, r.state, "\(r.volume.label) isn't connected."))
        }
        guard f.path == .placeholder else {
            return (nil, refusedAction(.checkAndReconnect, moveID, r.state, "Nothing is waiting to be reconnected."))
        }
        let changed = r.fileCount > 10_000 ? 2_292 : r.fileCount / 20
        return (Check(record: r, unchanged: r.fileCount - changed, changed: changed), nil)
    }

    func beginCheck(_ check: Check) -> Bool {
        put(JournalSubject(check.record), .intent, .checkAndReconnect, src: check.record.relativePath)
    }

    func finishCheck(_ check: Check) -> MoveOutcome {
        let r = check.record
        let subject = JournalSubject(r)
        advance(DemoTiming.verifySeconds(UInt64(check.unchanged) * 1_000_000))
        put(subject, .result, .checkAndReconnect, status: .ok,
            counts: JournalCounts(files: check.unchanged, differences: 0, sampled: check.unchanged, sampleOf: check.total))
        checks[r.id] = ReturnCheckResult(quickPassed: true, hashed: check.unchanged, mismatches: 0, fullCheck: true, changedSince: check.changed,
                                         sampleOf: check.total)
        guardPass()
        lastSnapshot = snapshot()
        let state = record(r.id)?.state ?? r.state
        return MoveOutcome(action: .checkAndReconnect, moveID: r.id, state: state, ok: true,
                           message: "Checked \(Format.number(check.unchanged)) files that haven't changed since they were copied: all matched. \(Format.number(check.changed)) files have changed since and weren't compared.")
    }

    func setAsideAndReconnect(_ moveID: String) -> MoveOutcome {
        guard let r = record(moveID), r.direction == .toDrive, r.state.isActive else {
            return refusedAction(.setAsideAndReconnect, moveID, .aborted, "That move isn't waiting to be reconnected.")
        }
        let f = guardFacts(r)
        guard f.path == .other, f.drive != .absent else {
            return refusedAction(.setAsideAndReconnect, moveID, r.state, "Nothing new needs setting aside.")
        }
        let macPath = absolute(r.macPath)
        let aside = macPath + Names.whileAwayInfix + dateText(cursor)
        let subject = JournalSubject(r)
        let ctx = RuleContext(record: r, home: home, mountPoint: mountPoint(of: r.volume.uuid))
        if let why = reason(RenameRules.check(.setAsideForeign, from: macPath, to: aside, ctx: ctx)) {
            return refusedAction(.setAsideAndReconnect, moveID, r.state, "The new item stays where it is. \(why)")
        }
        guard put(subject, .intent, .setAsideForeign, src: tilde(macPath), to: tilde(aside)) else {
            return refusedAction(.setAsideAndReconnect, moveID, r.state, DemoScenarios.journalBlockedMessage)
        }
        let moved = tree.relocate(macPath, to: aside)
        put(subject, .result, .setAsideForeign, status: moved ? .ok : .failed)
        guard moved else { return refusedAction(.setAsideAndReconnect, moveID, r.state, "The new item couldn't be renamed, so nothing was reconnected.") }
        guardPass()
        lastSnapshot = snapshot()
        return MoveOutcome(action: .setAsideAndReconnect, moveID: moveID, state: record(moveID)?.state ?? r.state, ok: true,
                           message: "Set the new item aside as \(leafName(aside)) and reconnected \(r.recipeName). Nothing was merged or deleted.")
    }

    func dateText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    // MARK: Events of a scenario

    func apply(_ e: DemoEvent) {
        cursor = max(cursor, now.addingTimeInterval(-Double(e.secondsAgo)))
        switch e.action {
        case .eject(let kind):
            eject(kind)
        case .mount:
            mounted.insert(DemoScenarios.outboardVolumeID)
        case .foreignFolder(let id, let bytes):
            // An app writes a new folder where the note was (the note is gone; the parked link stays in Parked/).
            if let path = Catalogue.recipe(id)?.absoluteSource(home: home) {
                tree.addDirectory(path, fingerprint: TreeFingerprint(files: 14, directories: 3, logicalBytes: bytes, allocatedBytes: bytes), ours: false,
                                  mtime: nowSeconds)
            }
        }
        guardPass()
        lastSnapshot = snapshot()
    }

    // MARK: Recovery at launch

    func pathKind(_ path: String, plan: MovePlan) -> PathKind {
        guard let n = tree.node(path) else { return .missing }
        switch n.kind {
        case .link: return .link
        case .note: return .placeholder
        case .directory: return n.stamp.isSameObject(as: plan.sourceStamp) ? .real : .other
        }
    }

    /// What the app does first on every launch (BUILD_PLAN §4.4): look at each move that was in flight, gather the facts, let
    /// `Recovery.decide` choose, and carry the action out through the same rules and journal lines. It never deletes, overwrites or merges.
    func recoverAtLaunch() {
        for r in records() where r.direction == .toDrive && (r.state.isInFlight || r.state == .planned) {
            guard let plan = plans[r.id] else { continue }
            let facts = RecoveryFacts(drivePresent: mounted.contains(r.volume.uuid), path: pathKind(plan.macPath, plan: plan),
                                      beforeMovePresent: tree.has(plan.beforeMovePath), stagingPresent: tree.has(plan.stagingPath),
                                      publishedPresent: tree.has(plan.destination.finalPath))
            carryOut(Recovery.decide(record: r, facts: facts), r, plan)
        }
    }

    private func carryOut(_ action: RecoveryAction, _ r: RelocationRecord, _ plan: MovePlan) {
        let subject = JournalSubject(r)
        let message = Recovery.message(for: action, record: r)
        let ending = Recovery.resultingState(of: action, record: r)
        switch action {
        case .noop, .remainSwapped, .remainConfirmed, .continueRollback, .finishPark, .createPlaceholder, .unpark, .recreateLink, .markReturned:
            break
        case .abort(let why, _):
            guard put(subject, .intent, .recover, note: message) else { return }
            put(subject, .result, .abort, state: ending, status: .ok, abort: why, note: message)
            put(subject, .result, .recover, status: .ok, note: message)
        case .rollbackOriginal:
            guard put(subject, .intent, .recover, note: message) else { return }
            let ok = undoSwap(plan, redirected: false)
            if ok { put(subject, .result, .abort, state: ending, status: .ok, abort: .interrupted, note: message) }
            put(subject, .result, .recover, status: ok ? .ok : .failed, note: message)
        case .setAsideForeignThenRollback:
            guard put(subject, .intent, .recover, note: message) else { return }
            let aside = plan.macPath + Names.createdWhileMovingSuffix
            if reason(RenameRules.check(.setAsideForeign, from: plan.macPath, to: aside, ctx: ruleContext(plan))) == nil,
               put(subject, .intent, .setAsideForeign, src: tilde(plan.macPath), to: tilde(aside)) {
                let moved = tree.relocate(plan.macPath, to: aside)
                put(subject, .result, .setAsideForeign, status: moved ? .ok : .failed)
            }
            let ok = undoSwap(plan, redirected: false)
            if ok { put(subject, .result, .abort, state: ending, status: .ok, abort: .interrupted, note: message) }
            put(subject, .result, .recover, status: ok ? .ok : .failed, note: message)
        case .adoptSwapped:
            guard put(subject, .intent, .recover, note: message) else { return }
            put(subject, .result, .swapped, state: .swapped, status: .ok)
            put(subject, .result, .recover, status: .ok, note: message)
        case .markTrashedUnrecorded:
            guard put(subject, .intent, .recover, note: message) else { return }
            put(subject, .result, .trash, state: .originalTrashed, status: .ok, note: message)
            put(subject, .result, .recover, status: .ok, note: message)
        case .needsAttention:
            // Facts shown, nothing touched: the line is a refusal and the state stays where the journal left it.
            guard put(subject, .intent, .recover, note: message) else { return }
            put(subject, .result, .recover, status: .refused, note: message)
        }
    }
}
