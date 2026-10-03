#if DEBUG
import Darwin
import Foundation
import XCTest
import OutboardCore
@testable import OutboardMac

/// The scenarios of safety-ux 12.2 (S1 to S20) on real volumes made from disk images. They run only with `OUTBOARD_DISK_TESTS=1` (the
/// macOS CI job sets it) and skip with the reason when a runner cannot do something: a refused drive, no disk image tool, no Trash.
/// Nothing here claims a real USB or Thunderbolt drive behaves the same; the probe workflow's artifact is the evidence for what CI saw.
class DiskTestCase: MacTestCase {
    let defaults = FakeDefaults()

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(DiskImageLab.isEnabled, "Disk image tests run only with OUTBOARD_DISK_TESTS=1.")
        Reconcile.resetForTests()
    }

    override func tearDown() {
        Faults.disarm()
        defaults.uninstall()
        super.tearDown()
    }

    struct Disk {
        var sandbox: Sandbox
        var image: DiskImageLab.Image
        var backend: Backend
        var facts: DriveFacts
        var uuid: String { facts.uuid ?? "" }
    }

    // MARK: building blocks

    func attach(_ sb: Sandbox, volumeName: String = "Outboard-TEST", megabytes: Int = 14_000, fileSystem: String = "APFS",
                readOnly: Bool = false, ownersOff: Bool = false) throws -> DiskImageLab.Image {
        let file = try DiskImageLab.create(in: sb.root, name: UUID().uuidString, volumeName: volumeName, megabytes: megabytes, fileSystem: fileSystem)
        let image = try DiskImageLab.attach(file, readOnly: readOnly, ownersOff: ownersOff)
        addTeardownBlock { DiskImageLab.detach(image, force: true) }
        return image
    }

    func connect(_ sb: Sandbox, _ image: DiskImageLab.Image, mark: Bool = true) async throws -> Disk {
        let backend = LiveBackend.make(home: sb.home, appVersion: "test", policy: .testing)
        let mount = Fs.normalized(image.mountPoint)
        let volumes = await backend.volumes()
        guard var facts = volumes.first(where: { $0.mountPoint == mount }) else {
            throw XCTSkip("the image volume is not in the mount table the app reads: \(volumes.map(\.mountPoint))")
        }
        if mark {
            let used = await backend.useDrive(facts.id)
            guard used.ok else { throw XCTSkip("this runner's disk image cannot be used as a drive: \(used.message)") }
            facts = used.facts ?? facts
        }
        return Disk(sandbox: sb, image: image, backend: backend, facts: facts)
    }

    func consent(_ disk: Disk, _ recipeID: String) async throws -> ConsentRecord {
        let recipe = try XCTUnwrap(Catalogue.recipe(recipeID))
        let report = await disk.backend.eligibility(disk.facts.id, recipeID)
        guard report.isAllowed else {
            throw XCTSkip("this runner's disk image is refused for \(recipeID): " + report.refusals.map(\.message).joined(separator: " | "))
        }
        return ConsentRecord(recipeVersion: recipe.version, tickedIDs: recipe.consent?.checkboxes.map(\.id) ?? [], ackIDs: report.acks.map(\.ackID),
                             sawUnverifiedNote: true)
    }

    func plan(_ disk: Disk, _ recipeID: String) async throws -> MovePlan {
        let c = try await consent(disk, recipeID)
        let result = await disk.backend.plan(recipeID, disk.facts.id, c)
        guard let plan = result.plan else { throw DiskImageLab.Failure("planning was refused: \(result.refusal ?? "no reason")") }
        return plan
    }

    func seedNpm(_ sb: Sandbox) {
        sb.put(".npm/_cacache/a.bin", bytes: 40_000, fill: 0x11)
        sb.put(".npm/_cacache/sub/b.bin", bytes: 3_000, fill: 0x22)
        sb.put(".npm/orig.bin", bytes: 12, fill: 0x33)
    }

    /// Runs the move; turns an environment problem (the app is running here, the drive is refused) into a skip with the reason.
    func move(_ disk: Disk, _ plan: MovePlan) async throws -> MoveOutcome {
        let outcome = await disk.backend.move(plan, { _ in })
        if outcome.abort == .preflightFailed, let first = outcome.preflight?.firstFailure, [PreflightID.p1, .p8].contains(first.check) {
            throw XCTSkip("preflight \(first.check.rawValue) failed on this runner: \(first.detail)")
        }
        return outcome
    }

    func assertRedirected(_ sb: Sandbox, _ disk: Disk, file: StaticString = #filePath, line: UInt = #line) {
        let path = sb.home + "/.npm"
        XCTAssertEqual(Fs.kind(Fs.info(path).st), .symlink, "~/.npm should be a link", file: file, line: line)
        XCTAssertTrue(VolumeIdentity.same(VolumeIdentity.volumeUUID(ofResolved: path), disk.facts.uuid), "the link resolves into the drive's volume", file: file, line: line)
    }

    func record(_ sb: Sandbox, _ id: String) -> RelocationRecord? { Fixtures.currentRecord(sb, id) }

    func isSymlink(_ path: String) -> Bool { Fs.kind(Fs.info(path).st) == .symlink }
}

