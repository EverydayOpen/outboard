import Foundation
import XCTest
@testable import OutboardCore

final class TreeCompareTests: XCTestCase {
    private func file(_ path: String, size: UInt64 = 10, sha: String? = nil, mode: UInt16 = 0o644, mtime: Int64 = 100, xattrs: [XattrInfo] = [], group: UInt64? = nil) -> TreeEntry {
        TreeEntry(path: path, type: .file, size: size, mode: mode, mtimeSeconds: mtime, xattrs: xattrs, sha256: sha ?? "h-\(path)", hardLinkGroup: group)
    }
    private func dir(_ path: String, mode: UInt16 = 0o755) -> TreeEntry { TreeEntry(path: path, type: .directory, mode: mode) }
    private func link(_ path: String, to target: String) -> TreeEntry { TreeEntry(path: path, type: .symlink, mode: 0o755, symlinkTarget: target) }

    private var tree: [TreeEntry] {
        [dir("snapshots"), dir("snapshots/rev1"), link("snapshots/rev1/model.bin", to: "../../blobs/abc"), dir("blobs"), file("blobs/abc", size: 4096),
         file("refs/main", size: 40, xattrs: [XattrInfo(name: "com.apple.quarantine", size: 20)])]
    }

    private func kinds(_ d: [Difference]) -> [DifferenceKind] { d.map(\.kind) }

    func testIdenticalTreesHaveNoDifferences() {
        XCTAssertEqual(TreeCompare.compare(source: tree, destination: tree, limit: 20), [])
        XCTAssertEqual(TreeCompare.totalDifferences(source: tree, destination: tree.reversed()), 0, "order does not matter")
        XCTAssertEqual(TreeCompare.compare(source: [], destination: [], limit: 20), [])
    }

    func testOneByteThatDiffersIsFound() {
        var dest = tree
        let i = dest.firstIndex { $0.path == "blobs/abc" }!
        dest[i].sha256 = "h-blobs/abd"
        let d = TreeCompare.compare(source: tree, destination: dest, limit: 20)
        XCTAssertEqual(d, [Difference(path: "blobs/abc", kind: .hashDiffers, detail: "the contents differ")])
    }

    func testEveryKindOfDifference() {
        var dest = tree
        dest.removeAll { $0.path == "refs/main" }                                           // missing on the drive
        dest.append(file("extra.txt"))                                                      // extra on the drive
        dest[dest.firstIndex { $0.path == "blobs/abc" }!] = file("blobs/abc", size: 4095)  // size
        dest[dest.firstIndex { $0.path == "blobs" }!] = file("blobs")                       // type
        dest[dest.firstIndex { $0.path == "snapshots/rev1/model.bin" }!] = link("snapshots/rev1/model.bin", to: "../../blobs/other")   // link target
        dest[dest.firstIndex { $0.path == "snapshots" }!] = dir("snapshots", mode: 0o700)   // mode
        let d = TreeCompare.compare(source: tree, destination: dest, limit: 50)
        let byPath = Dictionary(grouping: d, by: \.path).mapValues { kinds($0) }
        XCTAssertEqual(byPath["refs/main"], [.missingOnDrive])
        XCTAssertEqual(byPath["extra.txt"], [.extraOnDrive])
        XCTAssertEqual(byPath["blobs/abc"], [.sizeDiffers])
        XCTAssertEqual(byPath["blobs"], [.typeDiffers])
        XCTAssertEqual(byPath["snapshots/rev1/model.bin"], [.symlinkTargetDiffers])
        XCTAssertEqual(byPath["snapshots"], [.modeDiffers])
        XCTAssertEqual(TreeCompare.totalDifferences(source: tree, destination: dest), d.count)
        // extended attributes: a lost one and a different size
        var lost = tree
        lost[lost.firstIndex { $0.path == "refs/main" }!].xattrs = []
        XCTAssertEqual(kinds(TreeCompare.compare(source: tree, destination: lost, limit: 5)), [.xattrDiffers])
        var resized = tree
        resized[resized.firstIndex { $0.path == "refs/main" }!].xattrs = [XattrInfo(name: "com.apple.quarantine", size: 21)]
        XCTAssertEqual(kinds(TreeCompare.compare(source: tree, destination: resized, limit: 5)), [.xattrDiffers])
        // a mode that differs on a file
        var chmod = tree
        chmod[chmod.firstIndex { $0.path == "blobs/abc" }!].mode = 0o400
        XCTAssertEqual(kinds(TreeCompare.compare(source: tree, destination: chmod, limit: 5)), [.modeDiffers])
        // mode bits above the permission bits are ignored (a copy may add a type bit)
        var typeBits = tree
        typeBits[typeBits.firstIndex { $0.path == "blobs/abc" }!].mode = 0o100644
        XCTAssertEqual(TreeCompare.compare(source: tree, destination: typeBits, limit: 5), [])
    }

