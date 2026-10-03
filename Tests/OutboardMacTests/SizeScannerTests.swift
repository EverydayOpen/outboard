import Darwin
import Foundation
import XCTest
import OutboardCore
@testable import OutboardMac

final class SizeScannerTests: MacTestCase {
    func testCountsFilesFoldersAndBytes() throws {
        let sb = try makeSandbox()
        sb.put(".npm/a/one.bin", bytes: 1000)
        sb.put(".npm/a/two.bin", bytes: 2000)
        sb.put(".npm/three.bin", bytes: 500)
        let w = try XCTUnwrap(SizeScanner.walk(sb.home + "/.npm"))
        XCTAssertEqual(w.fingerprint.files, 3)
        XCTAssertEqual(w.fingerprint.directories, 1)
        XCTAssertEqual(w.fingerprint.logicalBytes, 3500)
        XCTAssertTrue(w.isComplete)
        XCTAssertEqual(w.entries.map(\.path), ["a", "a/one.bin", "a/two.bin", "three.bin"])
    }

    func testAHardLinkedFileCountsEveryNameForTheCopyAndOneInodeOnDisk() throws {
        let sb = try makeSandbox()
        let first = sb.put(".npm/one.bin", bytes: 4000)
        XCTAssertEqual(Darwin.link(first, sb.home + "/.npm/two.bin"), 0)
        let w = try XCTUnwrap(SizeScanner.walk(sb.home + "/.npm"))
        XCTAssertEqual(w.fingerprint.files, 2)
        XCTAssertEqual(w.fingerprint.hardLinkedFiles, 1)
        XCTAssertEqual(w.fingerprint.logicalBytes, 8000, "the copy writes both names, so both sizes land on the drive")
        var st = stat()
        XCTAssertEqual(lstat(first, &st), 0)
        XCTAssertEqual(w.fingerprint.allocatedBytes, Fs.allocated(st), "the space on this disk counts the inode once")
        XCTAssertEqual(w.entries.filter { $0.hardLinkGroup != nil }.count, 2)
    }

    func testSymlinksAreCountedAndNeverFollowed() throws {
        let sb = try makeSandbox()
        let outside = sb.dir("outside")
        sb.put("outside/big.bin", bytes: 100_000)
        sb.put(".npm/a.bin", bytes: 10)
        try FileManager.default.createSymbolicLink(atPath: sb.home + "/.npm/out", withDestinationPath: outside)
        let w = try XCTUnwrap(SizeScanner.walk(sb.home + "/.npm"))
        XCTAssertEqual(w.fingerprint.symlinks, 1)
        XCTAssertEqual(w.fingerprint.files, 1)
        XCTAssertEqual(w.fingerprint.logicalBytes, 10)
        XCTAssertEqual(w.entries.first { $0.path == "out" }?.symlinkTarget, outside)
    }

    func testASymlinkRootIsNotWalked() throws {
        let sb = try makeSandbox()
        let target = sb.dir("real")
        sb.link(".npm", to: target)
        XCTAssertNil(SizeScanner.walk(sb.home + "/.npm"))
    }

    func testMeasureReportsAbsentLinkedAndMeasured() throws {
        let sb = try makeSandbox()
        let npm = try XCTUnwrap(Catalogue.recipe("npm-cache"))
        let ollama = try XCTUnwrap(Catalogue.recipe("ollama-models"))
        sb.put(".npm/x.bin", bytes: 300)
        let real = sb.dir("elsewhere")
        sb.link(".ollama/models", to: real)
        let hf = try XCTUnwrap(Catalogue.recipe("huggingface-hub-cache"))
        let scans = SizeScanner.measure([npm, ollama, hf], home: sb.home, now: Fixtures.t0)
        let byRecipe = Dictionary(grouping: scans, by: \.recipeID)
        XCTAssertEqual(byRecipe["npm-cache"]?.first?.state, .measured)
        XCTAssertEqual(byRecipe["npm-cache"]?.first?.fingerprint.logicalBytes, 300)
        let linked = try XCTUnwrap(byRecipe["ollama-models"]?.first)
        XCTAssertTrue(linked.isLink)
        XCTAssertEqual(linked.state, .notMeasured)
        XCTAssertEqual(linked.reason, .alreadyRedirected)
        XCTAssertEqual(byRecipe["huggingface-hub-cache"]?.first?.state, .absent)
    }

