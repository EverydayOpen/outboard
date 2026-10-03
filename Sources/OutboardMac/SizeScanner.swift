import Darwin
import Foundation
import OutboardCore

/// Measures folders with `lstat` and `readdir` only: it never opens a file, never follows a link, never crosses onto another
/// device and performs no mutating verb (a Mac test proves it). Hard-linked files add their size once per name to `logicalBytes` (a copy
/// writes each name as a separate file) and their allocated space once per inode. `EPERM` on a folder macOS
/// protects is "needs Full Disk Access", not a failure; `EDEADLK`-style dataless files are counted, never read.
enum SizeScanner {
    struct WalkResult {
        var fingerprint: TreeFingerprint
        /// Sorted by path, paths relative to the walked folder; hashes are nil (the Verifier fills them).
        var entries: [TreeEntry]
        /// The first error met anywhere in the tree (0 = none); `rootErrno` is the root folder itself.
        var firstErrno: Int32
        var rootErrno: Int32
        var innerErrors: Int
        /// The time budget cut the walk: every number is a floor.
        var truncated: Bool

        var isComplete: Bool { !truncated && innerErrors == 0 && rootErrno == 0 }
    }

    private struct InodeKey: Hashable {
        var device: Int64
        var inode: UInt64
    }

    /// A file much smaller on disk than in length, not transparently compressed: a hole-y file (a disk image). Refused in v1.
    static func isSparse(_ st: stat) -> Bool {
        guard (st.st_flags & Fs.compressedFlag) == 0, st.st_size >= 1 << 20 else { return false }
        return Fs.allocated(st) * 2 < UInt64(st.st_size)
    }

    // MARK: - Sizing the catalogue

    /// One `SizeScan` per source folder of each recipe (companions included). Guided entries are measured too.
    /// `redirected` answers, for a `defaults` recipe, where its setting already points (nil = not redirected).
    static func measure(_ recipes: [Recipe], home: String, now: Date, budgetSeconds: Double = 30,
                        redirected: (Recipe) -> String? = { _ in nil }) -> [SizeScan] {
        var out: [SizeScan] = []
        for recipe in recipes {
            var paths: [String] = []
            if let source = recipe.source { paths.append(source) }
            paths += recipe.companionSources
            guard let first = paths.first else { continue }
            if let target = redirected(recipe) {
                out.append(SizeScan(recipeID: recipe.id, path: first, state: .notMeasured, reason: .alreadyRedirected,
                                    linkTarget: Fs.tilde(target, home: home), measuredAt: now))
                continue
            }
            for rel in paths { out.append(measureOne(recipe, rel, home: home, now: now, budget: budgetSeconds)) }
        }
        return out
    }

    private static func reason(for code: Int32, needsFDA: Bool) -> NotMeasuredReason {
        code == EPERM || code == EACCES ? (needsFDA ? .needsFullDiskAccess : .denied) : .failed
    }

    private static func measureOne(_ recipe: Recipe, _ rel: String, home: String, now: Date, budget: Double) -> SizeScan {
        let abs = Fs.expand(rel, home: home)
        let top = Fs.info(abs)
        if top.err == ENOENT || top.err == ENOTDIR {
            return SizeScan(recipeID: recipe.id, path: rel, state: .absent, measuredAt: now)
        }
        if top.err != 0 {
            return SizeScan(recipeID: recipe.id, path: rel, state: .notMeasured, reason: reason(for: top.err, needsFDA: recipe.needsFDA),
                            errnoCode: top.err, measuredAt: now)
        }
        let stamp = Fs.stamp(top.st)
        switch Fs.kind(top.st) {
        case .symlink:
            let target = Fs.linkTarget(abs).map { Fs.tilde($0, home: home) }
            return SizeScan(recipeID: recipe.id, path: rel, state: .notMeasured, reason: .alreadyRedirected, isLink: true,
                            linkTarget: target, stamp: stamp, measuredAt: now)
        case .directory:
            break
        default:
            return SizeScan(recipeID: recipe.id, path: rel, state: .notMeasured, reason: .failed, stamp: stamp, measuredAt: now)
        }
        guard let walked = walk(abs, xattrs: false, budgetSeconds: budget) else {
            return SizeScan(recipeID: recipe.id, path: rel, state: .notMeasured, reason: .failed, stamp: stamp, measuredAt: now)
        }
        if walked.rootErrno != 0 {
            return SizeScan(recipeID: recipe.id, path: rel, state: .notMeasured, reason: reason(for: walked.rootErrno, needsFDA: recipe.needsFDA),
                            errnoCode: walked.rootErrno, stamp: stamp, measuredAt: now)
        }
        let complete = walked.isComplete
        return SizeScan(recipeID: recipe.id, path: rel, state: complete ? .measured : .atLeast, fingerprint: walked.fingerprint,
                        errnoCode: walked.firstErrno == 0 ? nil : walked.firstErrno, stamp: stamp, measuredAt: now)
    }