    func testAFileNobodyHashedIsNeverCalledEqual() {
        var dest = tree
        dest[dest.firstIndex { $0.path == "blobs/abc" }!].sha256 = nil
        XCTAssertEqual(kinds(TreeCompare.compare(source: tree, destination: dest, limit: 5)), [.unreadable])
        var source = tree
        source[source.firstIndex { $0.path == "blobs/abc" }!].sha256 = nil
        XCTAssertEqual(kinds(TreeCompare.compare(source: source, destination: tree, limit: 5)), [.unreadable])
        // an empty file hashes like any other
        XCTAssertEqual(TreeCompare.compare(source: [file("e", size: 0, sha: "e3b0c442")], destination: [file("e", size: 0, sha: "e3b0c442")], limit: 5), [])
    }

    func testTheListIsSortedAndLimited() {
        let src = (0..<50).map { file(String(format: "f%02d", $0)) }
        let d = TreeCompare.compare(source: src, destination: [], limit: Limits.firstDifferencesListed)
        XCTAssertEqual(d.count, 20)
        XCTAssertEqual(d.first?.path, "f00")
        XCTAssertEqual(d.last?.path, "f19")
        XCTAssertEqual(TreeCompare.totalDifferences(source: src, destination: []), 50)
        XCTAssertEqual(TreeCompare.compare(source: src, destination: [], limit: 0), [])
        XCTAssertEqual(TreeCompare.compare(source: src, destination: [], limit: -3), [])
    }

    func testHardLinkedFilesAreComparedByPathAndReportedNotRefused() {
        let source = [file("a", group: 7), file("b", group: 7), file("c"), file("d", group: 9), file("e", group: 9)]
        let separate = [file("a"), file("b"), file("c"), file("d"), file("e")]
        XCTAssertEqual(TreeCompare.compare(source: source, destination: separate, limit: 5), [], "a copy made file by file is not a failure")
        XCTAssertEqual(TreeCompare.hardLinkedCopiedSeparately(source: source, destination: separate), 4)
        let kept = [file("a", group: 1), file("b", group: 1), file("c"), file("d"), file("e")]
        XCTAssertEqual(TreeCompare.hardLinkedCopiedSeparately(source: source, destination: kept), 2, "one group was kept")
        XCTAssertEqual(TreeCompare.hardLinkedCopiedSeparately(source: separate, destination: separate), 0)
    }

    func testChangedDuringCopy() {
        XCTAssertEqual(TreeCompare.changedDuringCopy(start: tree, now: tree, limit: 5), [])
        var now = tree
        now[now.firstIndex { $0.path == "blobs/abc" }!].mtimeSeconds += 5                 // an app wrote it
        now.append(file("new.bin"))                                                        // an app added one
        now.removeAll { $0.path == "refs/main" }                                           // an app removed one
        now[now.firstIndex { $0.path == "blobs" }!].mtimeSeconds += 50                     // a directory's own time moves: not a change
        let d = TreeCompare.changedDuringCopy(start: tree, now: now, limit: 20)
        XCTAssertEqual(d.map(\.path), ["blobs/abc", "new.bin", "refs/main"])
        XCTAssertTrue(d.allSatisfy { $0.kind == .changedDuringCopy })
        XCTAssertEqual(d.map(\.detail), ["changed while copying", "added while copying", "removed while copying"])
        var relinked = tree
        relinked[relinked.firstIndex { $0.path == "snapshots/rev1/model.bin" }!] = link("snapshots/rev1/model.bin", to: "elsewhere")
        XCTAssertEqual(TreeCompare.changedDuringCopy(start: tree, now: relinked, limit: 5).count, 1)
        XCTAssertEqual(TreeCompare.changedDuringCopy(start: tree, now: now, limit: 1).count, 1)
    }

    func testManifestTextIsSortedPathNulHashNewline() {
        let text = TreeCompare.manifestText([file("b", sha: "22"), dir("a"), link("c", to: "b"), file("a/x", sha: "11")])
        XCTAssertEqual(text, "a\u{0}dir\na/x\u{0}11\nb\u{0}22\nc\u{0}link:b\n")
        XCTAssertEqual(TreeCompare.manifestText([]), "")
        // the order of the input does not matter
        XCTAssertEqual(TreeCompare.manifestText(tree), TreeCompare.manifestText(tree.reversed()))
        // a different link target or hash changes the text
        var other = tree
        other[other.firstIndex { $0.path == "blobs/abc" }!].sha256 = "x"
        XCTAssertNotEqual(TreeCompare.manifestText(tree), TreeCompare.manifestText(other))
    }

    // MARK: return checks

    private func manifestEntries() -> [TreeEntry] { (0..<1000).map { file("f\($0)", size: UInt64($0 + 1), mtime: 1_000) } + [dir("d")] }

