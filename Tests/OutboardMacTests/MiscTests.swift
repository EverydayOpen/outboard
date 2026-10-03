import Darwin
import Foundation
import XCTest
import OutboardCore
import ServiceManagement
@testable import OutboardMac

final class LoginItemTests: XCTestCase {
    func testEveryStatusIsReportedPlainly() {
        XCTAssertEqual(LoginItem.map(.notRegistered), .notRegistered)
        XCTAssertEqual(LoginItem.map(.enabled), .enabled)
        XCTAssertEqual(LoginItem.map(.requiresApproval), .requiresApproval)
        XCTAssertEqual(LoginItem.map(.notFound), .notFound)
    }

    func testTheCurrentStateCanBeRead() {
        // Whatever it is on this machine, reading it does not throw and does not change it.
        let state = LoginItem.state
        XCTAssertEqual(LoginItem.state, state)
    }
}

final class DriveFolderTests: MacTestCase {
    func testOnlyARealFolderCalledOutboardOnTheSameDeviceIsUsed() throws {
        let sb = try makeSandbox()
        let mount = sb.dir("drive")
        XCTAssertTrue(OutboardRoot.driveFolderIsSound(mountPoint: mount), "no Outboard folder yet: it is made as a real one")
        XCTAssertTrue(OutboardRoot.driveFolderIsSound(mountPoint: mount, path: mount + "/Outboard/npm-cache/.npm"))
        sb.dir("drive/Outboard/npm-cache")
        XCTAssertTrue(OutboardRoot.driveFolderIsSound(mountPoint: mount, path: mount + "/Outboard/npm-cache/.npm"))
        XCTAssertFalse(OutboardRoot.driveFolderIsSound(mountPoint: sb.home + "/no-such-drive"))
    }

    func testAnOutboardFolderThatIsALinkOrAFileIsNeverUsed() throws {
        let sb = try makeSandbox()
        let elsewhere = sb.dir("elsewhere")
        let linked = sb.dir("linked")
        sb.link("linked/Outboard", to: elsewhere)
        XCTAssertFalse(OutboardRoot.driveFolderIsSound(mountPoint: linked), "a link is not a folder on the drive")
        XCTAssertFalse(OutboardRoot.driveFolderIsSound(mountPoint: linked, path: linked + "/Outboard/npm-cache"))
        XCTAssertNil(OutboardRoot.readMarker(mountPoint: linked))
        let file = sb.dir("file")
        sb.put("file/Outboard", bytes: 3)
        XCTAssertFalse(OutboardRoot.driveFolderIsSound(mountPoint: file), "a file called Outboard is not a folder")
    }

    func testARecipeFolderThatLeavesTheDriveIsNeverUsed() throws {
        let sb = try makeSandbox()
        let elsewhere = sb.dir("elsewhere")
        let mount = sb.dir("drive")
        sb.dir("drive/Outboard")
        sb.link("drive/Outboard/npm-cache", to: elsewhere)
        XCTAssertFalse(OutboardRoot.driveFolderIsSound(mountPoint: mount, path: mount + "/Outboard/npm-cache/.npm"), "it resolves to a place outside the drive")
    }
}

final class MaterializationTests: XCTestCase {
    func testTurningMaterializationOffSucceedsAndStaysOff() {
        // The call is process-wide and there is no way back, so the test only checks that it works here.
        XCTAssertTrue(Materialization.disableForProcess())
        XCTAssertTrue(Materialization.disableForProcess())
    }
}

final class FsTests: MacTestCase {
    func testStampDoesNotFollowALink() throws {
        let sb = try makeSandbox()
        let target = sb.put("target.bin", bytes: 1234)
        sb.link("l", to: target)
        let stamp = try XCTUnwrap(Fs.stamp(of: sb.home + "/l"))
        XCTAssertEqual(stamp.type, .symlink)
        XCTAssertEqual(Fs.linkTarget(sb.home + "/l"), target)
        XCTAssertNil(Fs.linkTarget(target), "a file is not a link")
    }

