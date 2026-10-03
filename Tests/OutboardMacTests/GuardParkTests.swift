import Darwin
import Foundation
import XCTest
import OutboardCore
@testable import OutboardMac

/// Parking and the guard's facts over a fake home. The recorded drive's UUID is not mounted anywhere, which is exactly "the drive is
/// gone", so the whole unplug side runs without a volume; the way back (unpark) needs a real one and is in DiskImageTests.
final class GuardParkTests: MacTestCase {
    override func setUp() {
        super.setUp()
        #if DEBUG
        Reconcile.resetForTests()
        #endif
    }

    private func journalFacts(_ sb: Sandbox, _ id: String = Fixtures.moveID) -> JournalFacts {
        JournalFacts(moveID: id, all: Journal.loadAll(home: sb.home), home: sb.home)
    }

    func testTheGuardSeesALinkWhoseDriveIsGone() throws {
        let sb = try makeSandbox()
        let layout = try Fixtures.swapped(sb)
        let record = try XCTUnwrap(Fixtures.currentRecord(sb))
        let mounted = try XCTUnwrap(VolumeIdentity.all())
        let facts = try XCTUnwrap(Reconcile.gather(record, entries: Journal.loadAll(home: sb.home), mounted: mounted, home: sb.home))
        XCTAssertEqual(facts.path, .link)
        XCTAssertEqual(facts.drive, .absent)
        XCTAssertFalse(facts.linkIsForeign)
        XCTAssertEqual(GuardPolicy.classify(facts), .park)
        XCTAssertEqual(GuardPolicy.action(for: .park, record: record), .park)
        _ = layout
    }

    func testALinkTheJournalDoesNotKnowIsForeign() throws {
        let sb = try makeSandbox()
        try Fixtures.swapped(sb)
        // Someone swaps our link for another one.
        try FileManager.default.removeItem(atPath: sb.home + "/.npm")
        try FileManager.default.createSymbolicLink(atPath: sb.home + "/.npm", withDestinationPath: sb.dir("elsewhere"))
        let record = try XCTUnwrap(Fixtures.currentRecord(sb))
        let facts = try XCTUnwrap(Reconcile.gather(record, entries: Journal.loadAll(home: sb.home), mounted: try XCTUnwrap(VolumeIdentity.all()), home: sb.home))
        XCTAssertTrue(facts.linkIsForeign)
        XCTAssertEqual(GuardPolicy.classify(facts), .foreign)
    }

    func testParkingMovesTheLinkAsideAndStandsANoteInItsPlace() throws {
        let sb = try makeSandbox()
        let layout = try Fixtures.swapped(sb)
        let record = try XCTUnwrap(Fixtures.currentRecord(sb))
        let result = Park.park(record, facts: journalFacts(sb), removal: .unclean, home: sb.home)
        guard case .parked = result else { return XCTFail("expected parked, got \(result)") }

        var st = stat()
        XCTAssertEqual(lstat(layout.macPath, &st), 0)
        XCTAssertEqual(st.st_mode & S_IFMT, S_IFREG, "a regular file stands where the folder was")
        XCTAssertEqual(st.st_mode & 0o777, 0o444)
        XCTAssertEqual(sb.read(layout.macPath), PlaceholderText.body(driveName: "Outboard"))
        let parked = Park.parkedFolder(moveID: layout.plan.id, home: sb.home) + "/link"
        XCTAssertEqual(Fs.linkTarget(parked), layout.driveFolder, "the link is kept, not deleted")
        XCTAssertEqual(sb.mode(Park.parkedFolder(moveID: layout.plan.id, home: sb.home)), 0o700)
        XCTAssertTrue(sb.exists(layout.driveFolder + "/copy.bin"), "the copy on the drive is never touched")

        let parkLines = lines(sb).filter { $0.step == "park" }
        XCTAssertFalse(parkLines.isEmpty)
        XCTAssertEqual(parkLines.last?.status, .ok)
        XCTAssertEqual(parkLines.last?.note, "park:unclean")
        let folded = try XCTUnwrap(Fixtures.currentRecord(sb))
        XCTAssertTrue(folded.isParked)
        XCTAssertTrue(folded.needsCheckBeforeReconnect, "a pulled drive must be checked before reconnecting")
    }

    func testAnEjectedDriveNeedsNoCheckAfterwards() throws {
        let sb = try makeSandbox()
        try Fixtures.swapped(sb)
        let record = try XCTUnwrap(Fixtures.currentRecord(sb))
        guard case .parked = Park.park(record, facts: journalFacts(sb), removal: .ejected, home: sb.home) else { return XCTFail("expected parked") }
        XCTAssertEqual(Fixtures.currentRecord(sb)?.needsCheckBeforeReconnect, false)
        XCTAssertEqual(journalFacts(sb).lastRemoval, .ejected)
    }

