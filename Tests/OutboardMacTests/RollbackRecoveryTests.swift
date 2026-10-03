import Darwin
import Foundation
import XCTest
import OutboardCore
@testable import OutboardMac

/// Rolling back, forgetting and crash recovery over a fake home. The drive is a plain folder inside the sandbox, so none of this needs
/// a mounted volume; what it proves is the order of the steps, the journal lines and that nothing is ever deleted or merged.
final class RollbackRecoveryTests: MacTestCase {
    private func requireNotRunning(_ sb: Sandbox) throws {
        let recipe = try XCTUnwrap(Catalogue.recipe("npm-cache"))
        if RunningCheck.state(recipe: recipe, snapshot: RunningApps.snapshot(for: recipe, home: sb.home)) != .notRunning {
            throw XCTSkip("npm or node is running here (or the process list cannot be read)")
        }
    }

    // MARK: rollback

    func testRollbackParksTheLinkAndPutsTheOriginalBack() throws {
        let sb = try makeSandbox()
        try requireNotRunning(sb)
        let layout = try Fixtures.swapped(sb)
        let record = try XCTUnwrap(Fixtures.currentRecord(sb))
        XCTAssertTrue(record.canRollBack)

        let outcome = Rollback.run(record, home: sb.home)
        XCTAssertTrue(outcome.ok, outcome.message)
        XCTAssertEqual(outcome.state, .rolledBack)
        XCTAssertTrue(Fs.isPlainDirectory(layout.macPath), "the original is a real folder again")
        XCTAssertEqual(sb.names(in: ".npm"), ["orig.bin"])
        XCTAssertFalse(sb.exists(layout.beforePath))
        // The link is evidence in Parked/<id>/link, not deleted; the drive's copy is untouched.
        let parked = Park.parkedFolder(moveID: layout.plan.id, home: sb.home) + "/link"
        XCTAssertEqual(Fs.linkTarget(parked), layout.driveFolder)
        XCTAssertTrue(sb.exists(layout.driveFolder + "/copy.bin"))
        XCTAssertEqual(Fixtures.currentRecord(sb)?.state, .rolledBack)
        XCTAssertTrue(steps(lines(sb)).contains("rollback.result"))
    }

    func testRollbackSetsAFolderTheAppMadeAsideAndNeverMergesIt() throws {
        let sb = try makeSandbox()
        try requireNotRunning(sb)
        let layout = try Fixtures.swapped(sb, redirected: false, journalUpTo: .setAside)
        // The app started in the gap and made its own folder where the original was.
        sb.put(".npm/fresh.bin", bytes: 3)
        let record = try XCTUnwrap(Fixtures.currentRecord(sb))
        XCTAssertEqual(record.state, .verifying)
        let outcome = Rollback.automatic(layout.plan, reason: .foreignFolderAppeared, home: sb.home)
        XCTAssertTrue(outcome.ok, outcome.message)
        XCTAssertEqual(outcome.state, .aborted)
        XCTAssertEqual(outcome.abort, .foreignFolderAppeared)
        XCTAssertEqual(sb.names(in: ".npm"), ["orig.bin"], "the original is back")
        XCTAssertEqual(sb.names(in: ".npm.created-while-moving"), ["fresh.bin"], "what the app made is set aside whole, not merged")
        XCTAssertFalse(sb.exists(layout.beforePath))
        XCTAssertEqual(Fixtures.currentRecord(sb)?.state, .aborted)
        XCTAssertEqual(Fixtures.currentRecord(sb)?.abort, .foreignFolderAppeared)
        XCTAssertTrue(RelocationFold.leftovers(from: Journal.loadAll(home: sb.home), records: RelocationFold.records(from: Journal.loadAll(home: sb.home)))
            .contains { $0.kind == .setAsideForeign }, "the set-aside folder is listed")
    }

    func testRollbackIsRefusedWhenThereIsNoSafetyCopy() throws {
        let sb = try makeSandbox()
        try Fixtures.swapped(sb)
        var record = try XCTUnwrap(Fixtures.currentRecord(sb))
        record.safetyCopy = .gone
        let outcome = Rollback.run(record, home: sb.home)
        XCTAssertFalse(outcome.ok)
        XCTAssertTrue(sb.exists(sb.home + "/.npm.before-move"))
    }

    func testForgetTakesTheLinkAwayAndClosesTheRecordWithoutTouchingTheDrive() throws {
        let sb = try makeSandbox()
        try requireNotRunning(sb)
        let layout = try Fixtures.swapped(sb)
        // The user confirmed and trashed the original earlier: only the link remains on the Mac.
        try FileManager.default.moveItem(atPath: layout.beforePath, toPath: sb.home + "/trash-stand-in")
        Journal.result(.confirm, subject: layout.subject, home: sb.home, status: .ok, state: .confirmed)
        let record = try XCTUnwrap(Fixtures.currentRecord(sb))
        XCTAssertEqual(record.state, .confirmed)
        let outcome = Rollback.forget(record, home: sb.home)
        XCTAssertTrue(outcome.ok, outcome.message)
        XCTAssertEqual(outcome.state, .forgotten)
        XCTAssertFalse(sb.exists(layout.macPath), "the app can make its own default now")
        XCTAssertEqual(Fs.linkTarget(Park.parkedFolder(moveID: layout.plan.id, home: sb.home) + "/link"), layout.driveFolder)
        XCTAssertTrue(sb.exists(layout.driveFolder + "/copy.bin"))
        XCTAssertEqual(Fixtures.currentRecord(sb)?.state, .forgotten)
    }

