import Foundation

/// The demo implementation of `Backend` (BUILD_PLAN §4.6, §5.10, §9): serves a scenario's synthetic Mac and mutates an in-memory
/// copy of it. Nothing is read from or written to the real system and the activity log lives in memory. Plans come from the real
/// `MovePlanner`, drives are judged by the real `Eligibility`, the journal is folded by the real `RelocationFold`, recovery and the
/// guard decide with the real `Recovery` and `GuardPolicy`, and a move compares its trees with the real `TreeCompare`. The
/// exception is timing: a whole move takes `seconds` (staggered over its beats so the screens animate), 0 for tests.
public enum DemoBackend {
    /// `now` is the only clock: the world is built around it and every journal line is stamped from it. `failure` injects one
    /// failure into the moves of this backend (see `DemoFailure`).
    public static func make(_ scenario: DemoScenario, seconds: Double = 1.2, now: Date = DemoScenarios.referenceNow, failure: DemoFailure? = nil) -> Backend {
        makeWithState(scenario, seconds: seconds, now: now, failure: failure).backend
    }

    static func makeWithState(_ scenario: DemoScenario, seconds: Double, now: Date, failure: DemoFailure?) -> (backend: Backend, state: DemoState) {
        let state = DemoState(DemoScenarios.world(scenario), now: now, failure: failure)
        let nothing: @Sendable () -> Void = {}
        let backend = Backend(
            measure: { ids in state.locked { state.scans(ids) } },
            volumes: { state.locked { state.currentVolumes() } },
            eligibility: { volumeID, recipeID in state.locked { state.eligibility(volumeID, recipeID) } },
            blockers: { recipeID in state.locked { state.blockers(recipeID) } },
            fullDiskAccess: { state.world.fullDiskAccess },
            relocations: { state.locked { state.records() } },
            leftovers: { state.locked { state.leftovers() } },
            loadLog: { state.locked { state.journal } },
            diagnostics: { state.locked { state.diagnostics() } },
            useDrive: { volumeID in state.locked { state.useDrive(volumeID) } },
            plan: { recipeID, volumeID, consent in state.locked { state.planMove(recipeID, volumeID, consent) } },
            move: { plan, progress in await runMove(plan, progress, state: state, seconds: seconds) },
            confirm: { moveID in state.locked { state.confirm(moveID) } },
            rollback: { moveID in state.locked { state.rollback(moveID) } },
            returnToMac: { moveID, progress in await runReturn(moveID, progress, state: state, seconds: seconds) },
            forget: { moveID in state.locked { state.forget(moveID) } },
            checkAndReconnect: { moveID, progress in await runCheck(moveID, progress, state: state, seconds: seconds) },
            setAsideAndReconnect: { moveID in state.locked { state.setAsideAndReconnect(moveID) } },
            trashLeftover: { leftoverID in state.locked { state.trashLeftover(leftoverID) } },
            recordGuideViewed: { recipeID in state.locked { state.recordGuideViewed(recipeID) } },
            reconcile: { trigger in state.locked { state.reconcile(trigger) } },
            watch: { _ in nothing },
            loginItemState: { state.locked { state.loginItem } },
            setLoginItem: { enabled in state.locked { state.setLoginItem(enabled) } },
            isDemo: true)
        return (backend, state)
    }

    // MARK: Running a move

    private static func pause(_ seconds: Double, beats: Int) -> UInt64 {
        UInt64(max(seconds, 0) / Double(max(beats, 1)) * 1_000_000_000)
    }

