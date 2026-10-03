import Darwin
import Foundation
import XCTest
import OutboardCore
@testable import OutboardMac

/// The single-site verbs against a fake home. The drive is never mounted here, so these cover what does not need one: the rules,
/// the fresh stamp, the journal before the act, and the refusals. The happy paths on a real volume are in DiskImageTests.
final class RenamerTests: MacTestCase {
    private func setup(_ sb: Sandbox) -> (MovePlan, RuleContext, JournalSubject) {
        sb.put(".npm/a.bin", bytes: 10)
        let plan = Fixtures.plan(sb)
        return (plan, RuleContext(plan: plan, home: sb.home), JournalSubject(plan))
    }

    func testSetAsideRenamesTheOriginalBesideItAndJournalsBothLines() throws {
        let sb = try makeSandbox()
        let (plan, ctx, subject) = setup(sb)
        let r = Renamer.perform(.setAside, from: plan.macPath, to: plan.beforeMovePath, ctx: ctx, subject: subject, home: sb.home, expected: plan.sourceStamp)
        guard case .renamed(let after) = r else { return XCTFail("expected renamed, got \(r)") }
        XCTAssertFalse(sb.exists(plan.macPath))
        XCTAssertEqual(sb.names(in: ".npm.before-move"), ["a.bin"])
        XCTAssertEqual(after?.inode, plan.sourceStamp.inode, "a rename keeps the object")
        let all = lines(sb)
        XCTAssertEqual(steps(all), ["setAside.intent", "setAside.result"])
        XCTAssertEqual(all[0].src, "~/.npm")
        XCTAssertEqual(all[0].to, "~/.npm.before-move")
        XCTAssertEqual(all[1].status, .ok)
        let facts = JournalFacts(moveID: plan.id, all: Journal.loadAll(home: sb.home), home: sb.home)
        XCTAssertEqual(facts.setAsideStamp?.inode, plan.sourceStamp.inode)
    }

    func testAPairTheRulesDoNotApproveIsRefusedAndNothingMoves() throws {
        let sb = try makeSandbox()
        let (plan, ctx, subject) = setup(sb)
        let r = Renamer.perform(.setAside, from: plan.macPath, to: plan.macPath + ".elsewhere", ctx: ctx, subject: subject, home: sb.home, expected: plan.sourceStamp)
        guard case .refused = r else { return XCTFail("expected refused, got \(r)") }
        XCTAssertTrue(sb.exists(plan.macPath))
        XCTAssertFalse(sb.exists(plan.macPath + ".elsewhere"))
        XCTAssertTrue(lines(sb).isEmpty, "a refusal writes nothing")
    }

    func testAFolderThatWasReplacedIsNotRenamed() throws {
        let sb = try makeSandbox()
        let (plan, ctx, subject) = setup(sb)
        try FileManager.default.moveItem(atPath: plan.macPath, toPath: sb.home + "/.npm-moved-by-someone")
        sb.put(".npm/b.bin", bytes: 3)   // a different folder under the old name
        let r = Renamer.perform(.setAside, from: plan.macPath, to: plan.beforeMovePath, ctx: ctx, subject: subject, home: sb.home, expected: plan.sourceStamp)
        guard case .changed = r else { return XCTFail("expected changed, got \(r)") }
        XCTAssertEqual(sb.names(in: ".npm"), ["b.bin"])
        XCTAssertFalse(sb.exists(plan.beforeMovePath))
    }

    func testAnExistingNewNameIsNeverReplaced() throws {
        let sb = try makeSandbox()
        let (plan, ctx, subject) = setup(sb)
        sb.put(".npm.before-move/older.bin", bytes: 1)
        let r = Renamer.perform(.setAside, from: plan.macPath, to: plan.beforeMovePath, ctx: ctx, subject: subject, home: sb.home, expected: plan.sourceStamp)
        guard case .refused = r else { return XCTFail("expected refused, got \(r)") }
        XCTAssertEqual(sb.names(in: ".npm.before-move"), ["older.bin"])
        XCTAssertEqual(sb.names(in: ".npm"), ["a.bin"])
    }