    // MARK: recovery

    func testAMoveInterruptedBeforeTheRenameAbortsAndLeavesTheOriginal() throws {
        let sb = try makeSandbox()
        let layout = try Fixtures.swapped(sb, journalUpTo: .verify)   // copy done, verify done, nothing renamed
        let record = try XCTUnwrap(Fixtures.currentRecord(sb))
        let facts = Recover.gatherFacts(record, home: sb.home)
        XCTAssertEqual(facts.path, .real)
        XCTAssertFalse(facts.beforeMovePresent)
        let action = Recovery.decide(record: record, facts: facts)
        guard case .abort(.interrupted, _) = action else { return XCTFail("expected abort, got \(action)") }
        let outcomes = Recover.run(home: sb.home)
        XCTAssertEqual(outcomes.first?.state, .aborted)
        XCTAssertEqual(sb.names(in: ".npm"), ["orig.bin"], "the original was never touched")
        XCTAssertEqual(Fixtures.currentRecord(sb)?.state, .aborted)
        // Running it again changes nothing (idempotent).
        XCTAssertTrue(Recover.run(home: sb.home).isEmpty)
        _ = layout
    }

    func testAMoveInterruptedAfterTheRenameRestoresTheOriginal() throws {
        let sb = try makeSandbox()
        try requireNotRunning(sb)
        let layout = try Fixtures.swapped(sb, redirected: false, journalUpTo: .setAside)   // renamed, no link yet, no result line
        let record = try XCTUnwrap(Fixtures.currentRecord(sb))
        let facts = Recover.gatherFacts(record, home: sb.home)
        XCTAssertEqual(facts.path, .missing)
        XCTAssertTrue(facts.beforeMovePresent)
        XCTAssertEqual(Recovery.decide(record: record, facts: facts), .rollbackOriginal)
        let outcomes = Recover.run(home: sb.home)
        XCTAssertEqual(outcomes.first?.ok, true, outcomes.first?.message ?? "no outcome")
        XCTAssertEqual(sb.names(in: ".npm"), ["orig.bin"])
        XCTAssertFalse(sb.exists(layout.beforePath))
        XCTAssertEqual(Fixtures.currentRecord(sb)?.state, .aborted)
        XCTAssertTrue(Recover.run(home: sb.home).isEmpty, "recovery is idempotent")
    }

    func testAFolderTheAppMadeInTheGapIsSetAsideByRecovery() throws {
        let sb = try makeSandbox()
        try requireNotRunning(sb)
        let layout = try Fixtures.swapped(sb, redirected: false, journalUpTo: .setAside)
        sb.put(".npm/fresh.bin", bytes: 3)
        let record = try XCTUnwrap(Fixtures.currentRecord(sb))
        let facts = Recover.gatherFacts(record, home: sb.home)
        XCTAssertEqual(facts.path, .other)
        XCTAssertEqual(Recovery.decide(record: record, facts: facts), .setAsideForeignThenRollback)
        let outcomes = Recover.run(home: sb.home)
        XCTAssertEqual(outcomes.first?.ok, true, outcomes.first?.message ?? "no outcome")
        XCTAssertEqual(sb.names(in: ".npm"), ["orig.bin"])
        XCTAssertEqual(sb.names(in: ".npm.created-while-moving"), ["fresh.bin"])
        _ = layout
    }

    func testTwoOriginalsStopRecoveryAndTouchNothing() throws {
        let sb = try makeSandbox()
        try Fixtures.swapped(sb, redirected: false, journalUpTo: .setAside)
        sb.put(".npm/orig.bin", bytes: 10)   // a folder with the same stamp is impossible; this is a different one, so "other"
        let record = try XCTUnwrap(Fixtures.currentRecord(sb))
        var facts = Recover.gatherFacts(record, home: sb.home)
        facts.path = .real   // what the table calls two originals: both the path and the safety copy are the recorded folders
        XCTAssertEqual(Recovery.decide(record: record, facts: facts), .needsAttention(.twoOriginals))
        let before = (sb.names(in: ".npm"), sb.names(in: ".npm.before-move"))
        guard let outcome = Recover.apply(.needsAttention(.twoOriginals), record: record, facts: facts, home: sb.home) else { return XCTFail("expected an outcome") }
        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(sb.names(in: ".npm"), before.0)
        XCTAssertEqual(sb.names(in: ".npm.before-move"), before.1)
    }

    func testAnActiveRelocationWithItsLinkInPlaceNeedsNothing() throws {
        let sb = try makeSandbox()
        try Fixtures.swapped(sb)
        let record = try XCTUnwrap(Fixtures.currentRecord(sb))
        let facts = Recover.gatherFacts(record, home: sb.home)
        XCTAssertEqual(facts.path, .link)
        XCTAssertTrue(facts.beforeMovePresent)
        XCTAssertEqual(Recovery.decide(record: record, facts: facts), .noop)
        XCTAssertTrue(Recover.run(home: sb.home).isEmpty)
    }

    func testRecoveryDoesNothingWhileAMutationIsInFlight() throws {
        let sb = try makeSandbox()
        try Fixtures.swapped(sb, journalUpTo: .verify)
        XCTAssertTrue(MutationGate.tryEnter())
        defer { MutationGate.leave() }
        XCTAssertTrue(Recover.run(home: sb.home).isEmpty, "a running move would look interrupted")
        XCTAssertEqual(Fixtures.currentRecord(sb)?.state, .verifying)
    }
}
