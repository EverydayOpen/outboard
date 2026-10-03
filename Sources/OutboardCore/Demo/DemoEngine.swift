import Foundation

/// One beat of a demo move: the progress it reports and the act it performs (journal first, then the tree). `act` returns an
/// outcome only when the move stops; nil means go on. Progress-only beats have no act.
struct DemoStep {
    var phase: ProgressPhase
    var fraction: Double
    var act: ((DemoState) -> MoveOutcome?)?
}

/// The move engine of the demo: the same order as the Mac's `MoveEngine` (BUILD_PLAN §5.5), written against the in-memory tree.
/// Preflight, copy, compare, publish, W1 recheck, set the original aside, redirect, health, swapped. Every rule check is the
/// real Core rule, every compare is the real `TreeCompare`, every line is the real journal model. A seeded history is played with
/// these same functions, so what the screens show is what a live move writes.
extension DemoState {
    func volumeRef(_ plan: MovePlan) -> VolumeRef {
        VolumeRef(uuid: plan.destination.volumeUUID, name: plan.destination.volumeName, token: plan.destination.volumeToken)
    }

    func ruleContext(_ plan: MovePlan) -> RuleContext { RuleContext(plan: plan, home: home) }

    func reason(_ verdict: RuleVerdict) -> String? {
        if case .refused(let why) = verdict { return why }
        return nil
    }

    // MARK: Seeded history

    func play(_ spec: DemoSpec) {
        guard let recipe = Catalogue.recipe(spec.recipeID), let scan = scans([spec.recipeID]).first, scan.state == .measured,
              let drive = drive(DemoScenarios.outboardVolumeID) else { return }
        cursor = max(cursor, now.addingTimeInterval(-Double(spec.secondsAgo)))
        let report = eligibility(drive.id, recipe.id)
        let consent = DemoScenarios.tickedConsent(recipe: recipe, report: report)
        let planned = MovePlanner.plan(recipe: recipe, folder: scan, drive: drive, report: report, consent: consent, prior: prior(recipe), home: home,
                                       now: cursor, moveID: spec.moveID(now: now), groupID: nil, prefs: DemoState.prefs)
        guard let plan = planned.plan else { return }
        let saved = failure
        defer { failure = saved }
        failure = spec.end == .mismatch ? .mismatch : nil
        var crash: Bool?
        if case .crash(let both) = spec.end { crash = both }
        for step in steps(plan, recipe, crash: crash) {
            if let act = step.act, act(self) != nil { return }
        }
        switch spec.end {
        case .trashed:
            advance(1_200)
            _ = confirm(plan.id)
        case .rolledBack:
            advance(600)
            _ = rollback(plan.id)
        default:
            break
        }
    }

    // MARK: The steps

    /// The beats of one move. Copy and compare report their progress in several beats; the switch is one beat, because the real
    /// engine has no suspension point between the recheck and the redirect.
    func steps(_ plan: MovePlan, _ recipe: Recipe, crash: Bool? = nil) -> [DemoStep] {
        var s: [DemoStep] = [
            DemoStep(phase: .preflight, fraction: 0, act: { $0.stepBegin(plan, recipe) }),
            DemoStep(phase: .copying, fraction: 0, act: { $0.stepCopyStart(plan) }),
        ]
        for f in [0.12, 0.27, 0.41, 0.58, 0.73, 0.89] { s.append(DemoStep(phase: .copying, fraction: f, act: nil)) }
        s.append(DemoStep(phase: .copying, fraction: 1, act: { $0.stepCopyDone(plan) }))
        s.append(DemoStep(phase: .verifying, fraction: 0, act: { $0.stepVerifyStart(plan) }))
        for f in [0.2, 0.45, 0.62, 0.8] { s.append(DemoStep(phase: .verifying, fraction: f, act: nil)) }
        s.append(DemoStep(phase: .verifying, fraction: 1, act: { $0.stepVerifyDone(plan) }))
        if let both = crash {
            s.append(DemoStep(phase: .swapping, fraction: 1, act: { $0.stepSwapCrash(plan, bothOriginals: both) }))
        } else {
            s.append(DemoStep(phase: .swapping, fraction: 1, act: { $0.stepSwap(plan, recipe) }))
        }
        s.append(DemoStep(phase: .finishing, fraction: 1, act: nil))
        return s
    }