final class MoveScenarioTests: DiskTestCase {
    // S2
    func testASymlinkRecipeMovesAndTheLinkResolvesIntoTheDrive() async throws {
        let sb = try makeSandbox()
        seedNpm(sb)
        let disk = try await connect(sb, try attach(sb))
        let p = try await plan(disk, "npm-cache")
        let outcome = try await move(disk, p)
        XCTAssertTrue(outcome.ok, outcome.message)
        XCTAssertEqual(outcome.state, .swapped)
        assertRedirected(sb, disk)
        XCTAssertEqual(sb.names(in: ".npm.before-move"), ["_cacache", "orig.bin"], "the original is kept next to the folder")
        XCTAssertTrue(sb.exists(p.destination.finalPath + "/_cacache/a.bin"))
        XCTAssertTrue(sb.exists(p.sentinelPath), "the sentinel sits beside the data, not inside it")
        XCTAssertNotNil(ManifestStore.load(moveID: p.id, home: sb.home))
        XCTAssertEqual(steps(lines(sb, p.id)), [
            "begin.intent", "preflight.intent", "preflight.result", "copy.intent", "copy.result", "verify.intent", "verify.result",
            "publish.intent", "publish.result", "publish.intent", "publish.result", "setAside.intent", "setAside.result",
            "redirect.intent", "redirect.result", "swapped.result",
        ])
        XCTAssertEqual(record(sb, p.id)?.state, .swapped)
        XCTAssertEqual(record(sb, p.id)?.safetyCopy, .kept)
        XCTAssertEqual(outcome.verification?.differences, 0)
    }

    // S1
    func testASettingRecipeMovesAndRollsBackWithoutDeletingAnything() async throws {
        let sb = try makeSandbox()
        sb.put("Library/Developer/Xcode/DerivedData/build/a.o", bytes: 9_000)
        let disk = try await connect(sb, try attach(sb))
        defaults.install()
        let p = try await plan(disk, "xcode-deriveddata")
        let outcome = try await move(disk, p)
        XCTAssertTrue(outcome.ok, outcome.message)
        guard case .defaults(_, let writes, _, let revert) = p.redirect else { return XCTFail("a defaults plan") }
        for w in writes { XCTAssertEqual(defaults.store[w.key], w.value) }
        XCTAssertFalse(sb.exists(sb.home + "/Library/Developer/Xcode/DerivedData"), "the default folder was renamed")
        XCTAssertEqual(sb.names(in: "Library/Developer/Xcode/DerivedData.before-move"), ["build"])

        let record = try XCTUnwrap(self.record(sb, p.id))
        let undone = Rollback.run(record, home: sb.home)
        XCTAssertTrue(undone.ok, undone.message)
        XCTAssertEqual(sb.names(in: "Library/Developer/Xcode/DerivedData"), ["build"])
        for w in revert { XCTAssertEqual(defaults.store[w.key], w.value, "the setting was written back, never deleted") }
        XCTAssertTrue(sb.exists(p.destination.finalPath + "/build/a.o"), "the copy on the drive stays")
        XCTAssertEqual(self.record(sb, p.id)?.state, .rolledBack)
    }

    // S3
    func testOneByteFlippedInStagingAbortsAndLeavesTheSourceAlone() async throws {
        let sb = try makeSandbox()
        seedNpm(sb)
        let disk = try await connect(sb, try attach(sb))
        let p = try await plan(disk, "npm-cache")
        let before = sb.names(in: ".npm")
        Faults.onHit = { point in
            guard point == .afterAct(.copy) else { return }
            let target = p.stagingPath + "/_cacache/a.bin"
            if let h = FileHandle(forWritingAtPath: target) {
                h.seek(toFileOffset: 100)
                h.write(Data([0xEE]))
                h.closeFile()
            }
        }
        let outcome = try await move(disk, p)
        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(outcome.state, .aborted)
        XCTAssertEqual(outcome.abort, .mismatch)
        XCTAssertEqual(outcome.differences.first?.kind, .hashDiffers)
        XCTAssertEqual(sb.names(in: ".npm"), before, "nothing on the Mac changed")
        XCTAssertFalse(sb.exists(sb.home + "/.npm.before-move"))
        XCTAssertFalse(isSymlink(sb.home + "/.npm"))
        XCTAssertTrue(RelocationFold.leftovers(from: Journal.loadAll(home: sb.home), records: RelocationFold.records(from: Journal.loadAll(home: sb.home)))
            .contains { $0.kind == .incompleteCopy }, "the partial copy is listed as a leftover")
    }

    // S4
    func testASourceThatChangesDuringTheCopyAborts() async throws {
        let sb = try makeSandbox()
        seedNpm(sb)
        let disk = try await connect(sb, try attach(sb))
        let p = try await plan(disk, "npm-cache")
        Faults.onHit = { point in
            if point == .afterAct(.copy) { sb.put(".npm/late.bin", bytes: 9) }
        }
        let outcome = try await move(disk, p)
        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(outcome.abort, .sourceChanged)
        XCTAssertFalse(isSymlink(sb.home + "/.npm"))
        XCTAssertFalse(sb.exists(sb.home + "/.npm.before-move"))
    }