    /// Runs the beats in order, reporting progress after each. Returns the outcome of a beat that stopped the move, or nil when
    /// every beat ran. A cancelled task stops the move at the next beat (the person pressed Cancel).
    private static func execute(_ steps: [DemoStep], _ plan: MovePlan, _ progress: @escaping @Sendable (MoveProgress) -> Void,
                                state: DemoState, seconds: Double, freezes: Bool) async -> MoveOutcome? {
        let gap = pause(seconds, beats: steps.count)
        for step in steps {
            if Task.isCancelled { return state.locked { state.cancelled(plan) } }
            if let act = step.act, let stop = state.locked({ act(state) }) { return stop }
            progress(state.locked { state.progress(plan, step) })
            if freezes, let f = state.world.frozen, step.phase == f.phase, step.fraction >= f.fraction {
                // Frozen on purpose: a screenshot of "Copying, 41%". Only a cancelled task leaves this.
                while !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000_000) }
                return state.locked { state.cancelled(plan) }
            }
            if gap > 0 { try? await Task.sleep(nanoseconds: gap) }
        }
        return nil
    }

    private static func runMove(_ plan: MovePlan, _ progress: @escaping @Sendable (MoveProgress) -> Void, state: DemoState, seconds: Double) async -> MoveOutcome {
        guard let recipe = Catalogue.recipe(plan.recipeID) else {
            return state.locked { state.refusedAction(.move, plan.id, .aborted, "Outboard doesn't know that app.") }
        }
        let steps = state.locked { () -> [DemoStep] in
            state.flights += 1
            state.started += 1
            return state.steps(plan, recipe)
        }
        let stopped = await execute(steps, plan, progress, state: state, seconds: seconds, freezes: true)
        return state.locked {
            state.flights -= 1
            return stopped ?? state.successOutcome(plan)
        }
    }

    private enum Prepared {
        case refused(MoveOutcome)
        case ready(RelocationRecord, MovePlan, [DemoStep])
    }

    private static func runReturn(_ moveID: String, _ progress: @escaping @Sendable (MoveProgress) -> Void, state: DemoState, seconds: Double) async -> MoveOutcome {
        let prepared: Prepared = state.locked {
            guard let r = state.record(moveID) else { return .refused(state.refusedAction(.returnToMac, moveID, .aborted, "Outboard has no record of that move.")) }
            guard r.canReturn else { return .refused(state.refusedAction(.returnToMac, moveID, r.state, "This move can't be returned to your Mac right now.")) }
            guard let drive = state.drive(r.volume.uuid) else {
                return .refused(state.refusedAction(.returnToMac, moveID, r.state, "\(r.volume.label) isn't connected. Plug it in to bring the data back."))
            }
            let id = MovePlanner.newMoveID(now: state.now, random: 0x0e7e40 + UInt32(state.started))
            let result = MovePlanner.returnPlan(for: r, drive: drive, home: state.home, now: state.cursor, moveID: id)
            guard let plan = result.plan else {
                return .refused(state.refusedAction(.returnToMac, moveID, r.state, result.refusal ?? "The data can't be returned right now. Nothing was changed."))
            }
            state.flights += 1
            state.started += 1
            return .ready(r, plan, state.returnSteps(r, plan))
        }
        let record: RelocationRecord, plan: MovePlan, steps: [DemoStep]
        switch prepared {
        case .refused(let outcome): return outcome
        case .ready(let r, let p, let s): (record, plan, steps) = (r, p, s)
        }
        let stopped = await execute(steps, plan, progress, state: state, seconds: seconds, freezes: false)
        return state.locked {
            state.flights -= 1
            if var stop = stopped {
                stop.action = .returnToMac
                return stop
            }
            return MoveOutcome(action: .returnToMac, moveID: moveID, state: .returned, ok: true,
                               message: "Back on your Mac. The copy on \(record.volume.label) stays there until you move it to the Trash.",
                               verification: state.summaries[plan.id])
        }
    }

    private static func runCheck(_ moveID: String, _ progress: @escaping @Sendable (MoveProgress) -> Void, state: DemoState, seconds: Double) async -> MoveOutcome {
        let prepared = state.locked { state.prepareCheck(moveID) }
        if let refusal = prepared.refusal { return refusal }
        guard let check = prepared.check else { return state.refusedAction(.checkAndReconnect, moveID, .aborted, "Nothing was changed.") }
        guard state.locked({ state.beginCheck(check) }) else {
            return state.refusedAction(.checkAndReconnect, moveID, check.record.state, DemoScenarios.journalBlockedMessage)
        }
        let ticks = [0.15, 0.4, 0.65, 0.85, 1.0]
        for f in ticks {
            progress(MoveProgress(moveID: check.record.id, phase: .verifying, bytesDone: 0, bytesTotal: 0, filesDone: Int(Double(check.unchanged) * f),
                                  filesTotal: check.unchanged, elapsedSeconds: (f * 60).rounded()))
            let gap = pause(seconds, beats: ticks.count)
            if gap > 0 { try? await Task.sleep(nanoseconds: gap) }
        }
        return state.locked { state.finishCheck(check) }
    }
}

extension DemoState {
    /// The person cancelled (or the task was cancelled): the move ends in Aborted, and a half-made copy on the drive stays there
    /// as a labelled leftover. A move that never wrote its first line has nothing to abort.
    func cancelled(_ plan: MovePlan) -> MoveOutcome {
        let message = "Stopped. Your Mac was not changed."
        guard seqs[plan.id] != nil, record(plan.id)?.state.isTerminal == false else {
            return MoveOutcome(action: .move, moveID: plan.id, state: .aborted, ok: false, abort: .userCancelled, message: message)
        }
        return abortMove(plan, .userCancelled, message)
    }
}