    func progress(_ plan: MovePlan, _ step: DemoStep) -> MoveProgress {
        let fp = plan.sourceFingerprint
        let f = step.fraction
        switch step.phase {
        case .copying:
            return MoveProgress(moveID: plan.id, phase: .copying, bytesDone: UInt64(Double(fp.logicalBytes) * f), bytesTotal: fp.logicalBytes,
                                filesDone: Int(Double(fp.files) * f), filesTotal: fp.files,
                                elapsedSeconds: (Double(DemoTiming.copySeconds(fp.logicalBytes)) * f).rounded())
        case .verifying:
            return MoveProgress(moveID: plan.id, phase: .verifying, bytesDone: fp.logicalBytes, bytesTotal: fp.logicalBytes,
                                filesDone: Int(Double(fp.files) * f), filesTotal: fp.files,
                                elapsedSeconds: (Double(DemoTiming.verifySeconds(fp.logicalBytes)) * f).rounded())
        default:
            return MoveProgress(moveID: plan.id, phase: step.phase, bytesDone: step.phase == .preflight ? 0 : fp.logicalBytes,
                                bytesTotal: fp.logicalBytes, filesDone: step.phase == .preflight ? 0 : fp.files, filesTotal: fp.files)
        }
    }

    // MARK: Preflight and begin

    func preflight(_ plan: MovePlan, _ recipe: Recipe) -> PreflightReport {
        let drive = self.drive(plan.destination.volumeUUID)
        let report = drive.map { Eligibility.evaluate(volume: $0, recipe: recipe, source: needs(recipe), policy: .release) }
        let fresh = Eligibility.freshness(plannedUUID: plan.destination.volumeUUID, plannedMountPoint: plan.destination.mountPoint, now: drive)
        let node = tree.node(plan.macPath)
        let fp = plan.sourceFingerprint
        let state = RunningCheck.state(recipe: recipe, snapshot: runningSnapshot(recipe))
        let blocked = RunningCheck.blockers(recipe: recipe, snapshot: runningSnapshot(recipe)).first { !$0.isClear }
        let leftover = tree.has(plan.beforeMovePath) || tree.has(plan.stagingPath)
        func check(_ id: PreflightID, _ ok: Bool, _ detail: String) -> PreflightCheck { PreflightCheck(id, passed: ok, detail: ok ? "" : detail) }
        let checks = [
            check(.p1, (report?.isAllowed ?? false) && fresh == nil, fresh?.message ?? report?.firstRefusal?.message ?? "The drive isn't connected."),
            check(.p2, recipe.isAutomated, "This move isn't switched on in this build."),
            check(.p3, node?.kind == .directory && node?.stamp.isSameObject(as: plan.sourceStamp) == true, "The folder isn't a plain folder on this Mac, or it changed since it was measured."),
            check(.p4, NeverList.reason(forPath: plan.sourcePath, home: home) == nil, "Outboard never moves this folder."),
            check(.p5, fp.datalessFiles == 0, "\(fp.datalessFiles) files aren't stored on this Mac."),
            check(.p6, fp.specialFiles == 0, "The folder holds special files that Outboard won't copy."),
            check(.p7, !leftover, "Something from an earlier move is still here. Finish or trash it first."),
            check(.p8, state == .notRunning, "\(blocked?.name ?? recipe.name) is running. Quit it to continue."),
            check(.p9, !world.journalBlocked, DemoScenarios.journalBlockedMessage),
            check(.p10, true, "Some files can't be read."),
            check(.p11, report?.verdicts.contains { $0.rule == .e10 && $0.outcome == .refuse } != true, "The drive and the data treat upper and lower case differently."),
            check(.p12, fp.hardLinkedFiles == 0 || drive?.supportsHardLinks == .yes, "The drive can't hold the hard links this data has."),
            check(.p13, plan.destination.finalPath.utf8.count < 1_000, "A name is too long for the drive."),
            check(.p14, flights <= 1, "Another move is running."),
        ]
        return PreflightReport(checks: checks)
    }

    func stepBegin(_ plan: MovePlan, _ recipe: Recipe) -> MoveOutcome? {
        plans[plan.id] = plan
        let subject = JournalSubject(plan)
        let ref = volumeRef(plan)
        let report = preflight(plan, recipe)
        reports[plan.id] = report
        let jp = MovePlanner.journalPlan(plan, onDriveMissing: recipe.onDriveMissing, volume: ref, fileCount: plan.sourceFingerprint.files, home: home)
        guard put(subject, .intent, .begin, state: .planned, volume: ref, plan: jp) else {
            return MoveOutcome(action: .move, moveID: plan.id, state: .aborted, ok: false, abort: .journalUnwritable,
                               message: DemoScenarios.journalBlockedMessage, preflight: report)
        }
        guard put(subject, .intent, .preflight, state: .preflight, volume: ref) else { return journalFailure(plan, report) }
        advance(2)
        let counts = JournalCounts(checksPassed: report.passedCount, checksTotal: report.checks.count, freeBytes: drive(plan.destination.volumeUUID)?.availableBytes)
        put(subject, .result, .preflight, status: report.passed ? .ok : .refused, counts: counts)
        if let failed = report.firstFailure {
            return abortMove(plan, .preflightFailed, "A check didn't pass: \(failed.detail) Nothing was changed.", preflight: report)
        }
        return nil
    }