    // MARK: - Walking one tree

    /// Walks the folder at `path` (a real directory, not a link): nil when it is not one. `xattrs` lists extended attribute names
    /// and sizes per entry (the verifier wants them, the size scan does not). `budgetSeconds` cuts a long walk short.
    static func walk(_ path: String, xattrs: Bool = true, budgetSeconds: Double? = nil) -> WalkResult? {
        let root = Fs.info(path)
        guard root.err == 0, Fs.kind(root.st) == .directory else { return nil }
        let rootDevice = root.st.st_dev
        var fingerprint = TreeFingerprint()
        var entries: [TreeEntry] = []
        var seen = Set<InodeKey>()
        var firstErrno: Int32 = 0
        var rootErrno: Int32 = 0
        var innerErrors = 0
        var truncated = false
        var visited = 0
        let deadline = budgetSeconds.map { Date().addingTimeInterval($0) }
        var stack: [(abs: String, rel: String)] = [(path, "")]

        func note(_ code: Int32) {
            innerErrors += 1
            if firstErrno == 0 { firstErrno = code }
        }

        walking: while let (dir, rel) = stack.popLast() {
            let listing = Fs.names(in: dir)
            if listing.err != 0 {
                if rel.isEmpty { rootErrno = listing.err }
                note(listing.err)
                continue
            }
            for name in listing.names {
                visited += 1
                if let deadline, visited % 256 == 0, Date() > deadline {
                    truncated = true
                    break walking
                }
                let abs = dir + "/" + name
                let relPath = rel.isEmpty ? name : rel + "/" + name
                let i = Fs.info(abs)
                if i.err != 0 {
                    note(i.err)
                    continue
                }
                let st = i.st
                switch Fs.kind(st) {
                case .directory:
                    if st.st_dev != rootDevice {
                        // A mount point inside the tree: not a plain folder, so the move is refused (preflight P6).
                        fingerprint.specialFiles += 1
                        entries.append(entry(.other, st, relPath, abs, link: nil, xattrs: false))
                        continue
                    }
                    fingerprint.directories += 1
                    entries.append(entry(.directory, st, relPath, abs, link: nil, xattrs: xattrs))
                    stack.append((abs, relPath))
                case .symlink:
                    fingerprint.symlinks += 1
                    entries.append(entry(.symlink, st, relPath, abs, link: Fs.linkTarget(abs), xattrs: xattrs))
                case .file:
                    fingerprint.files += 1
                    let linked = st.st_nlink > 1
                    var counted = true
                    if linked {
                        counted = seen.insert(InodeKey(device: Int64(st.st_dev), inode: UInt64(st.st_ino))).inserted
                        if !counted { fingerprint.hardLinkedFiles += 1 }
                    }
                    // The copy writes every name as its own file, so the bytes that land on the drive count each name; only the space
                    // the files take on this Mac's disk counts a hard-linked inode once.
                    fingerprint.logicalBytes += UInt64(max(0, st.st_size))
                    if counted { fingerprint.allocatedBytes += Fs.allocated(st) }
                    if (st.st_flags & Fs.datalessFlag) != 0 { fingerprint.datalessFiles += 1 }
                    if isSparse(st) { fingerprint.sparseFiles += 1 }
                    entries.append(entry(.file, st, relPath, abs, link: nil, xattrs: xattrs))
                case .other:
                    fingerprint.specialFiles += 1
                    entries.append(entry(.other, st, relPath, abs, link: nil, xattrs: false))
                }
            }
        }
        entries.sort { $0.path < $1.path }
        return WalkResult(fingerprint: fingerprint, entries: entries, firstErrno: firstErrno, rootErrno: rootErrno, innerErrors: innerErrors,
                          truncated: truncated)
    }

    private static func entry(_ type: FileType, _ st: stat, _ rel: String, _ abs: String, link: String?, xattrs: Bool) -> TreeEntry {
        TreeEntry(path: rel, type: type, size: type == .directory ? 0 : UInt64(max(0, st.st_size)), mode: UInt16(st.st_mode & 0o7777),
                  mtimeSeconds: Int64(st.st_mtimespec.tv_sec), symlinkTarget: link, xattrs: xattrs ? xattrList(abs) : [], sha256: nil,
                  hardLinkGroup: type == .file && st.st_nlink > 1 ? UInt64(st.st_ino) : nil)
    }

    /// Extended attribute names and sizes of the item itself (never a link's target), sorted by name.
    private static func xattrList(_ path: String) -> [XattrInfo] {
        let needed = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard needed > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: needed)
        let got = listxattr(path, &buffer, needed, XATTR_NOFOLLOW)
        guard got > 0 else { return [] }
        let names = buffer.prefix(got).split(separator: 0, omittingEmptySubsequences: true).map { part in
            String(decoding: part.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        return names.sorted().map { name in
            XattrInfo(name: name, size: UInt64(max(0, getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW))))
        }
    }
}