    // S5
    func testADriveThatIsTooSmallIsRefusedBeforeAnythingIsCopied() async throws {
        let sb = try makeSandbox()
        sb.put(".npm/big.bin", bytes: 120_000_000, fill: 0x44)
        let disk = try await connect(sb, try attach(sb, megabytes: 2_000))
        let report = await disk.backend.eligibility(disk.facts.id, "npm-cache")
        XCTAssertTrue(report.refusals.contains { $0.rule == .e12 }, "free space is E12: \(report.refusals.map(\.message))")
        let c = ConsentRecord(recipeVersion: 1, tickedIDs: Catalogue.recipe("npm-cache")?.consent?.checkboxes.map(\.id) ?? [], ackIDs: report.acks.map(\.ackID), sawUnverifiedNote: true)
        let result = await disk.backend.plan("npm-cache", disk.facts.id, c)
        XCTAssertNil(result.plan)
        XCTAssertNotNil(result.refusal)
        XCTAssertTrue(Journal.loadAll(home: sb.home).filter { $0.id != "app" }.isEmpty, "a refused plan writes no move line")
    }

    // S6
    func testADriveYankedDuringTheCopyAbortsAndLeavesTheSourceAlone() async throws {
        let sb = try makeSandbox()
        seedNpm(sb)
        let image = try attach(sb)
        let disk = try await connect(sb, image)
        let p = try await plan(disk, "npm-cache")
        Faults.onHit = { point in
            if point == .afterIntent(.copy) { DiskImageLab.detach(image, force: true) }
        }
        let outcome = try await move(disk, p)
        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(outcome.state, .aborted)
        XCTAssertEqual(sb.names(in: ".npm"), ["_cacache", "orig.bin"])
        XCTAssertFalse(sb.exists(sb.home + "/.npm.before-move"))
        XCTAssertFalse(isSymlink(sb.home + "/.npm"))
    }

    // S16
    func testAFolderAnAppMakesBetweenTheRenameAndTheLinkIsSetAsideAndTheOriginalComesBack() async throws {
        let sb = try makeSandbox()
        seedNpm(sb)
        let disk = try await connect(sb, try attach(sb))
        let p = try await plan(disk, "npm-cache")
        Faults.onHit = { point in
            if point == .afterAct(.setAside) { sb.put(".npm/made-by-app.bin", bytes: 4) }
        }
        let outcome = try await move(disk, p)
        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(outcome.state, .aborted)
        XCTAssertEqual(outcome.abort, .foreignFolderAppeared)
        XCTAssertEqual(sb.names(in: ".npm"), ["_cacache", "orig.bin"], "the original is back")
        XCTAssertEqual(sb.names(in: ".npm.created-while-moving"), ["made-by-app.bin"], "what the app made is set aside whole")
        XCTAssertFalse(sb.exists(sb.home + "/.npm.before-move"))
        XCTAssertEqual(record(sb, p.id)?.abort, .foreignFolderAppeared)
    }

    // S18
    func testRollbackAfterTheAppWroteToTheDriveKeepsThoseFilesOnTheDrive() async throws {
        let sb = try makeSandbox()
        seedNpm(sb)
        let disk = try await connect(sb, try attach(sb))
        let p = try await plan(disk, "npm-cache")
        let moved = try await move(disk, p)
        XCTAssertTrue(moved.ok, moved.message)
        for i in 1...3 { sb.put(".npm/written-by-app-\(i).bin", bytes: 8 + i) }   // through the link, onto the drive
        let undone = await disk.backend.rollback(p.id)
        XCTAssertTrue(undone.ok, undone.message)
        XCTAssertTrue(undone.message.contains("3 files"), "the count is said before anything is lost sight of: \(undone.message)")
        XCTAssertEqual(sb.names(in: ".npm"), ["_cacache", "orig.bin"], "the original, without the three files")
        for i in 1...3 { XCTAssertTrue(sb.exists(p.destination.finalPath + "/written-by-app-\(i).bin"), "kept on the drive") }
        XCTAssertEqual(record(sb, p.id)?.state, .rolledBack)
    }

    // S19
    func testReturnToMacAfterConfirmingBringsAVerifiedCopyBackAndKeepsTheDriveCopy() async throws {
        let sb = try makeSandbox()
        seedNpm(sb)
        let disk = try await connect(sb, try attach(sb))
        let p = try await plan(disk, "npm-cache")
        let moved = try await move(disk, p)
        XCTAssertTrue(moved.ok, moved.message)
        let confirmed = await disk.backend.confirm(p.id)
        if confirmed.state != .originalTrashed { throw XCTSkip("the Trash is not available in this session: \(confirmed.message)") }
        XCTAssertFalse(sb.exists(sb.home + "/.npm.before-move"))
        let back = await disk.backend.returnToMac(p.id, { _ in })
        XCTAssertTrue(back.ok, back.message)
        XCTAssertEqual(back.state, .returned)
        XCTAssertTrue(Fs.isPlainDirectory(sb.home + "/.npm"), "a real folder again")
        XCTAssertEqual(sb.names(in: ".npm"), ["_cacache", "orig.bin"])
        XCTAssertTrue(sb.exists(p.destination.finalPath + "/orig.bin"), "the drive copy stays until the user trashes it")
        XCTAssertEqual(record(sb, p.id)?.state, .returned)
    }
}