    func journalFailure(_ plan: MovePlan, _ report: PreflightReport? = nil) -> MoveOutcome {
        MoveOutcome(action: .move, moveID: plan.id, state: .aborted, ok: false, abort: .journalUnwritable,
                    message: DemoScenarios.journalBlockedMessage, preflight: report)
    }

    /// The move ends in Aborted. Nothing on the Mac changed: whatever is on the drive stays there and is labelled as a leftover.
    func abortMove(_ plan: MovePlan, _ why: AbortReason, _ message: String, differences: [Difference] = [], preflight: PreflightReport? = nil) -> MoveOutcome {
        put(JournalSubject(plan), .result, .abort, state: .aborted, status: .ok, abort: why, note: message)
        return MoveOutcome(action: .move, moveID: plan.id, state: .aborted, ok: false, abort: why, message: message,
                           preflight: preflight ?? reports[plan.id], differences: differences)
    }

    // MARK: Copy

    func stepCopyStart(_ plan: MovePlan) -> MoveOutcome? {
        if let why = reason(CopyRules.check(source: plan.sourcePath, destination: plan.stagingPath, ctx: ruleContext(plan))) {
            return abortMove(plan, .copyFailed, "Outboard didn't start the copy. \(why) Nothing was changed.")
        }
        guard put(JournalSubject(plan), .intent, .copy, state: .copying, src: tilde(plan.sourcePath), to: plan.stagingPath, stamp: plan.sourceStamp,
                  volume: volumeRef(plan)) else { return journalFailure(plan) }
        tree.addDirectory(plan.stagingPath, fingerprint: TreeFingerprint(), ours: true, mtime: nowSeconds)
        return nil
    }

    func stepCopyDone(_ plan: MovePlan) -> MoveOutcome? {
        advance(DemoTiming.copySeconds(plan.logicalBytes))
        tree.setFingerprint(plan.stagingPath, plan.sourceFingerprint)
        put(JournalSubject(plan), .result, .copy, status: .ok,
            counts: JournalCounts(files: plan.sourceFingerprint.files, bytes: plan.logicalBytes))
        return nil
    }

    // MARK: Compare (V1 to V3)

    func stepVerifyStart(_ plan: MovePlan) -> MoveOutcome? {
        guard put(JournalSubject(plan), .intent, .verify, state: .verifying, src: tilde(plan.sourcePath), to: plan.stagingPath) else { return journalFailure(plan) }
        return nil
    }

    func stepVerifyDone(_ plan: MovePlan) -> MoveOutcome? {
        advance(DemoTiming.verifySeconds(plan.logicalBytes))
        let subject = JournalSubject(plan)
        let source = DemoEntries.source(plan)
        var differences: [Difference] = []
        var why = AbortReason.mismatch
        switch failure {
        case .mismatch?:
            differences = TreeCompare.compare(source: source, destination: DemoEntries.withFlippedFile(source), limit: Limits.firstDifferencesListed)
        case .sourceChanged?:
            differences = TreeCompare.changedDuringCopy(start: source, now: DemoEntries.withChangedFile(source), limit: Limits.firstDifferencesListed)
            why = .sourceChanged
        default:
            differences = TreeCompare.compare(source: source, destination: source, limit: Limits.firstDifferencesListed)
        }
        let fp = plan.sourceFingerprint
        if !differences.isEmpty {
            put(subject, .result, .verify, status: .mismatch, counts: JournalCounts(files: fp.files, differences: differences.count))
            let label = volumeRef(plan).label
            let message = why == .sourceChanged
                ? "\(plan.recipeName) changed while it was being copied. Quit the app and start over. Nothing on your Mac was changed."
                : "\(differences.count) \(differences.count == 1 ? "file differs" : "files differ") between the original and \(label), so nothing was switched. Nothing on your Mac was changed."
            return abortMove(plan, why, message, differences: differences)
        }
        let summary = VerificationSummary(filesCompared: fp.files, bytesCompared: fp.logicalBytes, symlinksCompared: fp.symlinks,
                                          hardLinkedCopiedSeparately: fp.hardLinkedFiles, manifestDigest: DemoEntries.digest(source), completedAt: cursor)
        summaries[plan.id] = summary
        put(subject, .result, .verify, status: .ok, counts: JournalCounts(files: fp.files, bytes: fp.logicalBytes, differences: 0), verification: summary)
        return nil
    }

