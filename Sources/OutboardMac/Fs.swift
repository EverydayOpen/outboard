import Darwin
import Foundation
import OutboardCore

/// Small lstat/opendir helpers shared by the Mac layer. Nothing here follows a link, reads a file's contents or changes anything.
/// Written, not compiled (BUILD_PLAN §5): every Darwin name below is VERIFY until a macOS CI run.
enum Fs {
    // Values from <sys/stat.h>, spelled out (like Materialization) so we do not depend on how the C macros import. VERIFY each.
    static let datalessFlag: UInt32 = 0x4000_0000     // SF_DATALESS (iCloud placeholder)
    static let compressedFlag: UInt32 = 0x0000_0020   // UF_COMPRESSED (APFS/HFS transparent compression)
    static let pathLimit = 1024                       // PATH_MAX
    static let nameLimit = 255                        // NAME_MAX

    /// `lstat`: the item itself, never its target. `err == 0` means `st` is valid.
    static func info(_ path: String) -> (st: stat, err: Int32) {
        var st = stat()
        return lstat(path, &st) == 0 ? (st, 0) : (st, errno)
    }

    static func exists(_ path: String) -> Bool { info(path).err == 0 }

    static func kind(_ st: stat) -> FileType {
        switch st.st_mode & S_IFMT {
        case S_IFREG: return .file
        case S_IFDIR: return .directory
        case S_IFLNK: return .symlink
        default: return .other
        }
    }

    static func stamp(_ st: stat) -> FileStamp {
        let t = kind(st)
        return FileStamp(device: Int64(st.st_dev), inode: UInt64(st.st_ino), type: t, size: t == .directory ? 0 : UInt64(max(0, st.st_size)),
                         mtimeSeconds: Int64(st.st_mtimespec.tv_sec), mtimeNanoseconds: Int64(st.st_mtimespec.tv_nsec),
                         linkCount: UInt32(st.st_nlink))
    }

    /// The stamp of the item at `path` (never followed), nil when it cannot be looked at.
    static func stamp(of path: String) -> FileStamp? {
        let i = info(path)
        return i.err == 0 ? stamp(i.st) : nil
    }

    /// Allocated bytes (st_blocks * 512), the way Finder's "size on disk" counts. A dataless placeholder is 0.
    static func allocated(_ st: stat) -> UInt64 { UInt64(max(0, st.st_blocks)) * 512 }

    static func parent(of path: String) -> String { (path as NSString).deletingLastPathComponent }
    static func leaf(of path: String) -> String { (path as NSString).lastPathComponent }