    func testAFolderMacOSProtectsIsNeedsFullDiskAccess() throws {
        let sb = try makeSandbox()
        guard getuid() != 0 else { throw XCTSkip("root can open every folder") }
        let ios = try XCTUnwrap(Catalogue.recipe("ios-device-backups"))
        let folder = sb.dir("Library/Application Support/MobileSync/Backup")
        sb.put("Library/Application Support/MobileSync/Backup/device/x", bytes: 10)
        XCTAssertEqual(chmod(folder, 0o000), 0)
        defer { chmod(folder, 0o700) }
        let scan = try XCTUnwrap(SizeScanner.measure([ios], home: sb.home, now: Fixtures.t0).first)
        XCTAssertEqual(scan.state, .notMeasured)
        XCTAssertEqual(scan.reason, .needsFullDiskAccess)
        XCTAssertTrue(scan.errnoCode == EACCES || scan.errnoCode == EPERM)
    }

    func testARedirectedSettingIsNotOffered() throws {
        let sb = try makeSandbox()
        let xcode = try XCTUnwrap(Catalogue.recipe("xcode-deriveddata"))
        sb.put("Library/Developer/Xcode/DerivedData/a.o", bytes: 50)
        let scan = try XCTUnwrap(SizeScanner.measure([xcode], home: sb.home, now: Fixtures.t0, redirected: { _ in "/Volumes/Other/DD" }).first)
        XCTAssertEqual(scan.state, .notMeasured)
        XCTAssertEqual(scan.reason, .alreadyRedirected)
        XCTAssertEqual(scan.linkTarget, "/Volumes/Other/DD")
    }

    func testTheScanChangesNothing() throws {
        let sb = try makeSandbox()
        sb.put(".npm/a/one.bin", bytes: 1000)
        sb.put(".npm/b.bin", bytes: 20)
        sb.put(".ollama/models/m.bin", bytes: 77)
        let before = snapshot(sb.home)
        let recipes = [Catalogue.recipe("npm-cache")!, Catalogue.recipe("ollama-models")!]
        _ = SizeScanner.measure(recipes, home: sb.home, now: Fixtures.t0)
        _ = SizeScanner.walk(sb.home + "/.npm")
        XCTAssertEqual(snapshot(sb.home), before, "measuring creates, renames, changes and removes nothing")
    }

    /// Every path under `root` with its inode, size and modification time.
    private func snapshot(_ root: String) -> [String] {
        var out: [String] = []
        for name in (FileManager.default.subpaths(atPath: root) ?? []).sorted() {
            var st = stat()
            if lstat(root + "/" + name, &st) == 0 { out.append("\(name)|\(st.st_ino)|\(st.st_size)|\(st.st_mtimespec.tv_sec)|\(st.st_mode)") }
        }
        return out
    }

    func testSparseAndSpecialFilesAreFlagged() throws {
        let sb = try makeSandbox()
        let path = sb.put(".npm/hole.bin", bytes: 1)
        let fd = open(path, O_WRONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        // A 64 MB file with one byte at the end: most of it is a hole on APFS.
        XCTAssertEqual(ftruncate(fd, 64 << 20), 0)
        XCTAssertEqual(mkfifo(sb.home + "/.npm/pipe", 0o600), 0)
        let w = try XCTUnwrap(SizeScanner.walk(sb.home + "/.npm"))
        XCTAssertEqual(w.fingerprint.specialFiles, 1)
        if w.fingerprint.sparseFiles == 0 { throw XCTSkip("this filesystem allocated the whole file, so it is not sparse here") }
        XCTAssertEqual(w.fingerprint.sparseFiles, 1)
    }
}
