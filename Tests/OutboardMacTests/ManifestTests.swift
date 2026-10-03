import Darwin
import Foundation
import XCTest
import OutboardCore
@testable import OutboardMac

final class ManifestTests: MacTestCase {
    /// The manifest of the sandbox's stand-in drive folder, hashed the way the verifier hashes, saved the way the engine saves it.
    private func saveManifest(_ sb: Sandbox, _ layout: Fixtures.Layout, withDriveCopy: Bool = false) throws -> ManifestFile {
        var entries = try XCTUnwrap(SizeScanner.walk(layout.driveFolder)).entries
        for i in entries.indices where entries[i].type == .file {
            entries[i].sha256 = try XCTUnwrap(Verifier.hashFile(layout.driveFolder + "/" + entries[i].path, noCache: false).hex)
        }
        let manifest = ManifestFile(moveID: layout.plan.id, recipeID: layout.plan.recipeID, createdAt: Fixtures.t0, entries: entries,
                                    digest: Verifier.sha256Hex(of: TreeCompare.manifestText(entries)))
        let folder = withDriveCopy ? URL(fileURLWithPath: Fs.parent(of: layout.driveFolder)) : nil
        XCTAssertTrue(ManifestStore.save(manifest, home: sb.home, driveFolder: folder))
        return manifest
    }

    func testAManifestIsWrittenOnceWithPrivateModesAndReadsBackIntact() throws {
        let sb = try makeSandbox()
        let layout = try Fixtures.swapped(sb)
        let manifest = try saveManifest(sb, layout)
        let path = ManifestStore.folder(home: sb.home) + "/" + ManifestStore.fileName(moveID: layout.plan.id)
        XCTAssertEqual(sb.mode(ManifestStore.folder(home: sb.home)), 0o700)
        XCTAssertEqual(sb.mode(path), 0o600)
        XCTAssertEqual(ManifestStore.load(moveID: layout.plan.id, home: sb.home)?.digest, manifest.digest)
        XCTAssertFalse(ManifestStore.save(manifest, home: sb.home, driveFolder: nil), "a manifest is never rewritten")
    }

    func testAManifestWhoseContentsChangedReadsAsMissing() throws {
        let sb = try makeSandbox()
        let layout = try Fixtures.swapped(sb)
        _ = try saveManifest(sb, layout)
        let path = ManifestStore.folder(home: sb.home) + "/" + ManifestStore.fileName(moveID: layout.plan.id)
        var text = try XCTUnwrap(sb.read(path))
        text = text.replacingOccurrences(of: "copy.bin", with: "copz.bin")
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertNil(ManifestStore.load(moveID: layout.plan.id, home: sb.home), "it no longer matches its own digest")
    }

    func testTheCopyOnTheDriveIsUsedWhenTheMacCopyIsGone() throws {
        let sb = try makeSandbox()
        let layout = try Fixtures.swapped(sb)
        let manifest = try saveManifest(sb, layout, withDriveCopy: true)
        try FileManager.default.removeItem(atPath: ManifestStore.folder(home: sb.home))
        XCTAssertNil(ManifestStore.load(moveID: layout.plan.id, home: sb.home))
        XCTAssertEqual(ManifestStore.load(moveID: layout.plan.id, home: sb.home, driveFolder: Fs.parent(of: layout.driveFolder))?.digest, manifest.digest)
    }

    /// A manifest over the old 64 MiB reader limit (but far under the 256 MiB limit both sides share now) is written, and reads back.
    /// Before the limits agreed, `save` wrote such a file and `load` refused it, so a big folder was rolled back after its long copy.
    func testAManifestOverSixtyFourMegabytesIsWrittenAndReadBack() throws {
        let sb = try makeSandbox()
        let layout = try Fixtures.swapped(sb)
        let sha = String(repeating: "ab", count: 32)
        let longPath = String(repeating: "d", count: 1_000)
        let entries = (0..<70_000).map { TreeEntry(path: longPath + String($0), type: .file, size: 1, sha256: sha) }
        let manifest = ManifestFile(moveID: layout.plan.id, recipeID: layout.plan.recipeID, createdAt: Fixtures.t0, entries: entries,
                                    digest: Verifier.sha256Hex(of: TreeCompare.manifestText(entries)))
        XCTAssertTrue(ManifestStore.save(manifest, home: sb.home, driveFolder: URL(fileURLWithPath: Fs.parent(of: layout.driveFolder))))
        let path = ManifestStore.folder(home: sb.home) + "/" + ManifestStore.fileName(moveID: layout.plan.id)
        XCTAssertGreaterThan(Fs.info(path).st.st_size, 64 << 20, "the file is over the old reader limit")
        XCTAssertEqual(ManifestStore.load(moveID: layout.plan.id, home: sb.home)?.entries.count, entries.count)
        XCTAssertEqual(ManifestStore.load(moveID: layout.plan.id, home: "/nonexistent", driveFolder: Fs.parent(of: layout.driveFolder))?.digest, manifest.digest)
    }

    // MARK: the checks on return

    private func record(_ sb: Sandbox) throws -> RelocationRecord {
        try XCTUnwrap(Fixtures.currentRecord(sb))
    }

    func testACleanDriveSamplePassesAndHashesTheUnchangedFiles() throws {
        let sb = try makeSandbox()
        let layout = try Fixtures.swapped(sb)
        _ = try saveManifest(sb, layout)
        let mount = sb.home + "/fakedrive"
        let result = Reconcile.returnCheck(try record(sb), mount: mount, full: false, home: sb.home, isCancelled: { false }, progress: { _, _ in })
        XCTAssertTrue(result.quickPassed)
        XCTAssertEqual(result.hashed, 1)
        XCTAssertEqual(result.mismatches, 0)
        XCTAssertTrue(result.passed)
        XCTAssertFalse(result.fullCheck)
    }