    func testAnOldRemovalKindDoesNotMakeAPulledDriveLookEjected() throws {
        let sb = try makeSandbox()
        try Fixtures.swapped(sb)
        let record = try XCTUnwrap(Fixtures.currentRecord(sb))
        guard case .parked = Park.park(record, facts: journalFacts(sb), removal: .ejected, home: sb.home) else { return XCTFail("expected parked") }
        XCTAssertEqual(journalFacts(sb).lastRemoval, .ejected)

        // The drive came back and the unpark succeeded: that park is answered, so its kind says nothing about the next removal.
        let subject = JournalSubject(record)
        XCTAssertTrue(Journal.result(.unpark, subject: subject, home: sb.home, status: .ok, note: "unpark"))
        XCTAssertNil(journalFacts(sb).lastRemoval)

        // A newer park speaks again.
        XCTAssertTrue(Journal.result(.park, subject: subject, home: sb.home, status: .ok, note: JournalNote.park(.unclean)))
        XCTAssertEqual(journalFacts(sb).lastRemoval, .unclean)
    }

    func testAnAbsentDriveWithNoLiveNoticeIsUnknownNotEjected() throws {
        let sb = try makeSandbox()
        try Fixtures.swapped(sb)
        let record = try XCTUnwrap(Fixtures.currentRecord(sb))
        // The journal says an earlier park was an eject, but the path holds the link: that line is history, not news.
        XCTAssertTrue(Journal.result(.park, subject: JournalSubject(record), home: sb.home, status: .ok, note: JournalNote.park(.ejected)))
        let again = try XCTUnwrap(Fixtures.currentRecord(sb))
        let facts = try XCTUnwrap(Reconcile.gather(again, entries: Journal.loadAll(home: sb.home), mounted: try XCTUnwrap(VolumeIdentity.all()), home: sb.home))
        XCTAssertEqual(facts.path, .link)
        XCTAssertEqual(facts.drive, .absent)
        XCTAssertEqual(facts.removal, .unknown)
    }

    func testTheGuardSeesAParkedRelocationAsParked() throws {
        let sb = try makeSandbox()
        try Fixtures.swapped(sb)
        let record = try XCTUnwrap(Fixtures.currentRecord(sb))
        guard case .parked = Park.park(record, facts: journalFacts(sb), removal: .unknown, home: sb.home) else { return XCTFail("expected parked") }
        let again = try XCTUnwrap(Fixtures.currentRecord(sb))
        let facts = try XCTUnwrap(Reconcile.gather(again, entries: Journal.loadAll(home: sb.home), mounted: try XCTUnwrap(VolumeIdentity.all()), home: sb.home))
        XCTAssertEqual(facts.path, .placeholder)
        XCTAssertTrue(facts.placeholderUnchanged)
        XCTAssertEqual(GuardPolicy.classify(facts), .parked)
        XCTAssertEqual(GuardPolicy.health(state: .parked, held: nil, record: again), .driveAway)
    }

    func testParkingTwiceChangesNothingTheSecondTime() throws {
        let sb = try makeSandbox()
        let layout = try Fixtures.swapped(sb)
        let record = try XCTUnwrap(Fixtures.currentRecord(sb))
        guard case .parked = Park.park(record, facts: journalFacts(sb), removal: .ejected, home: sb.home) else { return XCTFail("expected parked") }
        let before = lines(sb).count
        let second = Park.park(record, facts: journalFacts(sb), removal: .ejected, home: sb.home)
        switch second {
        case .refused, .notNeeded: break
        default: XCTFail("a second park must do nothing, got \(second)")
        }
        XCTAssertEqual(lines(sb).count, before, "no new line for a park that did not happen")
        XCTAssertEqual(sb.names(in: "Library/Application Support/Outboard/Parked/" + layout.plan.id), ["link"])
    }

    /// A retarget (the drive came back under another mount point) moves the old link into Parked/<id>/link. The next eject has to
    /// park the new link beside it as link-2: the old one is evidence, and the rules must allow the numbered name.
    func testParkingAfterARetargetKeepsTheOldLinkAndParksTheNewOneBesideIt() throws {
        let sb = try makeSandbox()
        let layout = try Fixtures.swapped(sb)
        XCTAssertTrue(Park.ensureFolder(moveID: layout.plan.id, home: sb.home))
        let folder = Park.parkedFolder(moveID: layout.plan.id, home: sb.home)
        try FileManager.default.createSymbolicLink(atPath: folder + "/link", withDestinationPath: sb.dir("old-mount"))
        let record = try XCTUnwrap(Fixtures.currentRecord(sb))
        let result = Park.park(record, facts: journalFacts(sb), removal: .ejected, home: sb.home)
        guard case .parked = result else { return XCTFail("expected parked, got \(result)") }
        XCTAssertEqual(sb.names(in: "Library/Application Support/Outboard/Parked/" + layout.plan.id), ["link", "link-2"])
        XCTAssertEqual(Fs.linkTarget(folder + "/link"), sb.dir("old-mount"), "the older link is untouched")
        XCTAssertEqual(Fs.linkTarget(folder + "/link-2"), layout.driveFolder)
        XCTAssertEqual(Fs.kind(Fs.info(layout.macPath).st), .file, "the note stands where the folder was")
        XCTAssertEqual(Park.latestName("link", moveID: layout.plan.id, home: sb.home), folder + "/link-2")
        XCTAssertEqual(Park.nextName("link", moveID: layout.plan.id, home: sb.home), folder + "/link-3")
    }