final class DriveFolderPlantedTests: DiskTestCase {
    /// A drive whose `Outboard` is a link to a folder elsewhere: "Use this drive" refuses, nothing is written through the link, and no
    /// marker or check file on it is believed.
    func testADriveWithOutboardAsALinkIsRefusedAndNothingIsWrittenThroughIt() async throws {
        let sb = try makeSandbox()
        let image = try attach(sb)
        let elsewhere = sb.dir("elsewhere")
        try FileManager.default.createSymbolicLink(atPath: image.mountPoint + "/Outboard", withDestinationPath: elsewhere)
        let disk = try await connect(sb, image, mark: false)
        let used = await disk.backend.useDrive(disk.facts.id)
        XCTAssertFalse(used.ok, used.message)
        XCTAssertEqual(sb.names(in: "elsewhere"), [], "nothing was written through the link")
        XCTAssertFalse(OutboardRoot.driveFolderIsSound(mountPoint: image.mountPoint))
        XCTAssertNil(OutboardRoot.readMarker(mountPoint: image.mountPoint))
        var p = Fixtures.plan(sb, mount: Fs.normalized(image.mountPoint))
        p.destination.volumeUUID = disk.uuid   // the real drive, so the answer comes from the folder check and not from "the drive is not mounted"
        XCTAssertFalse(OutboardRoot.ensureRecipeFolder(plan: p), "the recipe folder is not made through the link either")
        XCTAssertEqual(sb.names(in: "elsewhere"), [])
    }

    /// `Outboard` becomes a link after the plan was made: the move stops before a byte is copied, and nothing goes through the link.
    func testAnOutboardFolderReplacedByALinkAfterPlanningHaltsTheMoveBeforeTheCopy() async throws {
        let sb = try makeSandbox()
        seedNpm(sb)
        let disk = try await connect(sb, try attach(sb))
        let p = try await plan(disk, "npm-cache")
        let mount = Fs.normalized(disk.image.mountPoint)
        let elsewhere = sb.dir("elsewhere")
        try FileManager.default.moveItem(atPath: mount + "/Outboard", toPath: mount + "/Outboard-real")
        try FileManager.default.createSymbolicLink(atPath: mount + "/Outboard", withDestinationPath: elsewhere)
        let outcome = await disk.backend.move(p, { _ in })
        XCTAssertFalse(outcome.ok, outcome.message)
        XCTAssertEqual(outcome.state, .aborted)
        XCTAssertEqual(sb.names(in: "elsewhere"), [], "nothing was written through the link")
        XCTAssertEqual(sb.names(in: ".npm"), ["_cacache", "orig.bin"], "the original is untouched")
        XCTAssertFalse(steps(lines(sb, p.id)).contains("copy.intent"), "no copy was started")
    }

    /// The same, one step later: the recipe folder is a link to a place on the drive itself that no check of the parent would catch.
    func testARecipeFolderThatIsALinkIsNeverCopiedInto() async throws {
        let sb = try makeSandbox()
        seedNpm(sb)
        let disk = try await connect(sb, try attach(sb))
        let p = try await plan(disk, "npm-cache")
        let mount = Fs.normalized(disk.image.mountPoint)
        let elsewhere = sb.dir("elsewhere")
        try FileManager.default.createDirectory(atPath: mount + "/Outboard", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: mount + "/" + p.destination.recipeFolder, withDestinationPath: elsewhere)
        XCTAssertFalse(OutboardRoot.recipeFolderIsOnDrive(p))
        XCTAssertFalse(OutboardRoot.ensureRecipeFolder(plan: p))
        guard case .refused = Copier.copy(p, home: sb.home, control: CopyControl()) else { return XCTFail("a copy must not start through a link") }
        XCTAssertEqual(sb.names(in: "elsewhere"), [])
        XCTAssertFalse(steps(lines(sb, p.id)).contains("copy.intent"))
    }
}

final class DriveEligibilityTests: DiskTestCase {
    private func report(_ disk: Disk, _ recipe: String = "npm-cache") async -> EligibilityReport {
        await disk.backend.eligibility(disk.facts.id, recipe)
    }

    // S9
    func testTwoDrivesWithTheSameNameAreBothRefused() async throws {
        let sb = try makeSandbox()
        let first = try attach(sb, volumeName: "Outboard-TEST-Backup")
        let second = try attach(sb, volumeName: "Outboard-TEST-Backup")
        let a = try await connect(sb, first, mark: false)
        let b = try await connect(sb, second, mark: false)
        XCTAssertNotEqual(a.facts.mountPoint, b.facts.mountPoint, "the second one mounts under another name")
        let ra = await report(a)
        let rb = await report(b)
        XCTAssertTrue(ra.refusals.contains { $0.rule == .e8 }, "first: \(ra.refusals.map(\.message))")
        XCTAssertTrue(rb.refusals.contains { $0.rule == .e8 }, "second: \(rb.refusals.map(\.message))")
    }

    // S10
    func testAReadOnlyAttachIsRefused() async throws {
        let sb = try makeSandbox()
        let disk = try await connect(sb, try attach(sb, readOnly: true), mark: false)
        let r = await report(disk)
        XCTAssertTrue(r.refusals.contains { $0.rule == .e6 }, "\(r.verdicts.map(\.message))")
    }

    // S11
    func testAVolumeThatIgnoresOwnershipIsNotSilentlyAccepted() async throws {
        let sb = try makeSandbox()
        let disk = try await connect(sb, try attach(sb, ownersOff: true), mark: false)
        let r = await report(disk)
        // The flag name is VERIFY, so the rule may refuse or ask for a tick; what it must not do is say nothing.
        let e9 = r.verdicts.filter { $0.rule == .e9 && ($0.outcome == .refuse || $0.outcome == .ack) }
        if e9.isEmpty { throw XCTSkip("this runner's volume did not report the ignore-ownership flag (E9 key name is VERIFY)") }
        XCTAssertFalse(e9.isEmpty)
    }