    func testQuickCheckListsAndSizes() {
        let manifest = manifestEntries()
        XCTAssertTrue(ReturnCheck.quick(manifest: manifest, current: manifest))
        var added = manifest
        added.append(file("new", size: 5, mtime: 2_000))
        XCTAssertTrue(ReturnCheck.quick(manifest: manifest, current: added), "files added since are not a failure")
        var written = manifest
        written[3].mtimeSeconds = 5_000
        written[3].size = 9_999
        XCTAssertTrue(ReturnCheck.quick(manifest: manifest, current: written), "an app wrote it: the time moved with the size")
        var truncated = manifest
        truncated[4].size = 1                                   // same time, different size: nobody wrote this through an app
        XCTAssertFalse(ReturnCheck.quick(manifest: manifest, current: truncated))
        XCTAssertEqual(ReturnCheck.sizeMismatches(manifest: manifest, current: truncated), 1)
        var missing = manifest
        missing.removeAll { $0.path == "f7" }
        XCTAssertFalse(ReturnCheck.quick(manifest: manifest, current: missing))
        XCTAssertEqual(ReturnCheck.missingFiles(manifest: manifest, current: missing), 1)
        var retyped = manifest
        retyped[5] = dir(retyped[5].path)
        XCTAssertFalse(ReturnCheck.quick(manifest: manifest, current: retyped))
        XCTAssertFalse(ReturnCheck.quick(manifest: manifest, current: []), "an empty drive")
        XCTAssertTrue(ReturnCheck.quick(manifest: [], current: []))
    }

    func testUnchangedAndChangedSince() {
        let manifest = manifestEntries()
        var current = manifest
        current[0].mtimeSeconds = 9
        current[1].size += 1
        current.append(file("added", size: 1, mtime: 3_000))
        let unchanged = ReturnCheck.unchanged(manifest: manifest, current: current)
        XCTAssertEqual(unchanged.count, 998)
        XCTAssertFalse(unchanged.contains("f0"))
        XCTAssertFalse(unchanged.contains("f1"))
        XCTAssertFalse(unchanged.contains("added"))
        XCTAssertFalse(unchanged.contains("d"), "a folder is not hashed")
        XCTAssertEqual(unchanged, unchanged.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) })
        XCTAssertEqual(ReturnCheck.changedSince(manifest: manifest, current: current), 3, "two changed and one added")
        // a manifest entry without a hash cannot be compared
        var nohash = manifest
        nohash[2].sha256 = nil
        XCTAssertFalse(ReturnCheck.unchanged(manifest: nohash, current: nohash).contains("f2"))
    }

    func testTheSampleIsBoundedDeterministicAndOfUnchangedFiles() {
        let manifest = manifestEntries()
        var current = manifest
        current[10].mtimeSeconds = 7
        let s1 = ReturnCheck.sample(manifest: manifest, current: current, limit: Limits.returnSampleFiles, seed: 42)
        let s2 = ReturnCheck.sample(manifest: manifest, current: current, limit: Limits.returnSampleFiles, seed: 42)
        let s3 = ReturnCheck.sample(manifest: manifest, current: current, limit: Limits.returnSampleFiles, seed: 43)
        XCTAssertEqual(s1.count, 200)
        XCTAssertEqual(s1, s2, "the same inputs and seed give the same files")
        XCTAssertNotEqual(s1, s3)
        XCTAssertEqual(Set(s1).count, 200, "no file twice")
        XCTAssertFalse(s1.contains("f10"), "a changed file is not in the sample")
        XCTAssertTrue(Set(s1).isSubset(of: Set(ReturnCheck.unchanged(manifest: manifest, current: current))))
        XCTAssertEqual(s1, s1.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) })
        XCTAssertEqual(ReturnCheck.sample(manifest: manifest, current: manifest, limit: 5_000, seed: 1).count, 1000, "a small tree is sampled whole")
        XCTAssertEqual(ReturnCheck.sample(manifest: manifest, current: manifest, limit: 0, seed: 1), [])
        // the sample is spread over the tree, not just the first names
        XCTAssertTrue(s1.contains { Int($0.dropFirst()) ?? 0 > 800 })
    }

    func testTheListingResultFeedsTheDecision() {
        let manifest = manifestEntries()
        var current = manifest
        current[4].size = 1
        let result = ReturnCheck.listingResult(manifest: manifest, current: current, hashed: 200, hashMismatches: 0, fullCheck: false)
        XCTAssertFalse(result.quickPassed)
        XCTAssertEqual(result.mismatches, 1, "a size that differs with an unchanged time counts as a mismatch")
        XCTAssertEqual(result.sampleOf, 999)
        XCTAssertFalse(result.passed)
        let clean = ReturnCheck.listingResult(manifest: manifest, current: manifest, hashed: 200, hashMismatches: 0, fullCheck: false)
        XCTAssertTrue(clean.passed)
        XCTAssertEqual(ReturnReport(clean).sampled, 200)
        XCTAssertEqual(ReturnReport(clean).sampleOf, 1000)
    }
}
