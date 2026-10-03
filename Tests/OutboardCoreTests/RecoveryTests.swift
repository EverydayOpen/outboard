import Foundation
import XCTest
@testable import OutboardCore

final class RecoveryTests: XCTestCase {
    private func rec(_ method: MethodKind, _ state: MoveState, _ step: MoveStep, _ phase: JournalPhase, _ status: StepStatus? = nil) -> RelocationRecord {
        T.record(recipeID: method == .defaults ? "xcode-deriveddata" : "ollama-models", state: state,
                 last: JournalMark(step: step, phase: phase, status: status ?? (phase == .result ? .ok : nil)), method: method) {
            // In these rows the journal has the `rollback` line that began the undo.
            $0.rollbackStarted = [.rollback, .undoRedirect, .undoSetAside, .setAsideForeign].contains(step)
        }
    }

    /// The record types of the recovery table: where the journal stopped.
    private let types: [(String, MoveState, MoveStep, JournalPhase)] = [
        ("preflight", .preflight, .preflight, .intent),
        ("planned", .planned, .begin, .intent),
        ("copying", .copying, .copy, .intent),
        ("copied", .copying, .copy, .result),
        ("verifying", .verifying, .verify, .intent),
        ("verified", .verifying, .verify, .result),
        ("publishing", .verifying, .publish, .intent),
        ("published", .verifying, .publish, .result),
        ("setAsideIntent", .verifying, .setAside, .intent),
        ("setAsideDone", .verifying, .setAside, .result),
        ("redirectIntent", .verifying, .redirect, .intent),
        ("redirectDone", .verifying, .redirect, .result),
        ("swapped", .swapped, .swapped, .result),
        ("confirmIntent", .swapped, .confirm, .intent),
        ("confirmed", .confirmed, .confirm, .result),
        ("trashIntent", .confirmed, .trash, .intent),
        ("trashed", .originalTrashed, .trash, .result),
        ("rollbackStarted", .swapped, .rollback, .intent),
        ("rollbackUndoRedirect", .swapped, .undoRedirect, .result),
        ("rollbackUndoSetAside", .swapped, .undoSetAside, .intent),
        ("parkIntent", .swapped, .park, .intent),
        ("parked", .confirmed, .park, .result),
        ("unparkIntent", .confirmed, .unpark, .intent),
        ("returnIntent", .confirmed, .returned, .intent),
        ("returnIntentAfterTrash", .originalTrashed, .returned, .intent),
        ("recovered", .swapped, .recover, .result),
        ("rolledBack", .rolledBack, .rollback, .result),
        ("aborted", .aborted, .abort, .result),
        ("returned", .returned, .returned, .result),
        ("forgotten", .forgotten, .forget, .result),
    ]

    private func allFacts(_ method: MethodKind) -> [RecoveryFacts] {
        let kinds: [PathKind] = [.real, .link, .placeholder, .missing, .other]
        let settings: [SettingFact] = method == .defaults ? [.new, .prior, .other] : [.notApplicable]
        var out: [RecoveryFacts] = []
        for d in [false, true] { for x in kinds { for b in [false, true] { for s in [false, true] { for f in [false, true] {
            for k in settings { for h in [false, true] { for p in [false, true] { for r in [false, true] {
                out.append(RecoveryFacts(drivePresent: d, path: x, beforeMovePresent: b, stagingPresent: s, publishedPresent: f, setting: k, healthPasses: h, parkedLinkPresent: p, returnSwapped: r))
            } } } }
        } } } } }
        return out
    }

    // MARK: the theorem

    func testEveryRecordTypeTimesEveryCombinationOfFactsIsSafeAndIdempotent() {
        var cases = 0
        var failures: [String] = []
        var actionsSeen: Set<String> = []
        for method in [MethodKind.symlink, .defaults] {
            let facts = allFacts(method)
            for (name, state, step, phase) in types {
                let record = rec(method, state, step, phase)
                for f in facts {
                    cases += 1
                    let action = Recovery.decide(record: record, facts: f)
                    actionsSeen.insert(String(describing: action).components(separatedBy: "(").first ?? "")
                    XCTAssertEqual(action, Recovery.decide(record: record, facts: f), "deterministic")
                    let v = RecoverySimulator.violations(of: action, record: record, facts: f)
                    if !v.isEmpty && failures.count < 6 { failures.append("\(method) \(name) \(f) -> \(action): \(v)") }
                }
            }
        }
        XCTAssertEqual(failures, [])
        XCTAssertGreaterThan(cases, 20_000)
        // every kind of action is reachable
        for expected in ["noop", "abort", "rollbackOriginal", "setAsideForeignThenRollback", "adoptSwapped", "remainSwapped", "remainConfirmed", "markTrashedUnrecorded",
                         "continueRollback", "finishPark", "createPlaceholder", "unpark", "recreateLink", "markReturned", "needsAttention"] {
            XCTAssertTrue(actionsSeen.contains(expected), "\(expected) is never chosen")
        }
    }