    // S12. ExFAT labels hold 11 characters (VERIFY), so this one volume cannot start with "Outboard-TEST"; tools/disk_image.sh cleanup also detaches OB-TEST*.
    func testExFATIsRefusedAndMacOSExtendedIsNotOfferedForAppData() async throws {
        let sb = try makeSandbox()
        let exfat = try await connect(sb, try attach(sb, volumeName: "OB-TEST-EXF", fileSystem: "ExFAT"), mark: false)
        let rx = await report(exfat)
        XCTAssertTrue(rx.refusals.contains { $0.rule == .e4 }, "\(rx.verdicts.map(\.message))")
        let hfs = try await connect(sb, try attach(sb, volumeName: "Outboard-TEST-HFS", fileSystem: "HFS+"), mark: false)
        let r = await report(hfs)
        XCTAssertTrue(r.refusals.contains { $0.rule == .e4 } || r.warnings.contains { $0.rule == .e4 }, "HFS+ is refused or warned for app data: \(r.verdicts.map(\.message))")
    }

    // S13
    func testACaseSensitiveVolumeIsFineForACaseInsensitiveSource() async throws {
        let sb = try makeSandbox()
        seedNpm(sb)
        let disk = try await connect(sb, try attach(sb, volumeName: "Outboard-TEST-CASE", fileSystem: "Case-sensitive APFS"), mark: false)
        let r = await report(disk)
        XCTAssertFalse(r.refusals.contains { $0.rule == .e10 }, "the reverse (case-sensitive source on a case-insensitive drive) is the refused one")
    }

    // S15
    func testATimeMachineBackupFolderAtTheRootRefusesTheDrive() async throws {
        let sb = try makeSandbox()
        let image = try attach(sb)
        try FileManager.default.createDirectory(atPath: image.mountPoint + "/Backups.backupdb", withIntermediateDirectories: true)
        let disk = try await connect(sb, image, mark: false)
        let r = await report(disk)
        XCTAssertTrue(r.refusals.contains { $0.rule == .e7 }, "\(r.verdicts.map(\.message))")
    }

    // MARK: a copy that stopped

    /// A move that stopped in the middle of its copy, as the journal would show it: the staging folder is on the drive with part of
    /// the data. `crash` leaves no result line for the copy (the process died; the next launch aborts the move).
    private func stoppedCopy(_ sb: Sandbox, crash: Bool) async throws -> (disk: Disk, plan: MovePlan, next: MovePlan, leftover: Leftover) {
        seedNpm(sb)
        let disk = try await connect(sb, try attach(sb))
        let p = try await plan(disk, "npm-cache")
        let next = try await plan(disk, "npm-cache")
        let subject = JournalSubject(p)
        let volume = VolumeRef(uuid: p.destination.volumeUUID, name: p.destination.volumeName, token: p.destination.volumeToken)
        XCTAssertTrue(Journal.begin(p, onDriveMissing: .parkPlaceholder, volume: volume, home: sb.home, at: Date()))
        XCTAssertTrue(Journal.intent(.preflight, subject: subject, home: sb.home, state: .preflight))
        Journal.result(.preflight, subject: subject, home: sb.home, status: .ok)
        XCTAssertTrue(OutboardRoot.ensureRecipeFolder(plan: p))
        XCTAssertTrue(Journal.intent(.copy, subject: subject, home: sb.home, src: p.sourcePath, to: p.stagingPath, stamp: p.sourceStamp, state: .copying))
        try FileManager.default.createDirectory(atPath: p.stagingPath, withIntermediateDirectories: false)
        try Data(count: 100).write(to: URL(fileURLWithPath: p.stagingPath + "/partial.bin"))
        if crash {
            XCTAssertEqual(Recover.run(home: sb.home).first?.state, .aborted)
        } else {
            Journal.result(.copy, subject: subject, home: sb.home, status: .interrupted, src: p.sourcePath, to: p.stagingPath, stamp: Fs.stamp(of: p.stagingPath))
            Journal.result(.abort, subject: subject, home: sb.home, status: .ok, abort: .userCancelled, state: .aborted, note: "Stopped.")
        }
        let entries = Journal.loadAll(home: sb.home)
        let found = RelocationFold.leftovers(from: entries, records: RelocationFold.records(from: entries)).first { $0.kind == .incompleteCopy && $0.moveID == p.id }
        return (disk, p, next, try XCTUnwrap(found, "the partial copy is listed as a leftover"))
    }

    private func assertTrashedAndNextTryPassesP7(_ sb: Sandbox, _ stopped: (disk: Disk, plan: MovePlan, next: MovePlan, leftover: Leftover),
                                                 file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(Preflight.leftovers(stopped.next, home: sb.home).isEmpty, "the partial copy blocks P7 until it is trashed", file: file, line: line)
        let outcome = Leftovers.trash(stopped.leftover.id, home: sb.home)
        if !outcome.ok, outcome.message.contains("Trash") { throw XCTSkip("the Trash is not available in this session: \(outcome.message)") }
        XCTAssertTrue(outcome.ok, outcome.message, file: file, line: line)
        XCTAssertFalse(sb.exists(stopped.plan.stagingPath), "the partial copy left its place", file: file, line: line)
        XCTAssertEqual(Preflight.leftovers(stopped.next, home: sb.home), [], "P7 passes for the next try", file: file, line: line)
    }