    // MARK: Publish and switch (V4, W1 to W4)

    func stepSwap(_ plan: MovePlan, _ recipe: Recipe) -> MoveOutcome? {
        let subject = JournalSubject(plan)
        let ctx = ruleContext(plan)
        let label = volumeRef(plan).label
        // V4: the verified copy gets its final name, and the sentinel goes beside it.
        if let why = reason(RenameRules.check(.publish, from: plan.stagingPath, to: plan.destination.finalPath, ctx: ctx)) {
            return abortMove(plan, .unknown, "Outboard didn't publish the copy. \(why) Nothing on your Mac was changed.")
        }
        guard put(subject, .intent, .publish, src: plan.stagingPath, to: plan.destination.finalPath) else { return journalFailure(plan) }
        guard tree.relocate(plan.stagingPath, to: plan.destination.finalPath) else {
            put(subject, .result, .publish, status: .failed)
            return abortMove(plan, .copyFailed, "The copy couldn't be given its final name. Nothing on your Mac was changed.")
        }
        tree.addMarker(plan.sentinelPath, mtime: nowSeconds)
        put(subject, .result, .publish, status: .ok)

        // W1: everything is looked at again, with nothing in between this and the redirect.
        if failure == .appLaunched { running.insert(recipe.id) }
        if failure == .driveChanged {
            mounted.remove(plan.destination.volumeUUID)
            removal[plan.destination.volumeUUID] = .unclean
        }
        if let changed = Eligibility.freshness(plannedUUID: plan.destination.volumeUUID, plannedMountPoint: plan.destination.mountPoint,
                                               now: drive(plan.destination.volumeUUID)) {
            return abortMove(plan, .driveChanged, changed.message)
        }
        if RunningCheck.state(recipe: recipe, snapshot: runningSnapshot(recipe)) != .notRunning {
            return abortMove(plan, .appLaunched, "\(plan.recipeName) opened before the switch, so the move stopped. Quit the app and start over. Nothing on your Mac was changed.")
        }
        guard let live = tree.node(plan.macPath), live.stamp.isSameObject(as: plan.sourceStamp) else {
            return abortMove(plan, .sourceChanged, "The folder changed before the switch. Quit the app and start over. Nothing on your Mac was changed.")
        }

        // W2: the original is renamed, not deleted.
        if let why = reason(RenameRules.check(.setAside, from: plan.macPath, to: plan.beforeMovePath, ctx: ctx)) {
            return abortMove(plan, .unknown, "Outboard didn't set the original aside. \(why) Nothing on your Mac was changed.")
        }
        guard put(subject, .intent, .setAside, src: tilde(plan.macPath), to: tilde(plan.beforeMovePath), stamp: live.stamp) else { return journalFailure(plan) }
        guard tree.relocate(plan.macPath, to: plan.beforeMovePath) else {
            put(subject, .result, .setAside, status: .failed)
            return abortMove(plan, .unknown, "The original couldn't be renamed. Nothing on your Mac was changed.")
        }
        put(subject, .result, .setAside, status: .ok)

        // W3: the app is pointed at the copy.
        switch plan.redirect {
        case .symbolicLink(let linkPath, let target):
            if let why = reason(LinkRules.check(linkPath: linkPath, target: target, ctx: ctx)) {
                _ = undoSwap(plan, redirected: false)
                return abortMove(plan, .unknown, "Outboard didn't create the link. \(why) Your original is back where it was.")
            }
            guard put(subject, .intent, .redirect, src: tilde(linkPath), to: target) else {
                _ = undoSwap(plan, redirected: false)
                return journalFailure(plan)
            }
            if failure == .foreignFolder {
                tree.addDirectory(linkPath, fingerprint: TreeFingerprint(files: 3, directories: 1, logicalBytes: 4_096), ours: false, mtime: nowSeconds)
            }
            if tree.has(linkPath) {
                put(subject, .result, .redirect, status: .failed, errno: 17)
                return foreignAppeared(plan)
            }
            tree.addLink(linkPath, target: target, mtime: nowSeconds)
            put(subject, .result, .redirect, status: .ok)
        case .defaults(let domain, let writes, _, _):
            guard put(subject, .intent, .redirect, src: domain, note: writes.map(\.key).joined(separator: ", ")) else {
                _ = undoSwap(plan, redirected: false)
                return journalFailure(plan)
            }
            for w in writes { defaultsStore[domain, default: [:]][w.key] = w.value }
            put(subject, .result, .redirect, status: .ok)
        }

        // W4: the redirect must resolve to the recorded drive, with the sentinel there.
        let healthy = GuardPolicy.classify(GuardFacts(path: .link, drive: .mountedAtRecordedPath, sentinel: tree.has(plan.sentinelPath) ? .ok : .missing,
                                                      targetOnRecordedVolume: .yes)) == .healthy
        guard healthy else {
            _ = undoSwap(plan, redirected: true)
            return abortMove(plan, .healthFailed, "The link didn't resolve to \(label), so Outboard put your original back. Nothing on your Mac was changed.")
        }
        put(subject, .result, .swapped, state: .swapped, status: .ok, verification: summaries[plan.id])
        return nil
    }