    func testNothingMovesWhenTheJournalWillNotTakeTheIntent() throws {
        let sb = try makeSandbox()
        let (plan, ctx, subject) = setup(sb)
        XCTAssertTrue(Journal.prepare(home: sb.home))
        XCTAssertEqual(chmod(Journal.directory(home: sb.home), 0o500), 0)
        defer { chmod(Journal.directory(home: sb.home), 0o700) }
        let r = Renamer.perform(.setAside, from: plan.macPath, to: plan.beforeMovePath, ctx: ctx, subject: subject, home: sb.home, expected: plan.sourceStamp)
        guard case .notAttempted = r else { return XCTFail("expected notAttempted, got \(r)") }
        XCTAssertTrue(sb.exists(plan.macPath))
        XCTAssertFalse(sb.exists(plan.beforeMovePath))
    }

    func testUndoSetAsidePutsTheOriginalBack() throws {
        let sb = try makeSandbox()
        let (plan, ctx, subject) = setup(sb)
        XCTAssertTrue(Renamer.perform(.setAside, from: plan.macPath, to: plan.beforeMovePath, ctx: ctx, subject: subject, home: sb.home, expected: plan.sourceStamp).isRenamed)
        let facts = JournalFacts(moveID: plan.id, all: Journal.loadAll(home: sb.home), home: sb.home)
        let back = Renamer.perform(.undoSetAside, from: plan.beforeMovePath, to: plan.macPath, ctx: ctx, subject: subject, home: sb.home, expected: facts.setAsideStamp)
        XCTAssertTrue(back.isRenamed, back.text)
        XCTAssertEqual(sb.names(in: ".npm"), ["a.bin"])
        XCTAssertFalse(sb.exists(plan.beforeMovePath))
    }

    func testAForeignFolderIsSetAsideNotMerged() throws {
        let sb = try makeSandbox()
        let (plan, ctx, subject) = setup(sb)
        let target = plan.macPath + Names.createdWhileMovingSuffix
        let r = Renamer.perform(.setAsideForeign, from: plan.macPath, to: target, ctx: ctx, subject: subject, home: sb.home, expected: nil)
        XCTAssertTrue(r.isRenamed, r.text)
        XCTAssertEqual(sb.names(in: ".npm.created-while-moving"), ["a.bin"])
        // A second one cannot take the same name; the first is never overwritten.
        sb.put(".npm/b.bin", bytes: 2)
        let again = Renamer.perform(.setAsideForeign, from: plan.macPath, to: target, ctx: ctx, subject: subject, home: sb.home, expected: nil)
        guard case .refused = again else { return XCTFail("the name is taken, expected refused, got \(again)") }
        XCTAssertEqual(sb.names(in: ".npm.created-while-moving"), ["a.bin"])
    }
}

final class CopierTests: MacTestCase {
    func testACopyThatCannotStartLeavesTheSourceAlone() throws {
        let sb = try makeSandbox()
        sb.put(".npm/a.bin", bytes: 10)
        let plan = Fixtures.plan(sb)
        let result = Copier.copy(plan, home: sb.home, control: CopyControl())
        switch result {
        case .failed, .refused, .changed, .notAttempted: break   // the staging folder's parent is on a drive that is not there
        default: XCTFail("expected the copy not to happen, got \(result)")
        }
        XCTAssertEqual(sb.names(in: ".npm"), ["a.bin"])
        XCTAssertFalse(sb.exists(plan.stagingPath))
    }

    func testASourceThatChangedSincePlanningIsNotCopied() throws {
        let sb = try makeSandbox()
        sb.put(".npm/a.bin", bytes: 10)
        let plan = Fixtures.plan(sb)
        try FileManager.default.moveItem(atPath: plan.macPath, toPath: sb.home + "/.npm-gone")
        sb.put(".npm/other.bin", bytes: 1)
        guard case .changed = Copier.copy(plan, home: sb.home, control: CopyControl()) else { return XCTFail("expected changed") }
        XCTAssertTrue(lines(sb).isEmpty, "nothing is journaled for a copy that never started")
    }