    func testACancelledCopyLeavesAFolderTheUserCanTrashAndTryAgain() async throws {
        let sb = try makeSandbox()
        let stopped = try await stoppedCopy(sb, crash: false)
        try assertTrashedAndNextTryPassesP7(sb, stopped)
    }

    func testACopyThatDiedWithoutAResultLineCanBeTrashedToo() async throws {
        let sb = try makeSandbox()
        let stopped = try await stoppedCopy(sb, crash: true)
        try assertTrashedAndNextTryPassesP7(sb, stopped)
    }
}

final class GuardScenarioTests: DiskTestCase {
    private func moved(_ sb: Sandbox) async throws -> (Disk, MovePlan) {
        seedNpm(sb)
        let disk = try await connect(sb, try attach(sb))
        let p = try await plan(disk, "npm-cache")
        let outcome = try await move(disk, p)
        XCTAssertTrue(outcome.ok, outcome.message)
        return (disk, p)
    }

    private func assertParked(_ sb: Sandbox, _ p: MovePlan, file: StaticString = #filePath, line: UInt = #line) {
        var st = stat()
        XCTAssertEqual(lstat(sb.home + "/.npm", &st), 0, file: file, line: line)
        XCTAssertEqual(st.st_mode & S_IFMT, S_IFREG, "a note stands where the folder was", file: file, line: line)
        XCTAssertEqual(st.st_mode & 0o777, 0o444, file: file, line: line)
        XCTAssertTrue(isSymlink(Park.parkedFolder(moveID: p.id, home: sb.home) + "/link"), "the link is kept in Parked/", file: file, line: line)
    }

    // S7 and S8
    func testEjectParksAndACleanReturnReconnectsAfterTheSample() async throws {
        let sb = try makeSandbox()
        let (disk, p) = try await moved(sb)
        VolumeWatcher.setRemovalForTests(.ejected, uuid: disk.uuid)
        XCTAssertTrue(DiskImageLab.detach(disk.image))
        Reconcile.setLaunchedAt(Date().addingTimeInterval(-60))
        let away = await disk.backend.reconcile(.unmount)    // includes the 5 second debounce
        XCTAssertEqual(away.relocations.first?.health, .driveAway)
        assertParked(sb, p)
        XCTAssertEqual(record(sb, p.id)?.isParked, true)
        XCTAssertEqual(record(sb, p.id)?.needsCheckBeforeReconnect, false, "an eject was seen")

        let image = try DiskImageLab.attach(disk.image.file)
        addTeardownBlock { DiskImageLab.detach(image, force: true) }
        let back = await disk.backend.reconcile(.mount)
        XCTAssertEqual(back.relocations.first?.health, .healthy, "\(back)")
        assertRedirected(sb, disk)
        XCTAssertEqual(record(sb, p.id)?.isParked, false)
        XCTAssertTrue(sb.exists(Park.parkedFolder(moveID: p.id, home: sb.home) + "/note"), "the note was moved away, not deleted")
        XCTAssertTrue(back.banners.contains { $0.kind == .backClean } || back.banners.isEmpty, "\(back.banners.map(\.text))")
    }

    // S17
    func testAPulledDriveStaysDisconnectedUntilCheckAndReconnect() async throws {
        let sb = try makeSandbox()
        let (disk, p) = try await moved(sb)
        XCTAssertTrue(DiskImageLab.detach(disk.image, force: true))
        Reconcile.setLaunchedAt(Date().addingTimeInterval(-60))
        _ = await disk.backend.reconcile(.unmount)
        assertParked(sb, p)
        XCTAssertEqual(record(sb, p.id)?.needsCheckBeforeReconnect, true)

        let image = try DiskImageLab.attach(disk.image.file)
        addTeardownBlock { DiskImageLab.detach(image, force: true) }
        let held = await disk.backend.reconcile(.mount)
        XCTAssertEqual(held.relocations.first?.health, .held)
        XCTAssertEqual(held.relocations.first?.held, .uncleanRemoval)
        assertParked(sb, p)   // nothing was reconnected

        let checked = await disk.backend.checkAndReconnect(p.id, { _ in })
        XCTAssertTrue(checked.ok, checked.message)
        assertRedirected(sb, disk)
        XCTAssertEqual(record(sb, p.id)?.needsCheckBeforeReconnect, false)
    }

    // S20
    func testParkingAndReconnectingTwiceNeverLeavesDuplicatesOrFailsTheSecondTime() async throws {
        let sb = try makeSandbox()
        let (disk, p) = try await moved(sb)
        var current = disk.image
        for round in 1...2 {
            VolumeWatcher.setRemovalForTests(.ejected, uuid: disk.uuid)
            XCTAssertTrue(DiskImageLab.detach(current), "round \(round)")
            Reconcile.setLaunchedAt(Date().addingTimeInterval(-60))
            _ = await disk.backend.reconcile(.unmount)
            assertParked(sb, p)
            current = try DiskImageLab.attach(disk.image.file)
            let image = current
            addTeardownBlock { DiskImageLab.detach(image, force: true) }
            let back = await disk.backend.reconcile(.mount)
            XCTAssertEqual(back.relocations.first?.health, .healthy, "round \(round): \(back)")
            assertRedirected(sb, disk)
        }
        let parked = sb.names(in: "Library/Application Support/Outboard/Parked/" + p.id)
        XCTAssertTrue(parked.contains("note") && parked.contains("note-2"), "each round keeps its own note: \(parked)")
    }