    func testTerminalRecordsNeedNothing() {
        for state in MoveState.allCases where state.isTerminal {
            let r = rec(.symlink, state, .abort, .result)
            for f in allFacts(.symlink) { XCTAssertEqual(Recovery.decide(record: r, facts: f), .noop) }
        }
    }

    func testTheSimulatorCatchesAnActionThatWouldOverwriteMergeOrLose() {
        let r = rec(.symlink, .verifying, .setAside, .result)
        // renaming the original back over a folder that is there
        XCTAssertFalse(RecoverySimulator.violations(of: .rollbackOriginal, record: r, facts: RecoveryFacts(drivePresent: true, path: .real, beforeMovePresent: true)).isEmpty)
        // rolling back with no original anywhere
        XCTAssertFalse(RecoverySimulator.violations(of: .rollbackOriginal, record: r, facts: RecoveryFacts(drivePresent: true, path: .missing, beforeMovePresent: false)).isEmpty)
        // aborting while two originals exist, or none
        XCTAssertFalse(RecoverySimulator.violations(of: .abort(.interrupted, labelLeftovers: false), record: r, facts: RecoveryFacts(drivePresent: true, path: .real, beforeMovePresent: true)).isEmpty)
        XCTAssertFalse(RecoverySimulator.violations(of: .abort(.interrupted, labelLeftovers: false), record: r, facts: RecoveryFacts(drivePresent: true, path: .missing, beforeMovePresent: true)).isEmpty)
        // adopting a redirect that is not healthy
        XCTAssertFalse(RecoverySimulator.violations(of: .adoptSwapped, record: r, facts: RecoveryFacts(drivePresent: true, path: .link, beforeMovePresent: true, publishedPresent: true, healthPasses: false)).isEmpty)
        // continuing a rollback with two originals would merge them
        XCTAssertFalse(RecoverySimulator.violations(of: .continueRollback, record: r, facts: RecoveryFacts(drivePresent: true, path: .real, beforeMovePresent: true)).isEmpty)
        // a note over something that is there; a link to a copy that is not there
        let active = rec(.symlink, .swapped, .swapped, .result)
        XCTAssertFalse(RecoverySimulator.violations(of: .createPlaceholder, record: active, facts: RecoveryFacts(drivePresent: false, path: .other, beforeMovePresent: true)).isEmpty)
        XCTAssertFalse(RecoverySimulator.violations(of: .recreateLink, record: active, facts: RecoveryFacts(drivePresent: true, path: .missing, beforeMovePresent: true, publishedPresent: false)).isEmpty)
        // calling the safety copy gone while it is there
        let confirmed = rec(.symlink, .confirmed, .trash, .intent)
        XCTAssertFalse(RecoverySimulator.violations(of: .markTrashedUnrecorded, record: confirmed, facts: RecoveryFacts(drivePresent: true, path: .link, beforeMovePresent: true)).isEmpty)
        // and the good case is clean
        XCTAssertEqual(RecoverySimulator.violations(of: .rollbackOriginal, record: r, facts: RecoveryFacts(drivePresent: true, path: .missing, beforeMovePresent: true)), [])
    }

    // MARK: the rows of the table