    func testAFileCorruptedWithoutChangingItsSizeOrTimeIsFound() throws {
        let sb = try makeSandbox()
        let layout = try Fixtures.swapped(sb)
        _ = try saveManifest(sb, layout)
        let file = layout.driveFolder + "/copy.bin"
        var before = stat()
        XCTAssertEqual(lstat(file, &before), 0)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: file))
        handle.write(Data([0x7A]))
        handle.closeFile()
        // Put the modification time back, so the file looks untouched to the listing.
        var times = [timeval(tv_sec: before.st_mtimespec.tv_sec, tv_usec: 0), timeval(tv_sec: before.st_mtimespec.tv_sec, tv_usec: 0)]
        XCTAssertEqual(utimes(file, &times), 0)
        let mount = sb.home + "/fakedrive"
        let result = Reconcile.returnCheck(try record(sb), mount: mount, full: true, home: sb.home, isCancelled: { false }, progress: { _, _ in })
        XCTAssertEqual(result.hashed, 1)
        XCTAssertEqual(result.mismatches, 1)
        XCTAssertTrue(result.fullCheck)
        XCTAssertFalse(result.passed)
        // And Core's judgement of that result: an unclean removal stays held on a mismatch.
        let facts = GuardFacts(path: .placeholder, drive: .mountedAtRecordedPath, sentinel: .ok, targetOnRecordedVolume: .yes, removal: .unclean)
        XCTAssertEqual(Held.evaluate(facts: facts, record: try record(sb), check: result), .hold(.sampleMismatch))
    }

    func testAFileAnAppWroteSinceIsCountedAndNeverCompared() throws {
        let sb = try makeSandbox()
        let layout = try Fixtures.swapped(sb)
        _ = try saveManifest(sb, layout)
        let rewritten = sb.put("fakedrive/Outboard/npm-cache/npm/copy.bin", bytes: 25)   // a different size: an app wrote it
        var later = [timeval(tv_sec: time(nil) + 100, tv_usec: 0), timeval(tv_sec: time(nil) + 100, tv_usec: 0)]
        XCTAssertEqual(utimes(rewritten, &later), 0)
        sb.put("fakedrive/Outboard/npm-cache/npm/new.bin", bytes: 5)
        let result = Reconcile.returnCheck(try record(sb), mount: sb.home + "/fakedrive", full: true, home: sb.home, isCancelled: { false }, progress: { _, _ in })
        XCTAssertEqual(result.hashed, 0)
        XCTAssertEqual(result.mismatches, 0)
        XCTAssertEqual(result.changedSince, 2)
        XCTAssertTrue(result.passed)
    }

    func testAMissingFileFailsTheQuickCheck() throws {
        let sb = try makeSandbox()
        let layout = try Fixtures.swapped(sb)
        _ = try saveManifest(sb, layout)
        try FileManager.default.removeItem(atPath: layout.driveFolder + "/copy.bin")
        let result = Reconcile.returnCheck(try record(sb), mount: sb.home + "/fakedrive", full: false, home: sb.home, isCancelled: { false }, progress: { _, _ in })
        XCTAssertFalse(result.quickPassed)
        XCTAssertEqual(result.missing, 1)
    }

    func testWithoutAManifestNothingPasses() throws {
        let sb = try makeSandbox()
        try Fixtures.swapped(sb)
        let result = Reconcile.returnCheck(try record(sb), mount: sb.home + "/fakedrive", full: false, home: sb.home, isCancelled: { false }, progress: { _, _ in })
        XCTAssertFalse(result.quickPassed)
    }

    func testTheSampleIsTheSameEveryTime() throws {
        let sb = try makeSandbox()
        let layout = try Fixtures.swapped(sb)
        for i in 0..<30 { sb.put("fakedrive/Outboard/npm-cache/npm/f\(i).bin", bytes: 10 + i) }
        _ = try saveManifest(sb, layout)
        let a = Reconcile.returnCheck(try record(sb), mount: sb.home + "/fakedrive", full: false, home: sb.home, isCancelled: { false }, progress: { _, _ in })
        let b = Reconcile.returnCheck(try record(sb), mount: sb.home + "/fakedrive", full: false, home: sb.home, isCancelled: { false }, progress: { _, _ in })
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashed, 31)
    }
}

final class JournalFactsTests: MacTestCase {
    func testTheStampsAndTheLastLinkComeFromTheJournalLines() throws {
        let sb = try makeSandbox()
        let layout = try Fixtures.swapped(sb)
        let facts = JournalFacts(moveID: layout.plan.id, all: Journal.loadAll(home: sb.home), home: sb.home)
        XCTAssertEqual(facts.sourceStamp?.inode, layout.plan.sourceStamp.inode)
        XCTAssertEqual(facts.setAsideStamp?.inode, layout.plan.sourceStamp.inode)
        let link = try XCTUnwrap(facts.lastLink)
        XCTAssertEqual(link.target, layout.driveFolder)
        XCTAssertEqual(link.stamp.type, .symlink)
        XCTAssertNil(facts.lastPlaceholder)
        XCTAssertNil(facts.lastRemoval)
    }

    func testOtherMovesLinesAreIgnored() throws {
        let sb = try makeSandbox()
        let layout = try Fixtures.swapped(sb)
        let other = JournalFacts(moveID: "20270115T090000Z-bbbbbb", all: Journal.loadAll(home: sb.home), home: sb.home)
        XCTAssertNil(other.lastLink)
        XCTAssertNil(other.setAsideStamp)
        XCTAssertEqual(other.entries.count, 0)
        _ = layout
    }
}
