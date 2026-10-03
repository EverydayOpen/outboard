import Darwin
import Foundation
import XCTest
import OutboardCore
@testable import OutboardMac

final class GuardTests: MacTestCase {
    func testUnchangedItemPassesAndReturnsItsStamp() throws {
        let sb = try makeSandbox()
        let dir = sb.dir(".npm")
        let stamp = try XCTUnwrap(Fs.stamp(of: dir))
        sb.put(".npm/new.bin")   // a directory's own time moves when an app adds a file; that is not a change
        guard case .unchanged(let found) = Guard.verifyStamp(path: dir, expected: stamp) else { return XCTFail("expected unchanged") }
        XCTAssertEqual(found.inode, stamp.inode)
    }

    func testAMissingItemIsMissing() throws {
        let sb = try makeSandbox()
        XCTAssertEqual(Guard.verifyStamp(path: sb.home + "/nope", expected: nil), .missing)
    }

    func testAnotherObjectAtTheSamePathIsChanged() throws {
        let sb = try makeSandbox()
        let dir = sb.dir(".npm")
        let stamp = try XCTUnwrap(Fs.stamp(of: dir))
        try FileManager.default.moveItem(atPath: dir, toPath: sb.home + "/.npm-old")
        sb.dir(".npm")
        guard case .changed = Guard.verifyStamp(path: dir, expected: stamp) else { return XCTFail("a new folder with the old name is a different object") }
    }

    func testAFileWhoseSizeChangedIsChanged() throws {
        let sb = try makeSandbox()
        let file = sb.put("f.bin", bytes: 10)
        let stamp = try XCTUnwrap(Fs.stamp(of: file))
        sb.put("f.bin", bytes: 11)
        guard case .changed = Guard.verifyStamp(path: file, expected: stamp) else { return XCTFail("expected changed") }
    }

    func testALinkIsStampedAsTheLinkNeverItsTarget() throws {
        let sb = try makeSandbox()
        let target = sb.dir("target")
        sb.link("l", to: target)
        let stamp = try XCTUnwrap(Fs.stamp(of: sb.home + "/l"))
        XCTAssertEqual(stamp.type, .symlink)
        guard case .unchanged = Guard.verifyStamp(path: sb.home + "/l", expected: stamp) else { return XCTFail("expected unchanged") }
    }

    func testRecheckSeesAFolderThatIsGoneOrNotOnADrive() throws {
        let sb = try makeSandbox()
        sb.dir(".npm")
        let plan = Fixtures.plan(sb)
        // The drive is not mounted anywhere, so the swap's last look refuses.
        guard case .changed = Guard.recheck(plan, home: sb.home) else { return XCTFail("a plan whose drive is absent must not pass the recheck") }
        try FileManager.default.removeItem(atPath: sb.home + "/.npm")
        guard case .changed(let why) = Guard.recheck(plan, home: sb.home) else { return XCTFail("expected changed") }
        XCTAssertFalse(why.isEmpty)
    }

    func testTheModeBitsOfThePathAreNotPartOfTheStamp() throws {
        let sb = try makeSandbox()
        let dir = sb.dir(".npm")
        let stamp = try XCTUnwrap(Fs.stamp(of: dir))
        XCTAssertEqual(chmod(dir, 0o750), 0)
        guard case .unchanged = Guard.verifyStamp(path: dir, expected: stamp) else { return XCTFail("expected unchanged") }
    }

    // MARK: the source read again at W1

    private func seenSource(_ plan: MovePlan, secondsAgo: Double) throws -> SourceSeen {
        let walk = try XCTUnwrap(SizeScanner.walk(plan.sourcePath, xattrs: false))
        return SourceSeen(manifest: walk.entries, at: Date().addingTimeInterval(-secondsAgo))
    }

    func testRecheckReadsTheSourceAgainWhenTheComparisonIsOldAndRefusesAFileAddedSince() throws {
        let sb = try makeSandbox()
        sb.put(".npm/orig.bin", bytes: 10)
        let plan = Fixtures.plan(sb)
        let seen = try seenSource(plan, secondsAgo: Guard.rewalkAfterSeconds + 5)
        // Nothing changed: the recheck goes on to the drive checks, which refuse here for another reason (no drive).
        guard case .changed(let before) = Guard.recheck(plan, home: sb.home, seen: seen) else { return XCTFail("no drive is mounted") }
        XCTAssertFalse(before.contains("after it was compared"), before)
        // An app writes a file after the comparison read the tree: it would exist only in .before-move.
        sb.put(".npm/written-later.bin", bytes: 3)
        guard case .changed(let why) = Guard.recheck(plan, home: sb.home, seen: seen) else { return XCTFail("expected changed") }
        XCTAssertTrue(why.contains("after it was compared"), why)
        // A changed size is caught the same way.
        let plan2 = Fixtures.plan(sb)
        let seen2 = try seenSource(plan2, secondsAgo: Guard.rewalkAfterSeconds + 5)
        sb.put(".npm/orig.bin", bytes: 11)
        guard case .changed(let why2) = Guard.recheck(plan2, home: sb.home, seen: seen2) else { return XCTFail("expected changed") }
        XCTAssertTrue(why2.contains("after it was compared"), why2)
    }

    func testRecheckDoesNotWalkWhenTheComparisonIsRecent() throws {
        let sb = try makeSandbox()
        sb.put(".npm/orig.bin", bytes: 10)
        let plan = Fixtures.plan(sb)
        let seen = try seenSource(plan, secondsAgo: 0)
        sb.put(".npm/written-later.bin", bytes: 3)
        guard case .changed(let why) = Guard.recheck(plan, home: sb.home, seen: seen) else { return XCTFail("no drive is mounted") }
        XCTAssertFalse(why.contains("after it was compared"), "a recent comparison is trusted; the walk is skipped: \(why)")
    }
}