    /// Removes a trailing slash (except for "/"), so two spellings of one path compare equal.
    static func normalized(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// Fixed-size C char arrays (d_name, f_mntonname) import as tuples.
    static func string<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in raw.bindMemory(to: CChar.self).baseAddress.map { String(cString: $0) } ?? "" }
    }

    /// Entry names of one folder (no "." or ".."), sorted. `err` is the errno of `opendir` (ENOENT = absent, EPERM/EACCES = protected).
    static func names(in path: String) -> (names: [String], err: Int32) {
        guard let dir = opendir(path) else { return ([], errno) }
        defer { closedir(dir) }
        var out: [String] = []
        while let ent = readdir(dir) {
            let name = string(ent.pointee.d_name)
            if name == "." || name == ".." { continue }
            out.append(name)
        }
        return (out.sorted(), 0)
    }

    /// Mount point of the volume holding `path` (`statfs`); nil when it cannot be told.
    static func mountPoint(of path: String) -> String? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        return string(fs.f_mntonname)
    }

    /// `st_dev` of the item holding `path` (followed), nil when it cannot be told.
    static func device(of path: String) -> Int64? {
        var st = stat()
        return stat(path, &st) == 0 ? Int64(st.st_dev) : nil
    }

    /// The volume holding `path` is a local one (not smb, nfs, afp, webdav). nil = cannot be told.
    static func isLocalVolume(_ path: String) -> Bool? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        return (fs.f_flags & UInt32(MNT_LOCAL)) != 0
    }

    /// The errno of a `stat` that follows links: 0 when the target is reachable.
    static func targetErrno(_ path: String) -> Int32 {
        var st = stat()
        return stat(path, &st) == 0 ? 0 : errno
    }

    /// Where a symbolic link points (never resolved further); nil when `path` is not a link.
    static func linkTarget(_ path: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: path)
    }

    /// The errno behind a Foundation error (FileManager reports Cocoa codes with a POSIX error underneath, or none).
    static func posix(_ error: Error) -> Int32? {
        let e = error as NSError
        if e.domain == NSPOSIXErrorDomain { return Int32(e.code) }
        if let u = e.userInfo[NSUnderlyingErrorKey] as? NSError, u.domain == NSPOSIXErrorDomain { return Int32(u.code) }
        guard e.domain == NSCocoaErrorDomain else { return nil }
        switch e.code {
        case 257, 513: return EACCES      // NSFileReadNoPermissionError, NSFileWriteNoPermissionError
        case 4, 260: return ENOENT        // NSFileNoSuchFileError, NSFileReadNoSuchFileError
        case 516: return EEXIST           // NSFileWriteFileExistsError
        case 640: return ENOSPC           // NSFileWriteOutOfSpaceError
        default: return nil
        }
    }

    /// `~`-relative text for the journal and the screens.
    static func tilde(_ path: String, home: String) -> String { PathText.tilde(path, home: home) }
    static func expand(_ path: String, home: String) -> String { PathText.expandTilde(path, home: home) }

    /// 0 when the folder can be opened for listing, else the errno. Nothing is read from it.
    static func openDirectoryErrno(_ path: String) -> Int32 {
        guard let dir = opendir(path) else { return errno }
        closedir(dir)
        return 0
    }

    /// `realpath` of `path` (every link followed); nil when it cannot be resolved, with the errno.
    static func resolved(_ path: String) -> (path: String?, err: Int32) {
        guard let p = realpath(path, nil) else { return (nil, errno) }
        defer { free(p) }
        return (String(cString: p), 0)
    }

    static let linkedParentText = "A folder above this one is a link that leads somewhere else, so Outboard did not touch it. Nothing was changed."

    /// Why the folders above `path` do not lead where the text says, nil when they do. The never-list and the sync check are lexical,
    /// so a parent that is a link (`~/.ollama` into iCloud Drive or a container) would walk round them. Every link in the parent chain
    /// is followed; the answer is nil only when that is the same place as the text names, the home folder counting as itself resolved
    /// (a home under a link still works). Otherwise the place it really leads to is judged by the never-list, so the person gets that
    /// wording, and any other detour is refused all the same. A parent that is not there (or is a dangling link) is nil: the act that
    /// follows fails by itself. The last part of `path` is not followed; its own kind is checked by the caller with `lstat`.
    static func ancestorProblem(_ path: String, home: String) -> String? {
        let lexical = normalized(parent(of: path))
        let found = resolved(lexical)
        guard let real = found.path else {
            return found.err == ENOENT || found.err == ENOTDIR ? nil : "A folder above this one could not be looked at (error \(found.err))."
        }
        let h = normalized(home)
        var expected = lexical
        if !h.isEmpty, h != "/", lexical == h || lexical.hasPrefix(h + "/") {
            expected = (resolved(h).path ?? h) + String(lexical.dropFirst(h.count))
        }
        func same(_ a: String, _ b: String) -> Bool {
            a.precomposedStringWithCanonicalMapping.caseInsensitiveCompare(b.precomposedStringWithCanonicalMapping) == .orderedSame
        }
        if same(real, expected) { return nil }
        let there = (real == "/" ? "" : real) + "/" + leaf(of: path)
        return NeverList.reason(forPath: there, home: resolved(h).path ?? h)?.text ?? linkedParentText
    }

    /// A real, plain directory: not a link, not a file.
    static func isPlainDirectory(_ path: String) -> Bool {
        let i = info(path)
        return i.err == 0 && kind(i.st) == .directory
    }
}