    func testTheReturnCopyGoesBesideTheOriginalPath() throws {
        let sb = try makeSandbox()
        sb.dir(".npm")
        var plan = Fixtures.plan(sb)
        plan.direction = .returnToMac
        XCTAssertEqual(Copier.destinationPath(plan), plan.macPath + ".returning-" + plan.id)
        plan.direction = .toDrive
        XCTAssertEqual(Copier.destinationPath(plan), plan.stagingPath)
    }
}

final class TrasherTests: MacTestCase {
    private func item(_ sb: Sandbox, state: MoveState, path: String? = nil, expected: FileStamp? = nil, useRecorded: Bool = true) -> TrashItem {
        let record = Fixtures.record(sb, state: state)
        let target = path ?? sb.home + "/.npm.before-move"
        return TrashItem(path: target, expected: useRecorded ? (expected ?? Fs.stamp(of: target)) : nil,
                         ctx: RuleContext(record: record, home: sb.home, mountPoint: nil), subject: JournalSubject(record),
                         state: .originalTrashed, note: nil, journalPath: "~/.npm.before-move")
    }

    func testTheOriginalIsNotTrashedBeforeTheUserConfirms() throws {
        let sb = try makeSandbox()
        sb.put(".npm.before-move/a.bin")
        guard case .refused = Trasher.trash(item(sb, state: .swapped), home: sb.home) else { return XCTFail("expected refused") }
        XCTAssertTrue(sb.exists(sb.home + "/.npm.before-move"))
        XCTAssertTrue(lines(sb).isEmpty)
    }

    func testNothingElseIsEverTrashed() throws {
        let sb = try makeSandbox()
        sb.put(".npm/a.bin")
        guard case .refused = Trasher.trash(item(sb, state: .confirmed, path: sb.home + "/.npm"), home: sb.home) else { return XCTFail("the live folder is never trashed") }
        let other = sb.put("Documents/mine.txt")
        guard case .refused = Trasher.trash(item(sb, state: .confirmed, path: other), home: sb.home) else { return XCTFail("only the safety copy is trashed") }
        XCTAssertTrue(sb.exists(other))
    }

    func testAnItemWithoutARecordedStampIsRefused() throws {
        let sb = try makeSandbox()
        sb.put(".npm.before-move/a.bin")
        guard case .refused = Trasher.trash(item(sb, state: .confirmed, useRecorded: false), home: sb.home) else { return XCTFail("expected refused") }
        XCTAssertTrue(sb.exists(sb.home + "/.npm.before-move"))
    }

    func testAReplacedSafetyCopyIsNotTrashed() throws {
        let sb = try makeSandbox()
        sb.put(".npm.before-move/a.bin")
        let recorded = try XCTUnwrap(Fs.stamp(of: sb.home + "/.npm.before-move"))
        try FileManager.default.moveItem(atPath: sb.home + "/.npm.before-move", toPath: sb.home + "/.npm.bm-elsewhere")
        sb.put(".npm.before-move/new.bin")
        guard case .changed = Trasher.trash(item(sb, state: .confirmed, expected: recorded), home: sb.home) else { return XCTFail("expected changed") }
        XCTAssertEqual(sb.names(in: ".npm.before-move"), ["new.bin"])
    }

    func testTheConfirmedSafetyCopyGoesToTheTrashAndIsJournaled() throws {
        let sb = try makeSandbox()
        sb.put(".npm.before-move/a.bin")
        let result = Trasher.trash(item(sb, state: .confirmed), home: sb.home)
        if case .failed(_, let message) = result { throw XCTSkip("trashItem is not available in this session: \(message)") }
        #if os(macOS)
        guard case .trashed(let trashed) = result else { return XCTFail("expected trashed, got \(result)") }
        XCTAssertFalse(sb.exists(sb.home + "/.npm.before-move"))
        XCTAssertNotNil(trashed, "the Trash path is recorded")
        addTeardownBlock { if let trashed { try? FileManager.default.removeItem(atPath: trashed) } }
        let all = lines(sb)
        XCTAssertEqual(steps(all), ["trash.intent", "trash.result"])
        XCTAssertEqual(all[0].src, "~/.npm.before-move")
        XCTAssertEqual(all[1].state, .originalTrashed)
        #endif
    }
}