    func testBeforeTheOriginalIsRenamedTheMoveAbortsAndStartsOver() {
        let real = RecoveryFacts(drivePresent: true, path: .real, beforeMovePresent: false)
        for (_, state, step, phase) in types.prefix(8) {
            let r = rec(.symlink, state, step, phase)
            XCTAssertEqual(Recovery.decide(record: r, facts: real), .abort(.interrupted, labelLeftovers: false), "\(step)")
            var leftovers = real
            leftovers.stagingPresent = true
            XCTAssertEqual(Recovery.decide(record: r, facts: leftovers), .abort(.interrupted, labelLeftovers: true))
            var published = real
            published.publishedPresent = true
            XCTAssertEqual(Recovery.decide(record: r, facts: published), .abort(.interrupted, labelLeftovers: true))
            // should be impossible: the original is not where it was
            XCTAssertEqual(Recovery.decide(record: r, facts: RecoveryFacts(drivePresent: true, path: .other, beforeMovePresent: false)), .needsAttention(.originalNotAtPath))
        }
    }

    func testRenameIntentWithoutAResult() {
        let r = rec(.symlink, .verifying, .setAside, .intent)
        XCTAssertEqual(Recovery.decide(record: r, facts: RecoveryFacts(drivePresent: true, path: .real, beforeMovePresent: false)), .abort(.interrupted, labelLeftovers: false), "the rename did not happen")
        XCTAssertEqual(Recovery.decide(record: r, facts: RecoveryFacts(drivePresent: true, path: .missing, beforeMovePresent: true)), .rollbackOriginal, "the rename happened")
        XCTAssertEqual(Recovery.decide(record: r, facts: RecoveryFacts(drivePresent: true, path: .real, beforeMovePresent: true)), .needsAttention(.twoOriginals))
        XCTAssertEqual(Recovery.decide(record: r, facts: RecoveryFacts(drivePresent: true, path: .link, beforeMovePresent: true)), .needsAttention(.unrecognisedState), "no redirect was started yet")
    }

    func testRedirectIntentForALink() {
        let r = rec(.symlink, .verifying, .redirect, .intent)
        let healthy = RecoveryFacts(drivePresent: true, path: .link, beforeMovePresent: true, publishedPresent: true, healthPasses: true)
        XCTAssertEqual(Recovery.decide(record: r, facts: healthy), .adoptSwapped)
        var sick = healthy
        sick.healthPasses = false
        XCTAssertEqual(Recovery.decide(record: r, facts: sick), .continueRollback)
        var noCopy = healthy
        noCopy.publishedPresent = false
        XCTAssertEqual(Recovery.decide(record: r, facts: noCopy), .continueRollback, "never adopt a link to a copy that is not there")
        XCTAssertEqual(Recovery.decide(record: r, facts: RecoveryFacts(drivePresent: true, path: .missing, beforeMovePresent: true)), .rollbackOriginal)
        XCTAssertEqual(Recovery.decide(record: r, facts: RecoveryFacts(drivePresent: true, path: .other, beforeMovePresent: true)), .setAsideForeignThenRollback, "something new appeared in the gap")
    }

    func testRedirectIntentForASetting() {
        let r = rec(.defaults, .verifying, .redirect, .intent)
        let adopted = RecoveryFacts(drivePresent: true, path: .missing, beforeMovePresent: true, publishedPresent: true, setting: .new, healthPasses: true)
        XCTAssertEqual(Recovery.decide(record: r, facts: adopted), .adoptSwapped)
        var sick = adopted
        sick.healthPasses = false
        XCTAssertEqual(Recovery.decide(record: r, facts: sick), .continueRollback, "the setting must be put back too")
        var prior = adopted
        prior.setting = .prior
        XCTAssertEqual(Recovery.decide(record: r, facts: prior), .rollbackOriginal)
    }