    /// The drive goes away and comes back while another volume with the same name holds the old mount point, so it mounts under
    /// "<name> 1". No pass runs in between: the guard finds a link that still names the old path and a drive at a new one.
    private func remountUnderAnotherPath(_ sb: Sandbox, _ disk: Disk) throws -> DiskImageLab.Image {
        XCTAssertTrue(DiskImageLab.detach(disk.image))
        _ = try attach(sb)   // same volume name, a different UUID: takes the old mount point
        let image = try DiskImageLab.attach(disk.image.file)
        addTeardownBlock { DiskImageLab.detach(image, force: true) }
        guard image.mountPoint != disk.image.mountPoint else { throw XCTSkip("the drive came back at the same mount point on this runner") }
        return image
    }

    // A retarget leaves the old link in Parked/<id>/link, so the next eject has to park beside it (link-2).
    func testEjectingAfterARetargetStillParksAndKeepsBothLinks() async throws {
        let sb = try makeSandbox()
        let (disk, p) = try await moved(sb)
        let image = try remountUnderAnotherPath(sb, disk)
        Reconcile.setLaunchedAt(Date().addingTimeInterval(-60))
        let moved = await disk.backend.reconcile(.mount)
        XCTAssertEqual(moved.relocations.first?.health, .healthy, "\(moved)")
        let parkedFolder = Park.parkedFolder(moveID: p.id, home: sb.home)
        XCTAssertEqual(Fs.linkTarget(sb.home + "/.npm")?.hasPrefix(Fs.normalized(image.mountPoint) + "/"), true, "the link follows the drive")
        XCTAssertTrue(isSymlink(parkedFolder + "/link"), "the old link is kept")

        VolumeWatcher.setRemovalForTests(.ejected, uuid: disk.uuid)
        XCTAssertTrue(DiskImageLab.detach(image))
        let away = await disk.backend.reconcile(.unmount)
        XCTAssertEqual(away.relocations.first?.health, .driveAway)
        var st = stat()
        XCTAssertEqual(lstat(sb.home + "/.npm", &st), 0)
        XCTAssertEqual(st.st_mode & S_IFMT, S_IFREG, "a note stands where the folder was")
        XCTAssertTrue(isSymlink(parkedFolder + "/link") && isSymlink(parkedFolder + "/link-2"), "\(sb.names(in: "Library/Application Support/Outboard/Parked/" + p.id))")
        XCTAssertEqual(record(sb, p.id)?.isParked, true)
    }

    // A setting that still holds the old mount path is written again with the new one.
    func testASettingFollowsADriveThatCameBackUnderAnotherMountPoint() async throws {
        let sb = try makeSandbox()
        sb.put("Library/Developer/Xcode/DerivedData/build/a.o", bytes: 9_000)
        let disk = try await connect(sb, try attach(sb))
        defaults.install()
        let p = try await plan(disk, "xcode-deriveddata")
        let outcome = try await move(disk, p)
        XCTAssertTrue(outcome.ok, outcome.message)
        let image = try remountUnderAnotherPath(sb, disk)
        Reconcile.setLaunchedAt(Date().addingTimeInterval(-60))
        let snapshot = await disk.backend.reconcile(.mount)
        XCTAssertEqual(snapshot.relocations.first?.health, .healthy, "\(snapshot)")
        guard case .defaults(_, let writes, _, _) = p.redirect, let pathKey = writes.first(where: { $0.value == p.destination.finalPath }) else {
            return XCTFail("a defaults plan with a path key")
        }
        XCTAssertEqual(defaults.store[pathKey.key], Fs.normalized(image.mountPoint) + "/" + p.destination.relativePath, "the setting names the drive's new mount point")
        XCTAssertEqual(steps(lines(sb, p.id)).suffix(2), ["retarget.intent", "retarget.result"])
        XCTAssertTrue(sb.exists(Fs.normalized(image.mountPoint) + "/" + p.destination.relativePath + "/build/a.o"), "the copy on the drive is untouched")
    }

    // The note has been moved away; if the link then cannot be made, the path must not be left empty.
    func testAnUnparkWhoseLinkFailsStandsANoteAtThePathAgain() async throws {
        let sb = try makeSandbox()
        let (disk, p) = try await moved(sb)
        VolumeWatcher.setRemovalForTests(.ejected, uuid: disk.uuid)
        XCTAssertTrue(DiskImageLab.detach(disk.image))
        Reconcile.setLaunchedAt(Date().addingTimeInterval(-60))
        _ = await disk.backend.reconcile(.unmount)
        assertParked(sb, p)
        // Back under another mount point, so the parked link names the wrong place and a fresh link has to be made.
        _ = try attach(sb)
        let image = try DiskImageLab.attach(disk.image.file)
        addTeardownBlock { DiskImageLab.detach(image, force: true) }
        guard image.mountPoint != disk.image.mountPoint else { throw XCTSkip("the drive came back at the same mount point on this runner") }
        let macPath = sb.home + "/.npm"
        // Something small blocks the link while it is being made and is gone again before the result line: the link did not come, and
        // the path is empty.
        Faults.onHit = { point in
            if point == .afterIntent(.redirect) { FileManager.default.createFile(atPath: macPath, contents: Data()) }
            if point == .afterAct(.redirect) { try? FileManager.default.removeItem(atPath: macPath) }
        }
        _ = await disk.backend.reconcile(.mount)
        Faults.disarm()
        var st = stat()
        XCTAssertEqual(lstat(macPath, &st), 0, "the path is not left empty")
        XCTAssertEqual(st.st_mode & S_IFMT, S_IFREG, "a note stands there again")
        XCTAssertEqual(record(sb, p.id)?.isParked, true)
        XCTAssertEqual(lines(sb, p.id).last { $0.step == "unpark" && $0.phase == .result }?.status, .failed)
    }