    /// An app made a folder at the path between the rename and the link: it is set aside, never merged, and the original is restored.
    func foreignAppeared(_ plan: MovePlan) -> MoveOutcome {
        let subject = JournalSubject(plan)
        let aside = plan.macPath + Names.createdWhileMovingSuffix
        if reason(RenameRules.check(.setAsideForeign, from: plan.macPath, to: aside, ctx: ruleContext(plan))) == nil,
           put(subject, .intent, .setAsideForeign, src: tilde(plan.macPath), to: tilde(aside)) {
            let moved = tree.relocate(plan.macPath, to: aside)
            put(subject, .result, .setAsideForeign, status: moved ? .ok : .failed)
        }
        _ = undoSwap(plan, redirected: false)
        let name = leafName(plan.macPath)
        return abortMove(plan, .foreignFolderAppeared,
                         "Something new appeared at \(name) while the move was running. We set it aside as \(name)\(Names.createdWhileMovingSuffix) and restored your original.")
    }

    /// The crash row of the recovery table: the original was renamed, the process stopped before the result line was written.
    /// `bothOriginals` also leaves a second original at the path, which recovery must show and not touch.
    func stepSwapCrash(_ plan: MovePlan, bothOriginals: Bool) -> MoveOutcome? {
        let subject = JournalSubject(plan)
        put(subject, .intent, .publish, src: plan.stagingPath, to: plan.destination.finalPath)
        _ = tree.relocate(plan.stagingPath, to: plan.destination.finalPath)
        tree.addMarker(plan.sentinelPath, mtime: nowSeconds)
        put(subject, .result, .publish, status: .ok)
        guard let live = tree.node(plan.macPath) else { return nil }
        put(subject, .intent, .setAside, src: tilde(plan.macPath), to: tilde(plan.beforeMovePath), stamp: live.stamp)
        _ = tree.relocate(plan.macPath, to: plan.beforeMovePath)
        if bothOriginals { tree.replaceFromOutside(plan.macPath, with: live) }
        return MoveOutcome(action: .move, moveID: plan.id, state: .verifying, ok: false, abort: .interrupted, message: "Interrupted.")
    }

    // MARK: Undoing a switch (R2, R3)

    /// Puts the redirect back (when it was made) and the original where it was. Foreign items are set aside, never merged.
    func undoSwap(_ plan: MovePlan, redirected: Bool) -> Bool {
        let subject = JournalSubject(plan)
        let ctx = ruleContext(plan)
        if redirected {
            switch plan.redirect {
            case .symbolicLink(let linkPath, _):
                let parked = parkedLink(plan.id)
                guard reason(RenameRules.check(.park, from: linkPath, to: parked, ctx: ctx)) == nil,
                      put(subject, .intent, .undoRedirect, src: tilde(linkPath), to: tilde(parked)) else { return false }
                let ok = tree.relocate(linkPath, to: parked)
                put(subject, .result, .undoRedirect, status: ok ? .ok : .failed)
                if !ok { return false }
            case .defaults(let domain, _, _, let revert):
                guard put(subject, .intent, .undoRedirect, src: domain, note: revert.map(\.key).joined(separator: ", ")) else { return false }
                for w in revert { defaultsStore[domain, default: [:]][w.key] = w.value }
                put(subject, .result, .undoRedirect, status: .ok)
            }
        }
        if tree.has(plan.macPath) {
            let aside = plan.macPath + Names.createdWhileRollingBackSuffix
            guard reason(RenameRules.check(.setAsideForeign, from: plan.macPath, to: aside, ctx: ctx)) == nil,
                  put(subject, .intent, .setAsideForeign, src: tilde(plan.macPath), to: tilde(aside)) else { return false }
            let ok = tree.relocate(plan.macPath, to: aside)
            put(subject, .result, .setAsideForeign, status: ok ? .ok : .failed)
            if !ok { return false }
        }
        guard reason(RenameRules.check(.undoSetAside, from: plan.beforeMovePath, to: plan.macPath, ctx: ctx)) == nil,
              put(subject, .intent, .undoSetAside, src: tilde(plan.beforeMovePath), to: tilde(plan.macPath)) else { return false }
        let ok = tree.relocate(plan.beforeMovePath, to: plan.macPath)
        put(subject, .result, .undoSetAside, status: ok ? .ok : .failed)
        return ok
    }