    func testAfterTheSwapTheGuardOwnsTheRedirectAndRecoveryOnlyFinishesBookkeeping() {
        let link = RecoveryFacts(drivePresent: true, path: .link, beforeMovePresent: true, publishedPresent: true, healthPasses: true)
        XCTAssertEqual(Recovery.decide(record: rec(.symlink, .swapped, .swapped, .result), facts: link), .noop)
        XCTAssertEqual(Recovery.decide(record: rec(.symlink, .swapped, .confirm, .intent), facts: link), .remainSwapped)
        XCTAssertEqual(Recovery.decide(record: rec(.symlink, .confirmed, .trash, .intent), facts: link), .remainConfirmed)
        var gone = link
        gone.beforeMovePresent = false
        XCTAssertEqual(Recovery.decide(record: rec(.symlink, .confirmed, .trash, .intent), facts: gone), .markTrashedUnrecorded)
        XCTAssertEqual(Recovery.decide(record: rec(.symlink, .originalTrashed, .trash, .result), facts: gone), .noop)
        // an unfinished rollback is finished
        XCTAssertEqual(Recovery.decide(record: rec(.symlink, .swapped, .undoRedirect, .result), facts: link), .continueRollback)
        var foreign = link
        foreign.path = .other
        XCTAssertEqual(Recovery.decide(record: rec(.symlink, .swapped, .rollback, .intent), facts: foreign), .setAsideForeignThenRollback)
        var twoOriginals = link
        twoOriginals.path = .real
        XCTAssertEqual(Recovery.decide(record: rec(.symlink, .swapped, .rollback, .intent), facts: twoOriginals), .needsAttention(.twoOriginals))
        // a path with something else on it is the guard's business, never touched here
        for kind in [PathKind.other, .placeholder] {
            var f = link
            f.path = kind
            XCTAssertEqual(Recovery.decide(record: rec(.symlink, .swapped, .swapped, .result), facts: f), .noop)
        }
        // the original is back at the path in an active relocation: show it, touch nothing
        var back = link
        back.path = .real
        XCTAssertEqual(Recovery.decide(record: rec(.symlink, .swapped, .swapped, .result), facts: back), .needsAttention(.twoOriginals))
        back.beforeMovePresent = false
        XCTAssertEqual(Recovery.decide(record: rec(.symlink, .confirmed, .confirm, .result), facts: back), .needsAttention(.unrecognisedState))
    }

    func testParkAndUnparkInterruptions() {
        let parkIntent = rec(.symlink, .swapped, .park, .intent)
        func facts(_ path: PathKind, drive: Bool = false, healthy: Bool = false) -> RecoveryFacts {
            RecoveryFacts(drivePresent: drive, path: path, beforeMovePresent: true, publishedPresent: drive, healthPasses: healthy, parkedLinkPresent: path != .link)
        }
        XCTAssertEqual(Recovery.decide(record: parkIntent, facts: facts(.link, drive: true, healthy: true)), .noop, "not parked; the guard decides again")
        XCTAssertEqual(Recovery.decide(record: parkIntent, facts: facts(.placeholder)), .finishPark)
        XCTAssertEqual(Recovery.decide(record: parkIntent, facts: facts(.missing)), .createPlaceholder)
        XCTAssertEqual(Recovery.decide(record: parkIntent, facts: facts(.missing, drive: true)), .recreateLink, "the drive is back: rebuild, from the current mount point")
        let unparkIntent = rec(.symlink, .confirmed, .unpark, .intent)
        XCTAssertEqual(Recovery.decide(record: unparkIntent, facts: facts(.link, drive: true, healthy: true)), .unpark, "done: write the result")
        XCTAssertEqual(Recovery.decide(record: unparkIntent, facts: facts(.placeholder, drive: true)), .unpark, "retry when the drive is there")
        XCTAssertEqual(Recovery.decide(record: unparkIntent, facts: facts(.placeholder)), .noop)
        XCTAssertEqual(Recovery.decide(record: unparkIntent, facts: facts(.link, drive: true, healthy: false)), .noop)
        // a setting parks by being put back
        let settingPark = rec(.defaults, .swapped, .park, .intent)
        XCTAssertEqual(Recovery.decide(record: settingPark, facts: RecoveryFacts(drivePresent: false, path: .missing, beforeMovePresent: true, setting: .prior)), .finishPark)
        XCTAssertEqual(Recovery.decide(record: settingPark, facts: RecoveryFacts(drivePresent: true, path: .missing, beforeMovePresent: true, publishedPresent: true, setting: .new, healthPasses: true)), .noop)
        let settingUnpark = rec(.defaults, .swapped, .unpark, .intent)
        XCTAssertEqual(Recovery.decide(record: settingUnpark, facts: RecoveryFacts(drivePresent: true, path: .missing, beforeMovePresent: true, publishedPresent: true, setting: .prior)), .unpark)
    }