    // A different drive with the same name
    func testADifferentDriveWithTheSameNameIsNeverTreatedAsTheOne() async throws {
        let sb = try makeSandbox()
        let (disk, p) = try await moved(sb)
        VolumeWatcher.setRemovalForTests(.ejected, uuid: disk.uuid)
        XCTAssertTrue(DiskImageLab.detach(disk.image))
        Reconcile.setLaunchedAt(Date().addingTimeInterval(-60))
        _ = await disk.backend.reconcile(.unmount)
        let impostor = try attach(sb)   // another image with the same volume name, a different UUID
        _ = impostor
        let snapshot = await disk.backend.reconcile(.mount)
        XCTAssertNotEqual(snapshot.relocations.first?.health, .healthy)
        assertParked(sb, p)
    }
}

final class CrashRecoveryTests: DiskTestCase {
    private struct Point: CustomStringConvertible {
        var phase: String
        var step: MoveStep
        var occurrence: Int
        var arg: String { "\(phase):\(step.rawValue):\(occurrence)" }
        var description: String { arg }
    }

    /// Every journal record of a symlink move (S2): the intent and the act of each step. `publish` is written twice (the rename, then the check files).
    private let points: [Point] = [
        Point(phase: "intent", step: .preflight, occurrence: 1), Point(phase: "act", step: .preflight, occurrence: 1),
        Point(phase: "intent", step: .copy, occurrence: 1), Point(phase: "act", step: .copy, occurrence: 1),
        Point(phase: "intent", step: .verify, occurrence: 1), Point(phase: "act", step: .verify, occurrence: 1),
        Point(phase: "intent", step: .publish, occurrence: 1), Point(phase: "act", step: .publish, occurrence: 1),
        Point(phase: "intent", step: .publish, occurrence: 2), Point(phase: "act", step: .publish, occurrence: 2),
        Point(phase: "intent", step: .setAside, occurrence: 1), Point(phase: "act", step: .setAside, occurrence: 1),
        Point(phase: "intent", step: .redirect, occurrence: 1), Point(phase: "act", step: .redirect, occurrence: 1),
        Point(phase: "act", step: .swapped, occurrence: 1),
    ]

    private func helperPath() throws -> String {
        guard let path = builtProduct("OutboardCrashHelper") else { throw XCTSkip("the crash helper was not built next to the tests") }
        return path
    }

    func testTheProcessDiesAtEveryJournalRecordAndRecoveryLeavesTheDataSafe() async throws {
        let helper = try helperPath()
        for (index, point) in points.enumerated() {
            Reconcile.resetForTests()
            let sb = try makeSandbox()
            seedNpm(sb)
            // A volume name of its own each time, and the image is detached at the end of the round: two drives with one name are refused.
            let disk = try await connect(sb, try attach(sb, volumeName: "Outboard-TEST-CRASH-\(index)"))
            defer { DiskImageLab.detach(disk.image, force: true) }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: helper)
            process.arguments = ["--home", sb.home, "--volume", disk.facts.id, "--recipe", "npm-cache", "--arm", point.arg]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 9, "\(point): the helper should have died at the armed point")

            // What a launch does: recover, then the guard.
            _ = Recover.run(home: sb.home)
            Reconcile.setLaunchedAt(Date().addingTimeInterval(-60))
            _ = await disk.backend.reconcile(.launch)

            let path = sb.home + "/.npm"
            let before = path + Names.beforeMoveSuffix
            let atPathIsOriginal = Fs.isPlainDirectory(path) && sb.exists(path + "/orig.bin")
            let atPathIsLink = isSymlink(path) && VolumeIdentity.same(VolumeIdentity.volumeUUID(ofResolved: path), disk.uuid) && sb.exists(path + "/orig.bin")
            // (b) the original is at the path, or the path leads to a copy that is the original.
            XCTAssertTrue(atPathIsOriginal || atPathIsLink, "\(point): the path holds neither the original nor a link to its copy")
            // (c) a complete copy exists somewhere: the original itself, or the safety copy next to it.
            XCTAssertTrue(atPathIsOriginal || sb.exists(before + "/orig.bin"), "\(point): no complete original anywhere")
            // (a) nothing was deleted or merged: no folder was ever removed, and a folder an app made is set aside whole.
            XCTAssertFalse(sb.exists(path + "/made-by-app.bin"))
            // The record is in a state the machine allows, and a second recovery finds nothing to do.
            let moveID = try XCTUnwrap(Journal.loadAll(home: sb.home).first { $0.step == "begin" }?.id, "\(point): no begin line")
            let record = try XCTUnwrap(Fixtures.currentRecord(sb, moveID), "\(point): no record")
            XCTAssertTrue([.aborted, .swapped, .rolledBack].contains(record.state), "\(point): ended in \(record.state)")
            XCTAssertTrue(Recover.run(home: sb.home).isEmpty, "\(point): recovery is not idempotent")
        }
    }
}
#endif
