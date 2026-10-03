#if DEBUG
import Darwin
import Foundation
import XCTest
import OutboardCore
@testable import OutboardMac

/// The review fixes that need a real volume (disk image; OUTBOARD_DISK_TESTS=1, see DiskTestCase). Written, not compiled.
final class HardeningDiskTests: DiskTestCase {
    private var children: [Process] = []

    override func tearDown() {
        for p in children where p.isRunning {
            p.terminate()
            p.waitUntilExit()
        }
        children = []
        super.tearDown()
    }

    /// Starts a copy of the tiny fixture executable under `path`, so the running check finds a process by that name.
    private func launchFixture(at path: String) -> Process? {
        let source = builtProduct("OutboardFixture") ?? "/bin/sleep"
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard (try? FileManager.default.copyItem(atPath: source, toPath: path)) != nil else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["120"]
        guard (try? process.run()) != nil else { return nil }
        children.append(process)
        Thread.sleep(forTimeInterval: 0.4)
        return process.isRunning ? process : nil
    }

    private func seedOllama(_ sb: Sandbox) {
        sb.put(".ollama/models/blobs/a.bin", bytes: 30_000, fill: 0x11)
        sb.put(".ollama/models/manifests/m.json", bytes: 100, fill: 0x22)
    }

    private func moved(_ sb: Sandbox, recipe: String = "npm-cache") async throws -> (Disk, MovePlan) {
        if recipe == "npm-cache" { seedNpm(sb) } else { seedOllama(sb) }
        let disk = try await connect(sb, try attach(sb))
        let p = try await plan(disk, recipe)
        let outcome = try await move(disk, p)
        XCTAssertTrue(outcome.ok, outcome.message)
        return (disk, p)
    }

    // MARK: [1] a rolled-back Xcode recipe can be planned again

    func testAfterARollbackBothXcodeRecipesCanBePlannedAgain() async throws {
        let sb = try makeSandbox()
        sb.put("Library/Developer/Xcode/DerivedData/build/a.o", bytes: 9_000)
        sb.put("Library/Developer/Xcode/Archives/2027-01-15/App.xcarchive/Info.plist", bytes: 300)
        let disk = try await connect(sb, try attach(sb))
        defaults.install()
        for id in ["xcode-deriveddata", "xcode-archives"] {
            let p = try await plan(disk, id)
            let outcome = try await move(disk, p)
            XCTAssertTrue(outcome.ok, "\(id): \(outcome.message)")
            let swapped = try XCTUnwrap(record(sb, p.id), id)
            let undone = Rollback.run(swapped, home: sb.home)
            XCTAssertTrue(undone.ok, "\(id): \(undone.message)")
            // The path key is still set (a restore never deletes a key). It no longer means "already moved".
            let scans = await disk.backend.measure([id])
            let scan = try XCTUnwrap(scans.first, id)
            XCTAssertEqual(scan.state, .measured, "\(id): \(scan.reason.map { "\($0)" } ?? "")")
            let agreed = try await consent(disk, id)
            let again = await disk.backend.plan(id, disk.facts.id, agreed)
            XCTAssertNotNil(again.plan, "\(id): \(again.refusal ?? "no reason")")
        }
    }

    // MARK: [3] [6] a parent folder that is a link

    func testASourceReachedThroughALinkedParentIsRefusedAtP4AndNothingMoves() async throws {
        let sb = try makeSandbox()
        sb.put("Library/CloudStorage/Dropbox-Work/ollama/models/blobs/a.bin", bytes: 30_000)
        sb.link(".ollama", to: sb.home + "/Library/CloudStorage/Dropbox-Work/ollama")
        let disk = try await connect(sb, try attach(sb))
        let p = try await plan(disk, "ollama-models")
        let outcome = try await move(disk, p)
        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(outcome.abort, .preflightFailed)
        let p4 = try XCTUnwrap(outcome.preflight?.checks.first { $0.check == .p4 })
        XCTAssertFalse(p4.passed)
        XCTAssertTrue(p4.detail.contains("iCloud"), p4.detail)
        XCTAssertEqual(sb.names(in: "Library/CloudStorage/Dropbox-Work/ollama/models"), ["blobs"])
        XCTAssertFalse(steps(lines(sb, p.id)).contains("copy.intent"), "nothing was copied")
    }

    // MARK: [7] the app opens after the copy was published, before the swap

