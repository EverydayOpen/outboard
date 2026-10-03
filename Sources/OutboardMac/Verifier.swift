import CryptoKit
import Darwin
import Foundation
import OutboardCore

/// Why a verification did not produce "verified", and what it found.
struct VerifyFailure {
    var abort: AbortReason
    var message: String
    /// At most `Limits.firstDifferencesListed`.
    var differences: [Difference]
    var summary: VerificationSummary?
}

struct VerifyReport {
    var summary: VerificationSummary
    /// The source tree with every regular file's SHA-256: the manifest saved beside the sentinel.
    var manifest: [TreeEntry]
    /// When V3 last read the source. The W1 recheck reads it again if this was a while ago.
    var sourceWalkedAt: Date
}

enum VerifyOutcome {
    case verified(VerifyReport)
    case mismatch(VerifyFailure)
}

struct HashCheck {
    var hashed = 0
    var bytes: UInt64 = 0
    var mismatched: [String] = []
    var unreadable: [String] = []
    /// Paths left out because the byte budget ran out.
    var skippedForBudget = 0
    var cancelled = false
}

/// The only file with a hash (CryptoKit, SHA-256) and the only reader of file contents other than the journal and our own small
/// files. A copy is "verified" only when every file's size and SHA-256 match, the trees match in every other way Core compares,
/// and the source did not change while it was being copied. The destination is read with the page cache off (`F_NOCACHE`), so
/// the drive answers, not our own cache.
enum Verifier {
    /// Extended attributes the system adds by itself and cannot copy. Left out of the comparison on both sides (VERIFY on a Mac).
    static let ignoredXattrs: Set<String> = ["com.apple.provenance", "com.apple.macl"]

    // MARK: - Hashing