    func testAnActiveLinkThatVanishedIsRebuiltOrReplacedByTheNote() {
        let r = rec(.symlink, .swapped, .swapped, .result)
        XCTAssertEqual(Recovery.decide(record: r, facts: RecoveryFacts(drivePresent: true, path: .missing, beforeMovePresent: true, publishedPresent: true)), .recreateLink)
        XCTAssertEqual(Recovery.decide(record: r, facts: RecoveryFacts(drivePresent: false, path: .missing, beforeMovePresent: true)), .createPlaceholder)
        XCTAssertEqual(Recovery.decide(record: r, facts: RecoveryFacts(drivePresent: true, path: .missing, beforeMovePresent: true, publishedPresent: false)), .needsAttention(.unrecognisedState), "the copy is gone: show it")
        let setting = rec(.defaults, .swapped, .swapped, .result)
        XCTAssertEqual(Recovery.decide(record: setting, facts: RecoveryFacts(drivePresent: true, path: .missing, beforeMovePresent: true, publishedPresent: true, setting: .new)), .noop, "no link to rebuild")
    }

    func testAMoveBackToTheMacAbortsOrIsShown() {
        var back = T.record(state: .copying, last: JournalMark(step: .copy, phase: .intent))
        back.direction = .returnToMac
        XCTAssertEqual(Recovery.decide(record: back, facts: RecoveryFacts(drivePresent: true, path: .link, beforeMovePresent: false, stagingPresent: true)), .abort(.interrupted, labelLeftovers: true))
        XCTAssertEqual(Recovery.decide(record: back, facts: RecoveryFacts(drivePresent: true, path: .real, beforeMovePresent: false)), .needsAttention(.unrecognisedState))
        back.state = .swapped
        XCTAssertEqual(Recovery.decide(record: back, facts: RecoveryFacts(drivePresent: true, path: .real, beforeMovePresent: false)), .noop)
        for f in allFacts(.symlink) {
            var r = back
            r.state = .verifying
            XCTAssertEqual(RecoverySimulator.violations(of: Recovery.decide(record: r, facts: f), record: r, facts: f), [], "\(f)")
        }
    }

    func testResultingStates() {
        let verifying = rec(.symlink, .verifying, .setAside, .intent)
        let swapped = rec(.symlink, .swapped, .undoRedirect, .result)
        XCTAssertEqual(Recovery.resultingState(of: .abort(.interrupted, labelLeftovers: false), record: verifying), .aborted)
        XCTAssertEqual(Recovery.resultingState(of: .rollbackOriginal, record: verifying), .aborted, "the original is back and, net, nothing changed")
        XCTAssertEqual(Recovery.resultingState(of: .continueRollback, record: swapped), .rolledBack)
        XCTAssertEqual(Recovery.resultingState(of: .adoptSwapped, record: verifying), .swapped)
        XCTAssertEqual(Recovery.resultingState(of: .markTrashedUnrecorded, record: rec(.symlink, .confirmed, .trash, .intent)), .originalTrashed)
        XCTAssertEqual(Recovery.resultingState(of: .noop, record: swapped), .swapped)
        XCTAssertEqual(Recovery.resultingState(of: .createPlaceholder, record: swapped), .swapped)
    }

    func testMessages() {
        let r = T.record(recipeID: "xcode-deriveddata", state: .verifying, last: JournalMark(step: .setAside, phase: .intent), method: .defaults)
        let leaf = "DerivedData"
        XCTAssertEqual(Recovery.message(for: .noop, record: r), "")
        XCTAssertEqual(Recovery.message(for: .rollbackOriginal, record: r), "Restored your original \(leaf) after an interruption.")
        XCTAssertEqual(Recovery.message(for: .setAsideForeignThenRollback, record: r),
                       "Something new appeared at \(leaf) while the move was running. We set it aside as \(leaf).created-while-moving and restored your original.")
        XCTAssertEqual(Recovery.message(for: .adoptSwapped, record: r), "The move finished. Please check Xcode and confirm.")
        XCTAssertEqual(Recovery.message(for: .remainConfirmed, record: r), "Ready to move the safety copy to the Trash.")
        XCTAssertEqual(Recovery.message(for: .markTrashedUnrecorded, record: r), "The safety copy is gone from \(leaf).before-move; check the Trash.")
        XCTAssertEqual(Recovery.message(for: .abort(.interrupted, labelLeftovers: true), record: r).hasPrefix("Stopped part way. Your original was not touched."), true)
        var early = r
        early.state = .preflight
        XCTAssertEqual(Recovery.message(for: .abort(.interrupted, labelLeftovers: false), record: early), "The move was interrupted before anything was copied. Nothing on your Mac was changed.")
        var swapped = r
        swapped.state = .swapped
        XCTAssertEqual(Recovery.message(for: .continueRollback, record: swapped), "Finishing the undo.")
        XCTAssertEqual(Recovery.message(for: .recreateLink, record: r), "Rebuilt the link for Xcode.")
        var all: [RecoveryAction] = [.noop, .abort(.interrupted, labelLeftovers: true), .abort(.interrupted, labelLeftovers: false), .rollbackOriginal, .setAsideForeignThenRollback, .adoptSwapped,
                                     .remainSwapped, .remainConfirmed, .markTrashedUnrecorded, .continueRollback, .finishPark, .createPlaceholder, .unpark, .recreateLink, .markReturned]
        for reason in NeedsAttentionReason.allCases { all.append(.needsAttention(reason)) }
        for a in all {
            for rec in [r, early, swapped] {
                let m = Recovery.message(for: a, record: rec)
                XCTAssertEqual(BannedPhrases.hits(in: m), [], m)
                XCTAssertFalse(m.contains("/Users"), "no personal paths")
            }
        }
    }