    func testAnAppThatOpensBeforeTheSwapHaltsTheMoveAndTheOriginalStaysPut() async throws {
        let sb = try makeSandbox()
        guard Processes.names()?.contains("launchd") == true else { throw XCTSkip("the process list cannot be read here") }
        seedOllama(sb)
        let disk = try await connect(sb, try attach(sb))
        let p = try await plan(disk, "ollama-models")
        let started = Box()
        Faults.onHit = { [self] point in
            guard point == .afterAct(.publish), started.process == nil else { return }
            started.process = launchFixture(at: sb.home + "/bin/ollama")
        }
        let outcome = try await move(disk, p)
        guard started.process != nil else { throw XCTSkip("could not start a helper process") }
        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(outcome.state, .aborted)
        XCTAssertEqual(outcome.abort, .appLaunched, outcome.message)
        XCTAssertEqual(sb.names(in: ".ollama/models"), ["blobs", "manifests"], "the original is where it was")
        XCTAssertFalse(isSymlink(sb.home + "/.ollama/models"))
        XCTAssertFalse(sb.exists(sb.home + "/.ollama/models.before-move"), "nothing was renamed")
        XCTAssertTrue(sb.exists(p.sentinelPath), "the copy and its check file stay on the drive")
        let entries = Journal.loadAll(home: sb.home)
        XCTAssertTrue(RelocationFold.leftovers(from: entries, records: RelocationFold.records(from: entries)).contains { $0.kind == .incompleteCopy },
                      "the published copy is listed as a leftover")
        XCTAssertFalse(steps(lines(sb, p.id)).contains("setAside.intent"))
    }

    private final class Box: @unchecked Sendable {
        var process: Process?
    }

    // MARK: [8] a refused eject

    func testARefusedEjectDoesNotMakeALaterPullLookLikeAnEject() async throws {
        let sb = try makeSandbox()
        let (disk, p) = try await moved(sb)
        // The eject was refused (volume busy): the will-unmount was seen, the drive stayed.
        VolumeWatcher.setRemovalForTests(.ejected, uuid: disk.uuid)
        Reconcile.setLaunchedAt(Date().addingTimeInterval(-60))
        _ = await disk.backend.reconcile(.timer)
        XCTAssertNil(VolumeWatcher.removal(of: disk.uuid), "a drive that is still mounted has not left")
        // Later the cable is pulled. The notification a pull gives is only the unmount.
        XCTAssertTrue(DiskImageLab.detach(disk.image, force: true))
        VolumeWatcher.noteDidUnmount(disk.uuid)
        _ = await disk.backend.reconcile(.unmount)
        let parked = try XCTUnwrap(record(sb, p.id))
        XCTAssertTrue(parked.isParked)
        XCTAssertTrue(parked.needsCheckBeforeReconnect, "the full file check on reconnect is not skipped")
        XCTAssertEqual(JournalFacts(moveID: p.id, all: Journal.loadAll(home: sb.home), home: sb.home).lastRemoval, .unclean)
    }

    // MARK: [9] Confirm and Return

    private func confirmFixture(_ sb: Sandbox) async throws -> (Disk, MovePlan, RelocationRecord) {
        let (disk, p) = try await moved(sb)
        return (disk, p, try XCTUnwrap(record(sb, p.id)))
    }

    private func assertConfirmRefused(_ sb: Sandbox, _ record: RelocationRecord, containing text: String, file: StaticString = #filePath, line: UInt = #line) {
        let before = Journal.loadAll(home: sb.home).count
        let outcome = Confirm.run(record, home: sb.home)
        XCTAssertFalse(outcome.ok, file: file, line: line)
        XCTAssertTrue(outcome.message.contains(text), outcome.message, file: file, line: line)
        XCTAssertEqual(Journal.loadAll(home: sb.home).count, before, "a refused confirm writes nothing", file: file, line: line)
        XCTAssertEqual(Fixtures.currentRecord(sb, record.id)?.state, .swapped, file: file, line: line)
    }

    func testConfirmIsRefusedWhenTheDriveIsAbsent() async throws {
        let sb = try makeSandbox()
        let (disk, _, record) = try await confirmFixture(sb)
        XCTAssertTrue(DiskImageLab.detach(disk.image, force: true))
        assertConfirmRefused(sb, record, containing: "in first")
        XCTAssertTrue(sb.exists(sb.home + "/.npm.before-move/orig.bin"))
    }