    /// Lowercase hex SHA-256 of the file's bytes. `noCache` bypasses the page cache for this descriptor. The file is opened with
    /// O_NOFOLLOW, so a link swapped in after the walk fails instead of being read.
    static func hashFile(_ path: String, noCache: Bool, isCancelled: () -> Bool = { false }) -> (hex: String?, errno: Int32) {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return (nil, errno) }
        defer { close(fd) }
        if noCache { _ = fcntl(fd, F_NOCACHE, 1) }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: Limits.hashChunkBytes)
        while true {
            if isCancelled() { return (nil, ECANCELED) }
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                return (nil, errno)
            }
            if n == 0 { break }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0.prefix(n))) }
        }
        return (hex(hasher.finalize()), 0)
    }

    static func sha256Hex(of text: String) -> String { hex(SHA256.hash(data: Data(text.utf8))) }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        let digits = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        for byte in digest {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: - Verifying a copy

    /// V1 to V3 over two folders. `startManifest` is the source walk taken right before the copy began (Manifest A).
    /// `progress(filesDone, filesTotal, bytesDone)` is called as files are hashed.
    static func verify(sourceRoot: String, destinationRoot: String, startManifest: [TreeEntry], isCancelled: () -> Bool,
                       progress: (Int, Int, UInt64) -> Void) -> VerifyOutcome {
        // V1: walk both trees (type, size, mode, link target, extended attribute names and sizes).
        guard let src = SizeScanner.walk(sourceRoot), src.isComplete else {
            return .mismatch(VerifyFailure(abort: .copyFailed, message: "The folder on your Mac could not be read end to end.", differences: [], summary: nil))
        }
        guard let dst = SizeScanner.walk(destinationRoot), dst.isComplete else {
            return .mismatch(VerifyFailure(abort: .copyFailed, message: "The copy on the drive could not be read end to end.", differences: [], summary: nil))
        }
        var sourceEntries = normalized(src.entries)
        var destinationEntries = normalized(dst.entries)
        let linked = TreeCompare.hardLinkedCopiedSeparately(source: sourceEntries, destination: destinationEntries)
        // Hard-link groups do not survive a copy across volumes; they are compared by content and reported, not as differences.
        sourceEntries = sourceEntries.map { var e = $0; e.hardLinkGroup = nil; return e }
        destinationEntries = destinationEntries.map { var e = $0; e.hardLinkGroup = nil; return e }

        // V2: SHA-256 of every regular file on both sides; the destination is read uncached.
        let files = sourceEntries.indices.filter { sourceEntries[$0].type == .file }
        let destinationIndex = Dictionary(uniqueKeysWithValues: destinationEntries.indices.map { (destinationEntries[$0].path, $0) })
        var unreadable: [Difference] = []
        var bytes: UInt64 = 0
        for (n, i) in files.enumerated() {
            if isCancelled() {
                return .mismatch(VerifyFailure(abort: .userCancelled, message: "Stopped. Nothing on your Mac was changed.", differences: [], summary: nil))
            }
            progress(n, files.count, bytes)
            let path = sourceEntries[i].path
            let s = hashFile(sourceRoot + "/" + path, noCache: false, isCancelled: isCancelled)
            guard let sourceHash = s.hex else {
                if s.errno == ECANCELED {
                    return .mismatch(VerifyFailure(abort: .userCancelled, message: "Stopped. Nothing on your Mac was changed.", differences: [], summary: nil))
                }
                unreadable.append(Difference(path: path, kind: .unreadable, detail: "error \(s.errno)"))
                continue
            }
            sourceEntries[i].sha256 = sourceHash
            bytes += sourceEntries[i].size
            // A file that is missing or has another size on the drive is reported by the comparison; hashing it adds nothing.
            guard let j = destinationIndex[path], destinationEntries[j].type == .file, destinationEntries[j].size == sourceEntries[i].size else { continue }
            let d = hashFile(destinationRoot + "/" + path, noCache: true, isCancelled: isCancelled)
            if let destinationHash = d.hex {
                destinationEntries[j].sha256 = destinationHash
            } else if d.errno == ECANCELED {
                return .mismatch(VerifyFailure(abort: .userCancelled, message: "Stopped. Nothing on your Mac was changed.", differences: [], summary: nil))
            } else {
                unreadable.append(Difference(path: path, kind: .unreadable, detail: "error \(d.errno) on the drive"))
            }
        }
        progress(files.count, files.count, bytes)

        // V3 comes before the verdict: if the source changed while it was copied, the differences are not the copy's fault, and the
        // answer is "quit the app and start again", not "the copy is wrong".
        guard let again = SizeScanner.walk(sourceRoot) else {
            return .mismatch(VerifyFailure(abort: .sourceChanged, message: "The folder on your Mac changed while it was copied.", differences: [], summary: nil))
        }
        let sourceWalkedAt = Date()
        let changed = TreeCompare.changedDuringCopy(start: normalized(startManifest).map(strippingGroup), now: normalized(again.entries).map(strippingGroup),
                                                    limit: Limits.firstDifferencesListed)
        if !changed.isEmpty {
            return .mismatch(VerifyFailure(abort: .sourceChanged, message: "The folder on your Mac changed while it was copied. Quit the app and start again.",
                                           differences: changed, summary: nil))
        }

        var differences = TreeCompare.compare(source: sourceEntries, destination: destinationEntries, limit: Limits.firstDifferencesListed)
        differences += unreadable
        if !differences.isEmpty {
            let shown = Array(differences.prefix(Limits.firstDifferencesListed))
            return .mismatch(VerifyFailure(abort: .mismatch, message: "The copy does not match the original. Nothing on your Mac was changed.",
                                           differences: shown, summary: nil))
        }

        let digest = sha256Hex(of: TreeCompare.manifestText(sourceEntries))
        let symlinks = sourceEntries.filter { $0.type == .symlink }.count
        let summary = VerificationSummary(filesCompared: files.count, bytesCompared: bytes, symlinksCompared: symlinks, differences: 0,
                                          hardLinkedCopiedSeparately: linked, destinationReadUncached: true, manifestDigest: digest,
                                          completedAt: Date())
        return .verified(VerifyReport(summary: summary, manifest: sourceEntries, sourceWalkedAt: sourceWalkedAt))
    }

    private static func normalized(_ entries: [TreeEntry]) -> [TreeEntry] {
        entries.map { entry in
            var e = entry
            e.xattrs = e.xattrs.filter { !ignoredXattrs.contains($0.name) }
            return e
        }
    }

    private static func strippingGroup(_ entry: TreeEntry) -> TreeEntry {
        var e = entry
        e.hardLinkGroup = nil
        return e
    }

    // MARK: - Hashing a chosen set again (the return sample, "Check and reconnect")

    /// Hashes `paths` (relative to `root`) and compares each with the manifest's SHA-256. `byteBudget` stops a sample of very large
    /// files from reading hundreds of gigabytes; what was left out is counted in `skippedForBudget`.
    static func compareHashes(root: String, manifest: [TreeEntry], paths: [String], byteBudget: UInt64?, isCancelled: () -> Bool,
                              progress: (Int, Int) -> Void) -> HashCheck {
        let wanted = Dictionary(manifest.compactMap { e in e.sha256.map { (e.path, ($0, e.size)) } }, uniquingKeysWith: { first, _ in first })
        var out = HashCheck()
        for (n, path) in paths.enumerated() {
            if isCancelled() {
                out.cancelled = true
                break
            }
            progress(n, paths.count)
            guard let (expected, size) = wanted[path] else { continue }
            if let budget = byteBudget, out.bytes + size > budget, out.hashed > 0 {
                out.skippedForBudget += 1
                continue
            }
            let r = hashFile(root + "/" + path, noCache: true, isCancelled: isCancelled)
            if let hex = r.hex {
                out.hashed += 1
                out.bytes += size
                if hex != expected { out.mismatched.append(path) }
            } else if r.errno == ECANCELED {
                out.cancelled = true
                break
            } else {
                out.unreadable.append(path)
            }
        }
        progress(paths.count, paths.count)
        return out
    }
}
