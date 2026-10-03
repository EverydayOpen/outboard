import Darwin
import Foundation
import XCTest
import OutboardCore
@testable import OutboardMac

final class VerifierTests: MacTestCase {
    /// A source tree and its copy, made the way the app copies (a real `copyItem`), plus the walk Manifest A would be.
    private struct Pair {
        var source: String
        var copy: String
        var start: [TreeEntry]
    }

    private func pair(_ sb: Sandbox) throws -> Pair {
        sb.put("src/a.bin", bytes: 5000, fill: 0x01)
        sb.put("src/sub/b.bin", bytes: 70_000, fill: 0x02)
        sb.put("src/sub/deep/c.txt", bytes: 12, fill: 0x03)
        sb.dir("src/empty")
        try FileManager.default.createSymbolicLink(atPath: sb.home + "/src/link", withDestinationPath: "sub/b.bin")
        let start = try XCTUnwrap(SizeScanner.walk(sb.home + "/src")).entries
        try FileManager.default.copyItem(atPath: sb.home + "/src", toPath: sb.home + "/copy")
        return Pair(source: sb.home + "/src", copy: sb.home + "/copy", start: start)
    }

    private func verify(_ p: Pair) -> VerifyOutcome {
        Verifier.verify(sourceRoot: p.source, destinationRoot: p.copy, startManifest: p.start, isCancelled: { false }, progress: { _, _, _ in })
    }

    private func failure(_ outcome: VerifyOutcome, file: StaticString = #filePath, line: UInt = #line) -> VerifyFailure? {
        if case .mismatch(let f) = outcome { return f }
        XCTFail("expected a mismatch", file: file, line: line)
        return nil
    }

    func testAnIdenticalCopyIsVerifiedWithEveryFileHashed() throws {
        let sb = try makeSandbox()
        let p = try pair(sb)
        guard case .verified(let report) = verify(p) else { return XCTFail("expected verified") }
        XCTAssertEqual(report.summary.filesCompared, 3)
        XCTAssertEqual(report.summary.bytesCompared, 5000 + 70_000 + 12)
        XCTAssertEqual(report.summary.symlinksCompared, 1)
        XCTAssertEqual(report.summary.differences, 0)
        XCTAssertTrue(report.summary.destinationReadUncached)
        XCTAssertEqual(report.manifest.filter { $0.type == .file }.compactMap(\.sha256).count, 3)
        XCTAssertEqual(report.summary.manifestDigest, Verifier.sha256Hex(of: TreeCompare.manifestText(report.manifest)))
    }