    // MARK: What the person does next

    func successOutcome(_ plan: MovePlan) -> MoveOutcome {
        MoveOutcome(action: .move, moveID: plan.id, state: .swapped, ok: true,
                    message: "Moved \(Format.bytes(plan.logicalBytes)) to \(volumeRef(plan).label). Your original is kept until you confirm.",
                    preflight: reports[plan.id], verification: summaries[plan.id])
    }

    func refusedAction(_ action: MoveActionKind, _ moveID: String, _ state: MoveState, _ message: String) -> MoveOutcome {
        MoveOutcome(action: action, moveID: moveID, state: state, ok: false, message: message)
    }

    func confirm(_ moveID: String) -> MoveOutcome {
        guard let r = record(moveID), let plan = plans[moveID] else {
            return refusedAction(.confirm, moveID, .aborted, "Outboard has no record of that move.")
        }
        guard r.canConfirm else { return refusedAction(.confirm, moveID, r.state, "This move can't be confirmed right now.") }
        let subject = JournalSubject(r)
        guard put(subject, .intent, .confirm) else { return refusedAction(.confirm, moveID, r.state, DemoScenarios.journalBlockedMessage) }
        put(subject, .result, .confirm, state: .confirmed, status: .ok)
        guard let confirmed = record(moveID) else { return refusedAction(.confirm, moveID, .confirmed, "Outboard lost track of that move.") }
        let before = plan.beforeMovePath
        let trashed = trashFolder + "/" + leafName(before)
        let ctx = RuleContext(record: confirmed, home: home, mountPoint: mountPoint(of: r.volume.uuid))
        if let why = reason(TrashRules.allows(path: before, ctx: ctx)) {
            return refusedAction(.confirm, moveID, .confirmed, "Your original stays on this Mac. \(why)")
        }
        guard put(subject, .intent, .trash, src: tilde(before), to: tilde(trashed)) else {
            return refusedAction(.confirm, moveID, .confirmed, DemoScenarios.journalBlockedMessage)
        }
        advance(2)
        guard tree.relocate(before, to: trashed) else {
            put(subject, .result, .trash, status: .failed)
            return refusedAction(.confirm, moveID, .confirmed, "The original couldn't be moved to the Trash. It is still on this Mac.")
        }
        put(subject, .result, .trash, state: .originalTrashed, status: .ok, trashedPath: tilde(trashed))
        return MoveOutcome(action: .confirm, moveID: moveID, state: .originalTrashed, ok: true,
                           message: "Moved the original to the Trash. Your Mac gets the space back when you empty the Trash.")
    }

    func rollback(_ moveID: String) -> MoveOutcome {
        guard let r = record(moveID), let plan = plans[moveID], let recipe = Catalogue.recipe(r.recipeID) else {
            return refusedAction(.rollback, moveID, .aborted, "Outboard has no record of that move.")
        }
        guard r.canRollBack else { return refusedAction(.rollback, moveID, r.state, "This move can't be rolled back any more.") }
        if RunningCheck.state(recipe: recipe, snapshot: runningSnapshot(recipe)) != .notRunning {
            return refusedAction(.rollback, moveID, r.state, "\(r.recipeName) is running. Quit it and try again.")
        }
        let subject = JournalSubject(r)
        guard put(subject, .intent, .rollback) else { return refusedAction(.rollback, moveID, r.state, DemoScenarios.journalBlockedMessage) }
        guard undoSwap(plan, redirected: true) else {
            put(subject, .result, .rollback, status: .failed)
            return refusedAction(.rollback, moveID, r.state, "The rollback stopped. Your data is where it was; nothing was deleted.")
        }
        put(subject, .result, .rollback, state: .rolledBack, status: .ok)
        return MoveOutcome(action: .rollback, moveID: moveID, state: .rolledBack, ok: true,
                           message: "Rolled back to your original. Anything written on \(r.volume.label) since the move stays there and is not copied back.")
    }