    func testAFolderTheAppMadeWhileTheDriveWasAwayIsNeverParkedOver() throws {
        let sb = try makeSandbox()
        let layout = try Fixtures.swapped(sb)
        // The link vanished and an app made a real folder in its place.
        try FileManager.default.removeItem(atPath: layout.macPath)
        sb.put(".npm/made-by-app.bin", bytes: 5)
        let record = try XCTUnwrap(Fixtures.currentRecord(sb))
        let result = Park.park(record, facts: journalFacts(sb), removal: .unknown, home: sb.home)
        guard case .refused = result else { return XCTFail("expected refused, got \(result)") }
        XCTAssertEqual(sb.names(in: ".npm"), ["made-by-app.bin"])
        let facts = try XCTUnwrap(Reconcile.gather(record, entries: Journal.loadAll(home: sb.home), mounted: try XCTUnwrap(VolumeIdentity.all()), home: sb.home))
        XCTAssertEqual(GuardPolicy.classify(facts), .divergedWhileAbsent)
        XCTAssertEqual(GuardPolicy.action(for: .divergedWhileAbsent, record: record), .reportOnly)
    }

    func testARecipeThatLeavesAloneIsOnlyReportedOn() throws {
        let sb = try makeSandbox()
        try Fixtures.swapped(sb)
        var record = try XCTUnwrap(Fixtures.currentRecord(sb))
        record.onDriveMissing = .leaveAlone
        guard case .leftAlone = Park.park(record, facts: journalFacts(sb), removal: .unclean, home: sb.home) else { return XCTFail("expected leftAlone") }
        XCTAssertEqual(Fs.kind(Fs.info(sb.home + "/.npm").st), .symlink, "the link stays")
    }

    func testAnUnwritableJournalMeansNothingIsParked() throws {
        let sb = try makeSandbox()
        let layout = try Fixtures.swapped(sb)
        let record = try XCTUnwrap(Fixtures.currentRecord(sb))
        let facts = journalFacts(sb)
        XCTAssertEqual(chmod(Journal.directory(home: sb.home), 0o500), 0)
        defer { chmod(Journal.directory(home: sb.home), 0o700) }
        guard case .refused = Park.park(record, facts: facts, removal: .unknown, home: sb.home) else { return XCTFail("expected refused") }
        XCTAssertEqual(Fs.kind(Fs.info(layout.macPath).st), .symlink)
    }

    // MARK: the pass

    func testAPassInsideTheLaunchGraceDoesNotParkADriveItHasNotSeen() async throws {
        let sb = try makeSandbox()
        let layout = try Fixtures.swapped(sb)
        let snapshot = await Reconcile.run(.launch, home: sb.home)
        XCTAssertEqual(snapshot.relocations.first?.state, .park)
        XCTAssertEqual(snapshot.relocations.first?.health, .driveAway)
        XCTAssertEqual(Fs.kind(Fs.info(layout.macPath).st), .symlink, "a drive that may still be mounting is not given up on")
    }

    func testAPassAfterTheGraceParksTheLinkAndPublishesDriveAway() async throws {
        let sb = try makeSandbox()
        let layout = try Fixtures.swapped(sb)
        Reconcile.setLaunchedAt(Date().addingTimeInterval(-60))
        let snapshot = await Reconcile.run(.timer, home: sb.home)   // waits out the 5 second debounce
        XCTAssertEqual(Fs.kind(Fs.info(layout.macPath).st), .file)
        XCTAssertEqual(snapshot.relocations.first?.state, .parked)
        XCTAssertEqual(snapshot.relocations.first?.health, .driveAway)
        XCTAssertTrue(snapshot.banners.contains { $0.moveIDs.contains(layout.plan.id) })
        // The same pass again produces an equal snapshot: nothing changed, so nothing is published.
        let again = await Reconcile.run(.timer, home: sb.home)
        XCTAssertEqual(again, snapshot)
    }
}