    func testOneFlippedByteIsAMismatch() throws {
        let sb = try makeSandbox()
        let p = try pair(sb)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: p.copy + "/sub/b.bin"))
        handle.seek(toFileOffset: 30_000)
        handle.write(Data([0xFF]))
        handle.closeFile()
        let f = try XCTUnwrap(failure(verify(p)))
        XCTAssertEqual(f.abort, .mismatch)
        XCTAssertEqual(f.differences.first?.path, "sub/b.bin")
        XCTAssertEqual(f.differences.first?.kind, .hashDiffers)
    }

    func testAMissingAnExtraAndAResizedFileAreMismatches() throws {
        let sb = try makeSandbox()
        let p = try pair(sb)
        try FileManager.default.removeItem(atPath: p.copy + "/a.bin")
        sb.put("copy/extra.bin", bytes: 1)
        let f = try XCTUnwrap(failure(verify(p)))
        let kinds = Set(f.differences.map(\.kind))
        XCTAssertTrue(kinds.contains(.missingOnDrive))
        XCTAssertTrue(kinds.contains(.extraOnDrive))

        let sb2 = try makeSandbox()
        let q = try pair(sb2)
        sb2.put("copy/a.bin", bytes: 4999, fill: 0x01)
        let g = try XCTUnwrap(failure(verify(q)))
        XCTAssertEqual(g.differences.first?.kind, .sizeDiffers)
    }

    func testAChangedPermissionOrLinkTargetIsAMismatch() throws {
        let sb = try makeSandbox()
        let p = try pair(sb)
        XCTAssertEqual(chmod(p.copy + "/a.bin", 0o600), 0)
        XCTAssertTrue(failure(verify(p))?.differences.contains { $0.kind == .modeDiffers } ?? false)

        let sb2 = try makeSandbox()
        let q = try pair(sb2)
        try FileManager.default.removeItem(atPath: q.copy + "/link")
        try FileManager.default.createSymbolicLink(atPath: q.copy + "/link", withDestinationPath: "sub/other")
        XCTAssertTrue(failure(verify(q))?.differences.contains { $0.kind == .symlinkTargetDiffers } ?? false)
    }

    func testAnExtendedAttributeThatDiffersIsAMismatch() throws {
        let sb = try makeSandbox()
        let p = try pair(sb)
        let value = Array("x".utf8)
        #if os(macOS)
        let rc = setxattr(p.copy + "/a.bin", "user.outboard.test", value, value.count, 0, 0)
        #else
        let rc = setxattr(p.copy + "/a.bin", "user.outboard.test", value, value.count, 0)
        #endif
        if rc != 0 { throw XCTSkip("this filesystem does not take extended attributes") }
        XCTAssertTrue(failure(verify(p))?.differences.contains { $0.kind == .xattrDiffers } ?? false)
    }

    func testASourceThatChangedAfterTheManifestIsASourceChange() throws {
        let sb = try makeSandbox()
        let p = try pair(sb)
        // Something wrote to the source after Manifest A and, in this test, also to the copy so the trees still match.
        sb.put("src/late.bin", bytes: 9)
        sb.put("copy/late.bin", bytes: 9)
        let f = try XCTUnwrap(failure(verify(p)))
        XCTAssertEqual(f.abort, .sourceChanged)
        XCTAssertTrue(f.differences.contains { $0.path == "late.bin" })
    }

    func testHardLinkedFilesCopiedSeparatelyAreCountedNotRefused() throws {
        let sb = try makeSandbox()
        let first = sb.put("src/one.bin", bytes: 3000, fill: 0x07)
        XCTAssertEqual(Darwin.link(first, sb.home + "/src/two.bin"), 0)
        let start = try XCTUnwrap(SizeScanner.walk(sb.home + "/src")).entries
        // Copy file by file, as a copy across volumes does: two separate files.
        try FileManager.default.createDirectory(atPath: sb.home + "/copy", withIntermediateDirectories: true)
        for name in ["one.bin", "two.bin"] { try Data(contentsOf: URL(fileURLWithPath: sb.home + "/src/" + name)).write(to: URL(fileURLWithPath: sb.home + "/copy/" + name)) }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sb.home + "/copy/one.bin")
        let p = Pair(source: sb.home + "/src", copy: sb.home + "/copy", start: start)
        let outcome = verify(p)
        guard case .verified(let report) = outcome else { return XCTFail("expected verified, got \(outcome)") }
        XCTAssertEqual(report.summary.hardLinkedCopiedSeparately, 2)
    }

    func testCancellingStopsBeforeAnythingIsReportedAsVerified() throws {
        let sb = try makeSandbox()
        let p = try pair(sb)
        let outcome = Verifier.verify(sourceRoot: p.source, destinationRoot: p.copy, startManifest: p.start, isCancelled: { true }, progress: { _, _, _ in })
        XCTAssertEqual(failure(outcome)?.abort, .userCancelled)
    }

    func testTheKnownSha256Vector() {
        XCTAssertEqual(Verifier.sha256Hex(of: "abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(Verifier.sha256Hex(of: ""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testHashingAFileAgreesWithHashingItsText() throws {
        let sb = try makeSandbox()
        let path = sb.put("t.txt", bytes: 3, fill: 0x61)   // "aaa"
        let result = Verifier.hashFile(path, noCache: true)
        XCTAssertEqual(result.hex, Verifier.sha256Hex(of: "aaa"))
        XCTAssertEqual(Verifier.hashFile(sb.home + "/nope", noCache: false).hex, nil)
    }

    func testCompareHashesFindsOnlyTheDifferentFile() throws {
        let sb = try makeSandbox()
        let p = try pair(sb)
        guard case .verified(let report) = verify(p) else { return XCTFail("expected verified") }
        sb.put("copy/sub/deep/c.txt", bytes: 12, fill: 0x09)
        let check = Verifier.compareHashes(root: p.copy, manifest: report.manifest, paths: ["a.bin", "sub/b.bin", "sub/deep/c.txt"], byteBudget: nil,
                                           isCancelled: { false }, progress: { _, _ in })
        XCTAssertEqual(check.hashed, 3)
        XCTAssertEqual(check.mismatched, ["sub/deep/c.txt"])
    }

    func testTheByteBudgetLeavesFilesOutAndSaysSo() throws {
        let sb = try makeSandbox()
        let p = try pair(sb)
        guard case .verified(let report) = verify(p) else { return XCTFail("expected verified") }
        let check = Verifier.compareHashes(root: p.copy, manifest: report.manifest, paths: ["sub/b.bin", "a.bin", "sub/deep/c.txt"], byteBudget: 75_001,
                                           isCancelled: { false }, progress: { _, _ in })
        XCTAssertEqual(check.hashed, 2)
        XCTAssertEqual(check.skippedForBudget, 1)
    }
}