    func forget(_ moveID: String) -> MoveOutcome {
        guard let r = record(moveID), let plan = plans[moveID] else { return refusedAction(.forget, moveID, .aborted, "Outboard has no record of that move.") }
        guard r.state == .confirmed || r.state == .originalTrashed else {
            return refusedAction(.forget, moveID, r.state, r.canRollBack
                ? "Your original is still on this Mac. Roll back instead."
                : "Only a move that has been confirmed can be forgotten.")
        }
        let subject = JournalSubject(r)
        guard put(subject, .intent, .forget) else { return refusedAction(.forget, moveID, r.state, DemoScenarios.journalBlockedMessage) }
        // Whatever sits at the path (our link or our note) is set aside into Parked/, never deleted, so the app can make its own default.
        let macPath = absolute(r.macPath)
        if let node = tree.node(macPath), node.ours {
            let aside = supportFolder + "/" + Names.parkedFolder + "/" + plan.id + "/forgotten"
            if put(subject, .intent, .park, src: tilde(macPath), to: tilde(aside)) {
                let ok = tree.relocate(macPath, to: aside)
                put(subject, .result, .park, status: ok ? .ok : .failed)
            }
        }
        put(subject, .result, .forget, state: .forgotten, status: .ok)
        return MoveOutcome(action: .forget, moveID: moveID, state: .forgotten, ok: true,
                           message: "Forgot this move. Outboard can't get this data back without the drive.")
    }

    func trashLeftover(_ leftoverID: String) -> MoveOutcome {
        guard let item = leftovers().first(where: { $0.id == leftoverID }), let r = record(item.moveID) else {
            return refusedAction(.trashLeftover, leftoverID, .aborted, "That item isn't on the list any more.")
        }
        let mount = mountPoint(of: item.volume?.uuid ?? r.volume.uuid)
        let path = item.onDrive ? (mount.map { $0 + "/" + item.path }) : absolute(item.path)
        guard let path, tree.has(path) else { return refusedAction(.trashLeftover, item.moveID, r.state, "That item isn't where Outboard left it.") }
        var ctx = RuleContext(record: r, home: home, mountPoint: mount)
        ctx.knownLeftovers = RuleContext.leftoverPaths(leftovers(), mountPoint: mount)
        if let why = reason(TrashRules.allows(path: path, ctx: ctx)) {
            return refusedAction(.trashLeftover, item.moveID, r.state, why)
        }
        let subject = JournalSubject(r)
        let destination = (item.onDrive ? (mount ?? "") + "/.Trashes/501" : trashFolder) + "/" + leafName(path)
        // The journal names the item as the leftover list does (drive-relative on a drive), so the fold stops listing it. The result
        // line carries the move's own state: trashing a leftover does not change what became of the move.
        guard put(subject, .intent, .trash, src: item.path, to: tilde(destination)) else {
            return refusedAction(.trashLeftover, item.moveID, r.state, DemoScenarios.journalBlockedMessage)
        }
        guard tree.relocate(path, to: destination) else {
            put(subject, .result, .trash, state: r.state, status: .failed)
            return refusedAction(.trashLeftover, item.moveID, r.state, "The item couldn't be moved to the Trash.")
        }
        put(subject, .result, .trash, state: r.state, status: .ok, trashedPath: tilde(destination))
        return MoveOutcome(action: .trashLeftover, moveID: item.moveID, state: r.state, ok: true,
                           message: "Moved to the Trash" + (item.onDrive ? " on \(r.volume.label). The space comes back when that Trash is emptied." : "."))
    }

    // MARK: Return to Mac

