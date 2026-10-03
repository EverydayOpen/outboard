import Darwin
import Foundation
import OutboardCore

/// The move: preflight, copy, compare, publish, swap, health (BUILD_PLAN §5.5). It only calls the verbs (`Copier`, `Renamer`,
/// `Redirect`, `Journal`); it moves, copies, links and trashes nothing itself, and `tools/safety_greps.sh` pins the order of its
/// calls and forbids a suspension point between the fresh recheck (W1) and the redirect (W3). A failure before the swap leaves
/// nothing changed on the Mac; a failure after the original was renamed puts it back (`Rollback.automatic`).
enum MoveEngine {
    static func run(_ plan: MovePlan, home: String, policy: Policy, progress: @escaping @Sendable (MoveProgress) -> Void) async -> MoveOutcome {
        guard MutationGate.tryEnter() else { return refusal(plan, Say.busy) }
        defer { MutationGate.leave() }
        guard plan.direction == .toDrive, let recipe = Catalogue.recipe(plan.recipeID) else {
            return refusal(plan, "Outboard does not know this recipe, so nothing was changed.")
        }
        let subject = JournalSubject(plan)
        let volume = VolumeRef(uuid: plan.destination.volumeUUID, name: plan.destination.volumeName, token: plan.destination.volumeToken)

        // The plan is written first. If the journal cannot take it, nothing moves.
        guard Journal.begin(plan, onDriveMissing: recipe.onDriveMissing, volume: volume, home: home, at: Date()) else {
            return MoveOutcome(action: .move, moveID: plan.id, state: .planned, ok: false, abort: .journalUnwritable, message: Say.journalBlocked)
        }
        guard Journal.intent(.preflight, subject: subject, home: home, state: .preflight) else {
            return MoveOutcome(action: .move, moveID: plan.id, state: .planned, ok: false, abort: .journalUnwritable, message: Say.journalBlocked)
        }
        progress(MoveProgress(moveID: plan.id, phase: .preflight))

        // P1 to P14, with the drive read again right now (E18).
        guard let drive = await DriveInspector.facts(forVolumeID: plan.destination.volumeUUID) else {
            return halt(plan, home, .driveChanged, Say.driveGone)
        }
        let checked = Preflight.run(plan, recipe: recipe, drive: drive, home: home, snapshot: RunningApps.snapshot(for: recipe, home: home),
                                    journalWritable: Journal.isWritable(home: home), policy: policy, macOS: currentOS())
        switch checked {
        case .passed: break
        case .failed(let report):
            return halt(plan, home, .preflightFailed, report.firstFailure?.detail ?? "A check failed.", preflight: report)
        }
        Journal.result(.preflight, subject: subject, home: home, status: .ok, counts: JournalCounts(checksPassed: checked.report.passedCount,
                                                                                                  checksTotal: checked.report.checks.count,
                                                                                                  freeBytes: drive.availableBytes),
                       vol: drive.uuid, volName: drive.name, fsName: drive.fileSystem.displayName)
        guard OutboardRoot.ensureRecipeFolder(plan: plan) else { return halt(plan, home, .driveChanged, Say.driveGone) }

        // Copying. The copy runs on its own thread; this loop reports bytes every half second (no estimate, no rate).
        let awake = Awake(reason: "Outboard is copying " + plan.recipeName)
        defer { awake.end() }
        let control = CopyControl()
        let copyDone = Flag()
        let copyStarted = Date()
        let copied: CopyResult = await withTaskCancellationHandler {
            let worker = Task.detached(priority: .userInitiated) { () -> CopyResult in
                let result = Copier.copy(plan, home: home, control: control)
                copyDone.set()
                return result
            }
            var polls = 0
            while !copyDone.isSet {
                // A cancelled task makes sleep throw at once; stop polling (onCancel already told the copy) and just wait for it to end.
                guard (try? await Task.sleep(nanoseconds: UInt64(Limits.progressPollMilliseconds) * 1_000_000)) != nil else { break }
                polls += 1
                var note: String?
                if polls % 10 == 0, let opened = openedBlocker(recipe, home: home) { note = "\(opened) opened. If it changes the data, the move will start over." }
                progress(MoveProgress(moveID: plan.id, phase: .copying, bytesDone: min(control.bytes, plan.logicalBytes), bytesTotal: plan.logicalBytes,
                                      filesDone: control.files, filesTotal: plan.sourceFingerprint.files,
                                      elapsedSeconds: Date().timeIntervalSince(copyStarted), note: note))
            }
            return await worker.value
        } onCancel: {
            control.cancel()
        }
        guard case .copied(let done) = copied else { return copyFailure(copied, plan, home, volume) }
        if VolumeWatcher.didSleep(since: copyStarted) { return halt(plan, home, .sleepInterrupted, "The Mac went to sleep while copying. Nothing on your Mac was changed.", partialCopy: true) }

        // Comparing: every file by size and SHA-256, the tree in every other way, and the source against Manifest A.
        guard Journal.intent(.verify, subject: subject, home: home, state: .verifying) else { return halt(plan, home, .journalUnwritable, Say.journalBlocked, partialCopy: true) }
        let cancel = Flag()
        let verified: VerifyOutcome = await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) { () -> VerifyOutcome in
                Verifier.verify(sourceRoot: plan.sourcePath, destinationRoot: done.destination, startManifest: done.startManifest,
                                isCancelled: { cancel.isSet }, progress: { n, total, bytes in
                    progress(MoveProgress(moveID: plan.id, phase: .verifying, bytesDone: bytes, bytesTotal: plan.logicalBytes, filesDone: n,
                                          filesTotal: total, elapsedSeconds: Date().timeIntervalSince(copyStarted)))
                })
            }.value
        } onCancel: {
            cancel.set()
        }
        switch verified {
        case .verified: break
        case .mismatch(let failure):
            Journal.result(.verify, subject: subject, home: home, status: failure.abort == .mismatch ? .mismatch : .failed,
                           counts: JournalCounts(differences: failure.differences.count))
            // A comparison that could not read the drive is not a difference between the files: say the drive left.
            if failure.abort != .mismatch, VolumeIdentity.absent(volume) {
                return halt(plan, home, .driveChanged, "The drive was disconnected while the copy was being checked. Nothing on your Mac was changed.", partialCopy: true)
            }
            return halt(plan, home, failure.abort, failure.message, differences: failure.differences, partialCopy: true)
        }
        guard let report = verified.report else { return halt(plan, home, .unknown, "The comparison did not finish.", partialCopy: true) }
        Journal.result(.verify, subject: subject, home: home, status: .ok, counts: JournalCounts(files: report.summary.filesCompared, bytes: report.summary.bytesCompared, differences: 0),
                       verification: report.summary)

        // Publishing: the verified copy gets its final name, with its sentinel and manifest beside it.
        progress(MoveProgress(moveID: plan.id, phase: .swapping, bytesDone: plan.logicalBytes, bytesTotal: plan.logicalBytes))
        let ctx = RuleContext(plan: plan, home: home)
        let published = Renamer.perform(.publish, from: done.destination, to: plan.destination.finalPath, ctx: ctx, subject: subject, home: home,
                                        expected: done.stagingStamp)
        guard published.isRenamed else { return halt(plan, home, reason(for: published), published.text, partialCopy: true) }
        guard Journal.intent(.publish, subject: subject, home: home, to: plan.sentinelPath, note: "check files") else {
            return halt(plan, home, .journalUnwritable, Say.journalBlocked, partialCopy: true)
        }
        let manifest = ManifestFile(moveID: plan.id, recipeID: plan.recipeID, createdAt: Date().wholeSeconds, entries: report.manifest,
                                    digest: report.summary.manifestDigest)
        let wrote = OutboardRoot.writeSentinel(plan: plan, now: Date())
            && ManifestStore.save(manifest, home: home, driveFolder: URL(fileURLWithPath: plan.destination.mountPoint + "/" + plan.destination.recipeFolder))
        Journal.result(.publish, subject: subject, home: home, status: wrote ? .ok : .failed, to: plan.sentinelPath, note: "check files")
        guard wrote else { return halt(plan, home, .copyFailed, "The check files could not be written to the drive.", partialCopy: true) }

        // W1 to W3: from this line to the redirect nothing may suspend. Everything is read again, then the original is renamed and the
        // app is pointed at the copy. An app that starts in this window finds either the original or a refusal, never a half state.
        switch Guard.recheck(plan, home: home, seen: SourceSeen(manifest: report.manifest, at: report.sourceWalkedAt)) {
        case .unchanged: break
        case .changed(let why): return halt(plan, home, .sourceChanged, why, partialCopy: true)
        }
        switch RunningCheck.state(recipe: recipe, snapshot: RunningApps.snapshot(for: recipe, home: home)) {
        case .notRunning: break
        case .running: return halt(plan, home, .appLaunched, "The app opened while the move was getting ready. Nothing on your Mac was changed.", partialCopy: true)
        case .unknown: return halt(plan, home, .appLaunched, Say.unknownRunning, partialCopy: true)
        }
        let aside = Renamer.perform(.setAside, from: plan.macPath, to: plan.beforeMovePath, ctx: ctx, subject: subject, home: home, expected: plan.sourceStamp)
        guard aside.isRenamed else { return halt(plan, home, reason(for: aside), aside.text, partialCopy: true) }
        let redirected = Redirect.apply(plan, home: home)
        switch redirected {
        case .applied: break
        case .exists: return undone(plan, .foreignFolderAppeared, home)
        case .refused: return undone(plan, .driveChanged, home)
        case .failed(let code, _): return undone(plan, code == EPERM || code == EACCES ? .needsPermission : .healthFailed, home)
        case .notAttempted: return undone(plan, .journalUnwritable, home)
        }
        switch Health.check(plan, home: home) {
        case .healthy: break
        case .failed(let why): return undone(plan, why == Health.manifestUnreadable ? .manifestUnreadable : .healthFailed, home)
        }
        Journal.result(.swapped, subject: subject, home: home, status: .ok, state: .swapped, counts: JournalCounts(files: report.summary.filesCompared, bytes: plan.logicalBytes),
                       verification: report.summary)
        return MoveOutcome(action: .move, moveID: plan.id, state: .swapped, ok: true,
                           message: "Moved \(Format.bytes(plan.logicalBytes)) to \(volume.label). Your original is kept until you confirm.",
                           preflight: checked.report, verification: report.summary)
    }

    // MARK: - Helpers (after `run` on purpose: the pinned order in the file is the order of the calls above)

    static func currentOS() -> MinOS {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return MinOS(v.majorVersion, v.minorVersion)
    }

    static func refusal(_ plan: MovePlan, _ message: String) -> MoveOutcome {
        MoveOutcome(action: .move, moveID: plan.id, state: .planned, ok: false, message: message)
    }

    /// The name of a running blocker, if one started since the preflight.
    private static func openedBlocker(_ recipe: Recipe, home: String) -> String? {
        let snapshot = RunningApps.snapshot(for: recipe, home: home, includeHandles: false)
        return RunningCheck.blockers(recipe: recipe, snapshot: snapshot).first { !$0.isClear }?.name
    }

    private static func reason(for rename: RenameResult) -> AbortReason {
        if case .failed(let code, _) = rename, code == EPERM || code == EACCES { return .needsPermission }
        if case .changed = rename { return .sourceChanged }
        return .unknown
    }

    private static func copyFailure(_ result: CopyResult, _ plan: MovePlan, _ home: String, _ volume: VolumeRef) -> MoveOutcome {
        switch result {
        case .refused(let why): return halt(plan, home, .preflightFailed, why)
        case .changed(let why): return halt(plan, home, .sourceChanged, why)
        case .notAttempted(let why): return halt(plan, home, .journalUnwritable, why)
        case .failed(let code, let message):
            // The central risk of this product: the cable came out. Said in plain words, not as a system error. `halt` adds the sentence
            // about the partial copy.
            if VolumeIdentity.absent(volume) {
                return halt(plan, home, .driveChanged, "The drive was disconnected while copying. Nothing on your Mac was changed.", partialCopy: true, errno: code)
            }
            let abort: AbortReason = code == ENOSPC ? .destinationFull : (code == EPERM || code == EACCES ? .needsPermission : .copyFailed)
            return halt(plan, home, abort, message, partialCopy: true, errno: code)
        case .cancelled: return halt(plan, home, .userCancelled, "Stopped. Nothing on your Mac was changed.", partialCopy: true)
        case .copied: return halt(plan, home, .unknown, "The copy did not finish.", partialCopy: true)
        }
    }

    /// The swap went wrong after the original was renamed: it is put back (`Rollback.automatic`). The move did not happen, so the
    /// outcome is a failure, whether or not the undo itself went well (its own message says).
    private static func undone(_ plan: MovePlan, _ reason: AbortReason, _ home: String) -> MoveOutcome {
        var outcome = Rollback.automatic(plan, reason: reason, home: home)
        let leaf = Fs.leaf(of: plan.macPath)
        if outcome.ok {
            switch reason {
            case .foreignFolderAppeared:
                outcome.message = "Something new appeared at \(leaf) while the move was running. It was set aside as \(leaf)\(Names.createdWhileMovingSuffix) and your original is back."
            case .healthFailed:
                outcome.message = "The link or setting did not point at the drive, so Outboard put your original back."
            case .manifestUnreadable:
                outcome.message = "The check list made when the copy was taken could not be read back, so Outboard put your original back."
            default:
                outcome.message = "The move was undone. Your original is back where it was."
            }
        }
        outcome.ok = false
        outcome.abort = reason
        return outcome
    }

    /// Ends the move as Aborted. Nothing on the Mac changed; a partial copy on the drive is labelled and offered for the Trash.
    static func halt(_ plan: MovePlan, _ home: String, _ reason: AbortReason, _ message: String, preflight: PreflightReport? = nil,
                             differences: [Difference] = [], partialCopy: Bool = false, errno: Int32? = nil) -> MoveOutcome {
        let tail = partialCopy ? " A partial copy may be on the drive; it is listed under Leftovers." : ""
        // The journal gets the reason code, never `message`: that text can carry a system error's wording or a file name. The outcome keeps it.
        Journal.result(.abort, subject: JournalSubject(plan), home: home, status: .ok, errno: errno, abort: reason, state: .aborted, note: reason.rawValue)
        return MoveOutcome(action: .move, moveID: plan.id, state: .aborted, ok: false, abort: reason, message: message + tail, preflight: preflight,
                           differences: differences, errnoCode: errno)
    }
}

extension VerifyOutcome {
    var report: VerifyReport? {
        if case .verified(let r) = self { return r }
        return nil
    }
}