    /// A journal cut off or damaged anywhere, folded, then recovered against any facts: the theorem still holds.
    func testRecoveryOfRandomlyDamagedJournalsNeverViolatesTheTheorem() {
        var rng = SplitMix64(seed: 20261003)
        var failures: [String] = []
        var folded = 0
        for method in ["ollama-models", "xcode-deriveddata"] {
            let plan = T.plan(method, bytes: 5_000_000_000)
            let full = T.journal(plan, mac: T.recipe(method).source ?? "~/x")
            let facts = allFacts(method == "xcode-deriveddata" ? .defaults : .symlink)
            for _ in 0..<400 {
                var lines = Array(full.prefix(Int(rng.next() % UInt64(full.count)) + 1))
                // drop a few lines at random (a torn line, a lost write), never the begin line
                for _ in 0..<Int(rng.next() % 3) where lines.count > 1 { lines.remove(at: Int(rng.next() % UInt64(lines.count - 1)) + 1) }
                if rng.next() % 5 == 0, lines.count > 2 { lines.swapAt(1, 2) }
                guard let record = RelocationFold.records(from: lines).first else { continue }
                folded += 1
                _ = ActivityText.rows(from: lines, problemsOnly: false)
                XCTAssertTrue(MoveState.allCases.contains(record.state))
                for _ in 0..<20 {
                    let f = facts[Int(rng.next() % UInt64(facts.count))]
                    let action = Recovery.decide(record: record, facts: f)
                    let v = RecoverySimulator.violations(of: action, record: record, facts: f)
                    if !v.isEmpty && failures.count < 5 { failures.append("\(record.state) \(record.last) \(f) -> \(action): \(v)") }
                }
            }
        }
        XCTAssertEqual(failures, [])
        XCTAssertGreaterThan(folded, 700)
    }

    // MARK: what makes a rollback "started"

    /// A journal folded from lines, so the test covers the fold and the table together.
    private func swappedXcodeJournal() -> (plan: MovePlan, lines: [JournalEntry]) {
        let plan = T.plan("xcode-deriveddata", bytes: 5_000_000_000)
        return (plan, T.journal(plan, upTo: .swapped, mac: T.recipe("xcode-deriveddata").source ?? "~/x"))
    }

    func testASettingPutBackByTheGuardIsNotAnInterruptedRollback() {
        // The guard writes the setting back when the drive goes away. Older logs did that with `undoRedirect` lines and no `rollback` line.
        let base = swappedXcodeJournal()
        let plan = base.plan
        var lines = base.lines
        lines.append(T.line(plan.id, lines.count + 1, .intent, .undoRedirect))
        lines.append(T.line(plan.id, lines.count + 1, .result, .undoRedirect, status: .ok))
        let record = RelocationFold.records(from: lines)[0]
        XCTAssertEqual(record.state, .swapped)
        XCTAssertEqual(record.last.step, .undoRedirect)
        XCTAssertFalse(record.rollbackStarted)
        var unwanted = 0
        for f in allFacts(.defaults) {
            let action = Recovery.decide(record: record, facts: f)
            if [.continueRollback, .rollbackOriginal, .setAsideForeignThenRollback].contains(action) { unwanted += 1 }
            XCTAssertEqual(RecoverySimulator.violations(of: action, record: record, facts: f), [], "\(f)")
        }
        XCTAssertEqual(unwanted, 0, "no rollback is finished that nobody started")
        // The setting is back at its prior value while the drive is away: that is a parked relocation, nothing to recover.
        let away = RecoveryFacts(drivePresent: false, path: .missing, beforeMovePresent: true, setting: .prior)
        XCTAssertEqual(Recovery.decide(record: record, facts: away), .noop)
    }