    /// The beats of a reverse move: a verified copy back beside the path, then the swap. The record of the way out becomes Returned.
    func returnSteps(_ record: RelocationRecord, _ plan: MovePlan) -> [DemoStep] {
        let recipe = Catalogue.recipe(record.recipeID)
        let staging = plan.macPath + Names.returningInfix + plan.id
        var s: [DemoStep] = [
            DemoStep(phase: .preflight, fraction: 0, act: { state in
                state.plans[plan.id] = plan
                let ref = record.volume
                let jp = MovePlanner.journalPlan(plan, onDriveMissing: .none, volume: ref, fileCount: plan.sourceFingerprint.files, home: state.home)
                guard state.put(JournalSubject(plan), .intent, .begin, state: .planned, volume: ref, plan: jp) else { return state.journalFailure(plan) }
                state.put(JournalSubject(plan), .intent, .preflight, state: .preflight, volume: ref)
                state.advance(2)
                let running = recipe.map { RunningCheck.state(recipe: $0, snapshot: state.runningSnapshot($0)) } ?? .notRunning
                if running != .notRunning {
                    state.put(JournalSubject(plan), .result, .preflight, status: .refused)
                    return state.abortMove(plan, .appLaunched, "\(record.recipeName) is running. Quit it and try again. Nothing was changed.")
                }
                state.put(JournalSubject(plan), .result, .preflight, status: .ok, counts: JournalCounts(checksPassed: 14, checksTotal: 14))
                return nil
            }),
            DemoStep(phase: .copying, fraction: 0, act: { state in
                if let why = state.reason(CopyRules.check(source: plan.sourcePath, destination: staging, ctx: state.ruleContext(plan))) {
                    return state.abortMove(plan, .copyFailed, "Outboard didn't start the copy. \(why) Nothing was changed.")
                }
                guard state.put(JournalSubject(plan), .intent, .copy, state: .copying, src: plan.sourcePath, to: state.tilde(staging)) else {
                    return state.journalFailure(plan)
                }
                state.tree.addDirectory(staging, fingerprint: TreeFingerprint(), ours: true, mtime: state.nowSeconds)
                return nil
            }),
        ]
        for f in [0.3, 0.6, 0.9] { s.append(DemoStep(phase: .copying, fraction: f, act: nil)) }
        s.append(DemoStep(phase: .copying, fraction: 1, act: { state in
            state.advance(DemoTiming.copySeconds(plan.logicalBytes))
            // What came back is what the drive copy holds (the plan only knows the file count and the size).
            state.tree.setFingerprint(staging, state.tree.node(plan.sourcePath)?.fingerprint ?? plan.sourceFingerprint)
            state.put(JournalSubject(plan), .result, .copy, status: .ok, counts: JournalCounts(files: plan.sourceFingerprint.files, bytes: plan.logicalBytes))
            return nil
        }))
        s.append(DemoStep(phase: .verifying, fraction: 0, act: { state in
            state.put(JournalSubject(plan), .intent, .verify, state: .verifying)
            return nil
        }))
        for f in [0.3, 0.6, 0.9] { s.append(DemoStep(phase: .verifying, fraction: f, act: nil)) }
        s.append(DemoStep(phase: .verifying, fraction: 1, act: { state in
            state.advance(DemoTiming.verifySeconds(plan.logicalBytes))
            let source = DemoEntries.source(plan)
            let differences = TreeCompare.compare(source: source, destination: source, limit: Limits.firstDifferencesListed)
            let fp = plan.sourceFingerprint
            if !differences.isEmpty {
                state.put(JournalSubject(plan), .result, .verify, status: .mismatch, counts: JournalCounts(files: fp.files, differences: differences.count))
                return state.abortMove(plan, .mismatch, "A file differs between the drive and the copy that came back, so nothing was switched. Your Mac was not changed.",
                                       differences: differences)
            }
            let summary = VerificationSummary(filesCompared: fp.files, bytesCompared: fp.logicalBytes, symlinksCompared: fp.symlinks,
                                              manifestDigest: DemoEntries.digest(source), completedAt: state.cursor)
            state.summaries[plan.id] = summary
            state.put(JournalSubject(plan), .result, .verify, status: .ok, counts: JournalCounts(files: fp.files, bytes: fp.logicalBytes, differences: 0), verification: summary)
            return nil
        }))
        s.append(DemoStep(phase: .swapping, fraction: 1, act: { state in
            // The link (or the note) goes into Parked/, the returned copy takes the path, the drive copy stays where it is.
            let subject = JournalSubject(plan)
            let macPath = plan.macPath
            let parked = state.parkedLink(plan.id)
            if let node = state.tree.node(macPath), node.ours {
                if let why = state.reason(RenameRules.check(.park, from: macPath, to: parked, ctx: state.ruleContext(plan))) {
                    return state.abortMove(plan, .unknown, "The link didn't move aside. \(why) Nothing was deleted.")
                }
                guard state.put(subject, .intent, .park, src: state.tilde(macPath), to: state.tilde(parked)) else { return state.journalFailure(plan) }
                let ok = state.tree.relocate(macPath, to: parked)
                state.put(subject, .result, .park, status: ok ? .ok : .failed)
            }
            if let domain = record.defaultsDomain {
                for w in record.defaultsRevert { state.defaultsStore[domain, default: [:]][w.key] = w.value }
            }
            if let why = state.reason(RenameRules.check(.publish, from: staging, to: macPath, ctx: state.ruleContext(plan))) {
                return state.abortMove(plan, .unknown, "The returned copy didn't take its place. \(why) Nothing was deleted.")
            }
            guard state.put(subject, .intent, .publish, src: state.tilde(staging), to: state.tilde(macPath)) else { return state.journalFailure(plan) }
            guard state.tree.relocate(staging, to: macPath) else {
                state.put(subject, .result, .publish, status: .failed)
                return state.abortMove(plan, .unknown, "The returned copy couldn't take its place. Nothing was deleted.")
            }
            state.put(subject, .result, .publish, status: .ok)
            state.put(subject, .result, .swapped, state: .swapped, status: .ok, verification: state.summaries[plan.id])
            let old = JournalSubject(record)
            state.put(old, .intent, .returned, src: record.relativePath, to: state.tilde(macPath))
            state.put(old, .result, .returned, state: .returned, status: .ok)
            return nil
        }))
        s.append(DemoStep(phase: .finishing, fraction: 1, act: nil))
        return s
    }
}
