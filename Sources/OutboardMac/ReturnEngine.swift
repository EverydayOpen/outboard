import Darwin
import Foundation
import OutboardCore

/// "Return to Mac" (BUILD_PLAN §5.5, safety-ux 2.6): a new move in the other direction with the same steps. The copy on the drive is
/// compared, then copied to `<name>.returning-<id>` beside the path, compared again, and swapped in: the link (or the note, or the
/// setting) is taken away and the returned copy takes the path. The copy on the drive stays until the user moves it to the Trash.
/// The way out (the old record) ends Returned; the way back is its own record. Nothing is deleted.
extension MoveEngine {
    static func returnToMac(_ record: RelocationRecord, home: String, policy: Policy, progress: @escaping @Sendable (MoveProgress) -> Void) async -> MoveOutcome {
        func stop(_ message: String) -> MoveOutcome { MoveOutcome(action: .returnToMac, moveID: record.id, state: record.state, ok: false, message: message) }
        guard record.canReturn else { return stop("Only a confirmed move can come back to your Mac.") }
        guard let recipe = Catalogue.recipe(record.recipeID) else { return stop("Outboard does not know this recipe, so nothing was changed.") }
        guard MutationGate.tryEnter() else { return stop(Say.busy) }
        defer { MutationGate.leave() }
        guard let drive = await DriveInspector.facts(forVolumeID: record.volume.uuid) else { return stop("Plug \(record.volume.label) in to bring the data back.") }

        let planned = MovePlanner.returnPlan(for: record, drive: drive, home: home, now: Date(), moveID: MovePlanner.newMoveID(now: Date(), random: UInt32.random(in: 0...0xFF_FFFF)))
        guard var draft = planned.plan else { return stop(planned.refusal ?? "The data can't be returned right now. Nothing was changed.") }
        // The plan only knows the file count and size; the stamp and the fingerprint come from a walk of the copy on the drive.
        guard let stamp = Fs.stamp(of: draft.sourcePath), let walked = SizeScanner.walk(draft.sourcePath, xattrs: false), walked.isComplete else {
            return stop("The copy on \(record.volume.label) could not be read end to end. Nothing was changed.")
        }
        draft.sourceStamp = stamp
        draft.sourceFingerprint = walked.fingerprint
        let plan = draft
        let subject = JournalSubject(plan)

        func ended(_ reason: AbortReason, _ message: String, partial: Bool = false, differences: [Difference] = [], preflight: PreflightReport? = nil) -> MoveOutcome {
            var outcome = halt(plan, home, reason, message, preflight: preflight, differences: differences, partialCopy: false)
            outcome.action = .returnToMac
            if partial { outcome.message += " A partial copy may be next to the folder as " + Fs.leaf(of: Copier.destinationPath(plan)) + "." }
            return outcome
        }

        guard Journal.begin(plan, onDriveMissing: record.onDriveMissing, volume: record.volume, home: home, at: Date()) else { return stop(Say.journalBlocked) }
        guard Journal.intent(.preflight, subject: subject, home: home, state: .preflight) else { return stop(Say.journalBlocked) }
        progress(MoveProgress(moveID: plan.id, phase: .preflight))
        let checked = Preflight.runReturn(plan, recipe: recipe, home: home, snapshot: RunningApps.snapshot(for: recipe, home: home),
                                          journalWritable: Journal.isWritable(home: home),
                                          original: JournalFacts(moveID: record.id, all: Journal.loadAll(home: home), home: home))
        if case .failed(let report) = checked { return ended(.preflightFailed, report.firstFailure?.detail ?? "A check failed.", preflight: report) }
        Journal.result(.preflight, subject: subject, home: home, status: .ok, counts: JournalCounts(checksPassed: checked.report.passedCount, checksTotal: checked.report.checks.count))

        // Copy back beside the path.
        let awake = Awake(reason: "Outboard is copying " + plan.recipeName + " back")
        defer { awake.end() }
        let control = CopyControl()
        let copyDone = Flag()
        let started = Date()
        let copied: CopyResult = await withTaskCancellationHandler {
            let worker = Task.detached(priority: .userInitiated) { () -> CopyResult in
                let result = Copier.copy(plan, home: home, control: control)
                copyDone.set()
                return result
            }
            while !copyDone.isSet {
                // A cancelled task makes sleep throw at once; stop polling (onCancel already told the copy) and just wait for it to end.
                guard (try? await Task.sleep(nanoseconds: UInt64(Limits.progressPollMilliseconds) * 1_000_000)) != nil else { break }
                progress(MoveProgress(moveID: plan.id, phase: .copying, bytesDone: min(control.bytes, plan.logicalBytes), bytesTotal: plan.logicalBytes,
                                      filesDone: control.files, filesTotal: plan.sourceFingerprint.files, elapsedSeconds: Date().timeIntervalSince(started)))
            }
            return await worker.value
        } onCancel: {
            control.cancel()
        }
        guard case .copied(let done) = copied else {
            switch copied {
            case .failed(_, let message):
                if VolumeIdentity.absent(record.volume) { return ended(.driveChanged, "The drive was disconnected while copying. Nothing was changed.", partial: true) }
                return ended(.copyFailed, message, partial: true)
            case .cancelled: return ended(.userCancelled, "Stopped. Nothing on your Mac was changed.", partial: true)
            case .refused(let why), .changed(let why): return ended(.preflightFailed, why)
            case .notAttempted(let why): return ended(.journalUnwritable, why)
            case .copied: return ended(.unknown, "The copy did not finish.", partial: true)
            }
        }
        if VolumeWatcher.didSleep(since: started) { return ended(.sleepInterrupted, "The Mac went to sleep while copying. Nothing was changed.", partial: true) }

        // Compare.
        guard Journal.intent(.verify, subject: subject, home: home, state: .verifying) else { return ended(.journalUnwritable, Say.journalBlocked, partial: true) }
        let cancel = Flag()
        let verified: VerifyOutcome = await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) { () -> VerifyOutcome in
                Verifier.verify(sourceRoot: plan.sourcePath, destinationRoot: done.destination, startManifest: done.startManifest,
                                isCancelled: { cancel.isSet }, progress: { n, total, bytes in
                    progress(MoveProgress(moveID: plan.id, phase: .verifying, bytesDone: bytes, bytesTotal: plan.logicalBytes, filesDone: n,
                                          filesTotal: total, elapsedSeconds: Date().timeIntervalSince(started)))
                })
            }.value
        } onCancel: {
            cancel.set()
        }
        guard let report = verified.report else {
            if case .mismatch(let failure) = verified {
                Journal.result(.verify, subject: subject, home: home, status: failure.abort == .mismatch ? .mismatch : .failed,
                               counts: JournalCounts(differences: failure.differences.count))
                if failure.abort != .mismatch, VolumeIdentity.absent(record.volume) {
                    return ended(.driveChanged, "The drive was disconnected while the copy was being checked. Nothing was changed.", partial: true)
                }
                return ended(failure.abort, failure.message, partial: true, differences: failure.differences)
            }
            return ended(.unknown, "The comparison did not finish.", partial: true)
        }
        Journal.result(.verify, subject: subject, home: home, status: .ok, counts: JournalCounts(files: report.summary.filesCompared, bytes: report.summary.bytesCompared, differences: 0),
                       verification: report.summary)

        // Swap: the redirect goes away, the returned copy takes the path. From here to the last line nothing suspends.
        progress(MoveProgress(moveID: plan.id, phase: .swapping, bytesDone: plan.logicalBytes, bytesTotal: plan.logicalBytes))
        switch RunningCheck.state(recipe: recipe, snapshot: RunningApps.snapshot(for: recipe, home: home)) {
        case .notRunning: break
        case .running: return ended(.appLaunched, "\(recipe.name) opened while the copy was being checked. Nothing on your Mac was changed.", partial: true)
        case .unknown: return ended(.appLaunched, Say.unknownRunning, partial: true)
        }
        guard let target = RollbackTarget(plan: plan, home: home) else { return ended(.unknown, "Outboard does not know this recipe.", partial: true) }
        // The way out's own closing line is claimed before anything is swapped: if the journal cannot take it, nothing moves. A stop
        // after the swap and before that line is closed by recovery (`markReturned`).
        let old = JournalSubject(record)
        guard Journal.intent(.returned, subject: old, home: home, src: record.relativePath, to: plan.macPath) else {
            return ended(.journalUnwritable, Say.journalBlocked, partial: true)
        }
        let reverted = Redirect.revert(target, home: home, factsMoveID: record.id)
        guard reverted.isApplied else { return ended(.foreignFolderAppeared, "Something new is where the folder goes, so it was left alone. " + reverted.text, partial: true) }
        let published = Renamer.perform(.publish, from: done.destination, to: plan.macPath, ctx: RuleContext(plan: plan, home: home), subject: subject, home: home,
                                        expected: done.stagingStamp)
        guard published.isRenamed else {
            restoreRedirect(record, mount: drive.mountPoint, home: home)
            return ended(.unknown, "The returned copy could not take its place: " + published.text + " The link or setting was put back.", partial: true)
        }
        guard Fs.isPlainDirectory(plan.macPath) else {
            return ended(.healthFailed, "The returned folder is not where it should be. Check the activity log.", partial: true)
        }
        Journal.result(.swapped, subject: subject, home: home, status: .ok, state: .swapped, verification: report.summary)
        Journal.result(.returned, subject: old, home: home, status: .ok, state: .returned, src: record.relativePath, to: plan.macPath)
        Reconcile.forgetState(of: record.id)
        return MoveOutcome(action: .returnToMac, moveID: record.id, state: .returned, ok: true,
                           message: "Back on your Mac. The copy on \(record.volume.label) stays there until you move it to the Trash.",
                           preflight: checked.report, verification: report.summary)
    }

    /// The returned copy could not take its place: the link or the setting is put back so the app still finds its data on the drive.
    private static func restoreRedirect(_ record: RelocationRecord, mount: String, home: String) {
        if record.method == .defaults {
            guard let recipe = Catalogue.recipe(record.recipeID), let domain = record.defaultsDomain else { return }
            _ = DefaultsRedirect.reapply(domain: domain, writes: Health.recomputedWrites(record, mountPoint: mount), subject: JournalSubject(record), recipe: recipe, home: home)
        } else {
            let facts = GuardFacts(path: .missing, drive: .mountedAtRecordedPath)
            _ = Relink.recreate(record, facts: facts, home: home)
        }
    }
}