    func testConfirmIsRefusedWhenTheMoveDoesNotLookHealthy() async throws {
        let sb = try makeSandbox()
        let (_, _, record) = try await confirmFixture(sb)
        try FileManager.default.removeItem(atPath: sb.home + "/.npm")
        try FileManager.default.createSymbolicLink(atPath: sb.home + "/.npm", withDestinationPath: sb.dir("somewhere-else"))
        assertConfirmRefused(sb, record, containing: "does not look healthy")
        XCTAssertTrue(sb.exists(sb.home + "/.npm.before-move/orig.bin"))
    }

    func testConfirmIsRefusedWhenTheSafetyCopyIsGone() async throws {
        let sb = try makeSandbox()
        let (_, _, record) = try await confirmFixture(sb)
        try FileManager.default.moveItem(atPath: sb.home + "/.npm.before-move", toPath: sb.home + "/.npm.moved-by-hand")
        assertConfirmRefused(sb, record, containing: "gone")
        XCTAssertTrue(sb.exists(sb.home + "/.npm.moved-by-hand/orig.bin"))
    }

    func testConfirmIsRefusedWhenTheSafetyCopyIsAnotherFolder() async throws {
        let sb = try makeSandbox()
        let (_, _, record) = try await confirmFixture(sb)
        try FileManager.default.moveItem(atPath: sb.home + "/.npm.before-move", toPath: sb.home + "/.npm.moved-by-hand")
        sb.put(".npm.before-move/other.bin")
        assertConfirmRefused(sb, record, containing: "changed")
        XCTAssertEqual(sb.names(in: ".npm.before-move"), ["other.bin"], "a different folder is never sent to the Trash")
    }

    func testConfirmIsRefusedWhenTheJournalTakesNoLine() async throws {
        let sb = try makeSandbox()
        let (_, _, record) = try await confirmFixture(sb)
        let file = Journal.directory(home: sb.home) + "/" + ActivityLog.fileName(for: Date())
        guard chflags(file, UInt32(UF_IMMUTABLE)) == 0 else { throw XCTSkip("this session cannot lock a file") }
        addTeardownBlock { chflags(file, 0) }
        let outcome = Confirm.run(record, home: sb.home)
        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(outcome.message, Say.journalBlocked)
        XCTAssertTrue(sb.exists(sb.home + "/.npm.before-move/orig.bin"), "nothing went to the Trash")
    }

    func testAnAppThatOpensBeforeTheReturnSwapStopsTheReturnAndLeavesTheLinkInPlace() async throws {
        let sb = try makeSandbox()
        guard Processes.names()?.contains("launchd") == true else { throw XCTSkip("the process list cannot be read here") }
        let (disk, p) = try await moved(sb, recipe: "ollama-models")
        let confirmed = await disk.backend.confirm(p.id)
        if confirmed.state != .originalTrashed { throw XCTSkip("the Trash is not available in this session: \(confirmed.message)") }
        let started = Box()
        Faults.onHit = { [self] point in
            guard point == .afterAct(.verify), started.process == nil else { return }
            started.process = launchFixture(at: sb.home + "/bin/ollama")
        }
        let back = await disk.backend.returnToMac(p.id, { _ in })
        guard started.process != nil else { throw XCTSkip("could not start a helper process") }
        XCTAssertFalse(back.ok)
        XCTAssertEqual(back.abort, .appLaunched, back.message)
        XCTAssertTrue(isSymlink(sb.home + "/.ollama/models"), "the link is still in place")
        XCTAssertTrue(sb.exists(p.destination.finalPath + "/blobs/a.bin"), "the copy on the drive is untouched")
        XCTAssertEqual(record(sb, p.id)?.state, .originalTrashed, "the way out is not closed")
    }

    // MARK: [11] the cable comes out during the copy

    func testADriveUnpluggedDuringTheCopySaysSoInPlainWords() async throws {
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
        XCTAssertEqual(outcome.abort, .driveChanged, outcome.message)
        XCTAssertTrue(outcome.message.contains("disconnected"), outcome.message)
        XCTAssertTrue(outcome.message.contains("Nothing on your Mac was changed"), outcome.message)
        XCTAssertEqual(sb.names(in: ".npm"), ["_cacache", "orig.bin"])
        XCTAssertFalse(sb.exists(sb.home + "/.npm.before-move"))
    }
}
#endif