    func testARollbackLineMakesTheUndoLinesPartOfARollback() {
        let base = swappedXcodeJournal()
        let plan = base.plan
        var lines = base.lines
        lines.append(T.line(plan.id, lines.count + 1, .intent, .rollback))
        lines.append(T.line(plan.id, lines.count + 1, .intent, .undoRedirect))
        lines.append(T.line(plan.id, lines.count + 1, .result, .undoRedirect, status: .ok))
        let record = RelocationFold.records(from: lines)[0]
        XCTAssertTrue(record.rollbackStarted)
        let reverted = RecoveryFacts(drivePresent: true, path: .missing, beforeMovePresent: true, publishedPresent: true, setting: .prior)
        XCTAssertEqual(Recovery.decide(record: record, facts: reverted), .continueRollback)
        for f in allFacts(.defaults) {
            XCTAssertEqual(RecoverySimulator.violations(of: Recovery.decide(record: record, facts: f), record: record, facts: f), [], "\(f)")
        }
    }

    func testAMoveThatWasNeverRolledBackHasNoRollbackStarted() {
        let (plan, lines) = swappedXcodeJournal()
        XCTAssertFalse(RelocationFold.records(from: lines)[0].rollbackStarted)
        XCTAssertFalse(RelocationFold.records(from: T.journal(plan, upTo: .confirm))[0].rollbackStarted)
    }

    // MARK: a return that stopped before it closed the old record

    func testAReturnThatSwappedButDidNotCloseTheOldRecordIsClosed() {
        let swappedBack = RecoveryFacts(drivePresent: true, path: .other, beforeMovePresent: false, publishedPresent: true, returnSwapped: true)
        for state in [MoveState.confirmed, .originalTrashed] {
            for method in [MethodKind.symlink, .defaults] {
                let r = rec(method, state, .returned, .intent)
                var facts = swappedBack
                if method == .defaults { facts.setting = .prior }
                XCTAssertEqual(Recovery.decide(record: r, facts: facts), .markReturned, "\(state) \(method)")
                XCTAssertEqual(RecoverySimulator.violations(of: .markReturned, record: r, facts: facts), [])
                XCTAssertEqual(Recovery.resultingState(of: .markReturned, record: r), .returned)
                // Without a swapped return of its own the folder at the path is somebody else's: shown, never closed.
                var unknown = facts
                unknown.returnSwapped = false
                XCTAssertNotEqual(Recovery.decide(record: r, facts: unknown), .markReturned)
                // The link is still in place: the return stopped before its swap, so nothing is closed.
                var linked = unknown
                linked.path = .link
                XCTAssertNotEqual(Recovery.decide(record: r, facts: linked), .markReturned)
            }
        }
        // The simulator refuses to close a record whose return did not swap, or whose path holds no folder.
        let r = rec(.symlink, .confirmed, .returned, .intent)
        XCTAssertFalse(RecoverySimulator.violations(of: .markReturned, record: r, facts: RecoveryFacts(drivePresent: true, path: .other, beforeMovePresent: false)).isEmpty)
        XCTAssertFalse(RecoverySimulator.violations(of: .markReturned, record: r, facts: RecoveryFacts(drivePresent: true, path: .link, beforeMovePresent: false, returnSwapped: true)).isEmpty)
        XCTAssertFalse(Recovery.message(for: .markReturned, record: r).isEmpty)
    }

    func testAnOldRecordWhoseReturnWasInterruptedBeforeTheSwapStaysOnTheGuard() {
        // The `returned` intent was written, the redirect is still in place: recovery leaves it to the guard.
        let r = rec(.symlink, .confirmed, .returned, .intent)
        let link = RecoveryFacts(drivePresent: true, path: .link, beforeMovePresent: false, publishedPresent: true, healthPasses: true)
        XCTAssertEqual(Recovery.decide(record: r, facts: link), .noop)
        var parked = link
        parked.path = .placeholder
        XCTAssertEqual(Recovery.decide(record: r, facts: parked), .noop)
    }
}