    func testNamesListsSortedWithoutDots() throws {
        let sb = try makeSandbox()
        sb.put("d/b"); sb.put("d/a"); sb.put("d/.hidden")
        let listing = Fs.names(in: sb.home + "/d")
        XCTAssertEqual(listing.err, 0)
        XCTAssertEqual(listing.names, [".hidden", "a", "b"])
        XCTAssertEqual(Fs.names(in: sb.home + "/missing").err, ENOENT)
    }

    func testTheOpenProbeNeverListsAnything() throws {
        let sb = try makeSandbox()
        XCTAssertEqual(Fs.openDirectoryErrno(sb.home), 0)
        XCTAssertEqual(Fs.openDirectoryErrno(sb.home + "/missing"), ENOENT)
    }

    func testAPathIsNormalisedOnlyAtTheEnd() {
        XCTAssertEqual(Fs.normalized("/Volumes/X/"), "/Volumes/X")
        XCTAssertEqual(Fs.normalized("/"), "/")
        XCTAssertEqual(Fs.parent(of: "/a/b/c"), "/a/b")
        XCTAssertEqual(Fs.leaf(of: "/a/b/c"), "c")
    }

    func testPosixCodesComeThroughFoundationErrors() {
        let e = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        XCTAssertEqual(Fs.posix(e), ENOSPC)
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: 1, userInfo: [NSUnderlyingErrorKey: e])
        XCTAssertEqual(Fs.posix(wrapped), ENOSPC)
        XCTAssertEqual(Fs.posix(NSError(domain: NSCocoaErrorDomain, code: 640)), ENOSPC)
    }
}

final class VolumeIdentityTests: XCTestCase {
    func testAUUIDThatIsNotMountedIsAbsentAndNotMountedAnywhere() {
        let ref = VolumeRef(uuid: "00000000-0000-4000-8000-00000000DEAD", name: "Nobody", token: "t")
        XCTAssertTrue(VolumeIdentity.absent(ref))
        XCTAssertNil(VolumeIdentity.currentMountPoint(of: ref))
        XCTAssertFalse(VolumeIdentity.mounted(uuid: ref.uuid, at: "/Volumes/Nobody"))
        XCTAssertFalse(VolumeIdentity.matches(ref, mountPoint: "/Volumes/Nobody"))
    }

    func testUUIDsCompareWithoutCase() {
        XCTAssertTrue(VolumeIdentity.same("ab-CD", "AB-cd"))
        XCTAssertFalse(VolumeIdentity.same(nil, "AB"))
        XCTAssertFalse(VolumeIdentity.same("AB", nil))
    }

    func testTheStartupVolumeIsInTheMountTable() throws {
        let all = try XCTUnwrap(VolumeIdentity.all())
        XCTAssertTrue(all.contains { $0.mountPoint == "/" })
    }
}

#if DEBUG
final class FaultsTests: MacTestCase {
    override func tearDown() {
        Faults.disarm()
        super.tearDown()
    }

    func testTheHooksSeeEveryIntentAndEveryActInOrder() throws {
        let sb = try makeSandbox()
        var seen: [FaultPoint] = []
        Faults.onHit = { seen.append($0) }
        let subject = JournalSubject(moveID: Fixtures.moveID, recipe: "npm-cache@1")
        XCTAssertTrue(Journal.intent(.copy, subject: subject, home: sb.home))
        XCTAssertTrue(Journal.result(.copy, subject: subject, home: sb.home, status: .ok))
        XCTAssertEqual(seen, [.afterIntent(.copy), .afterAct(.copy)])
    }

    func testAFailedIntentDoesNotReachTheHook() throws {
        let sb = try makeSandbox()
        XCTAssertTrue(Journal.prepare(home: sb.home))
        XCTAssertEqual(chmod(Journal.directory(home: sb.home), 0o500), 0)
        defer { chmod(Journal.directory(home: sb.home), 0o700) }
        var seen: [FaultPoint] = []
        Faults.onHit = { seen.append($0) }
        XCTAssertFalse(Journal.intent(.copy, subject: JournalSubject(moveID: Fixtures.moveID, recipe: "x@1"), home: sb.home))
        XCTAssertTrue(seen.isEmpty, "no intent line was written, so there is no point to stop at")
    }
}
#endif
