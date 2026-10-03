import Foundation

/// The verified-copy comparison as pure functions over tree walks (BUILD_PLAN §4.4). The Mac `Verifier` walks and hashes both trees
/// and hands the entries here; any difference aborts the move. Equality here means "compared equal at that moment", never "intact".
///
/// What is compared: type, size, mode (not for links), link target (as text), extended attribute names and sizes, and the SHA-256 of
/// every regular file. What is not: modification times of the copy, and hard-link groups (a copy made file by file keeps no group, so
/// they are counted by `hardLinkedCopiedSeparately` and reported, not refused). The destination list must not contain Outboard's own
/// staging marker; the Mac layer removes it before calling.
public enum TreeCompare {
    public static func compare(source: [TreeEntry], destination: [TreeEntry], limit: Int) -> [Difference] {
        Array(allDifferences(source: source, destination: destination).prefix(max(0, limit)))
    }

    /// How many differences there are in all (`compare` lists only the first `limit`).
    public static func totalDifferences(source: [TreeEntry], destination: [TreeEntry]) -> Int {
        allDifferences(source: source, destination: destination).count
    }

    /// V3: the source changed after the manifest was taken at copy start. Directory times are not compared (an app adding a file moves
    /// them); an added or removed path is.
    public static func changedDuringCopy(start: [TreeEntry], now: [TreeEntry], limit: Int) -> [Difference] {
        let startMap = index(start), nowMap = index(now)
        var out: [Difference] = []
        for (path, s) in startMap {
            guard let n = nowMap[path] else {
                out.append(Difference(path: path, kind: .changedDuringCopy, detail: "removed while copying"))
                continue
            }
            if s.type != n.type {
                out.append(Difference(path: path, kind: .changedDuringCopy, detail: "changed type while copying"))
            } else if s.type == .file, s.size != n.size || s.mtimeSeconds != n.mtimeSeconds {
                out.append(Difference(path: path, kind: .changedDuringCopy, detail: "changed while copying"))
            } else if s.type == .symlink, s.symlinkTarget != n.symlinkTarget {
                out.append(Difference(path: path, kind: .changedDuringCopy, detail: "link changed while copying"))
            } else if s.type != .symlink, s.mode & 0o7777 != n.mode & 0o7777 {
                out.append(Difference(path: path, kind: .changedDuringCopy, detail: "permissions changed while copying"))
            }
        }
        for path in nowMap.keys where startMap[path] == nil {
            out.append(Difference(path: path, kind: .changedDuringCopy, detail: "added while copying"))
        }
        return Array(sorted(out).prefix(max(0, limit)))
    }

    /// Files that were hard-linked together on the source and are separate files on the destination ("N hard-linked files were copied
    /// as separate files").
    public static func hardLinkedCopiedSeparately(source: [TreeEntry], destination: [TreeEntry]) -> Int {
        let destMap = index(destination)
        var groups: [UInt64: [String]] = [:]
        for e in source where e.type == .file { if let g = e.hardLinkGroup { groups[g, default: []].append(e.path) } }
        var separate = 0
        for (_, paths) in groups where paths.count >= 2 {
            let destGroups = paths.compactMap { destMap[$0]?.hardLinkGroup }
            let preserved = destGroups.count == paths.count && Set(destGroups).count == 1
            if !preserved { separate += paths.count }
        }
        return separate
    }

    /// Sorted `relativePath NUL field NL`, hashed by the Mac layer for `ManifestFile.digest`. The field is the SHA-256 of a regular
    /// file, `dir` for a directory and `link:<target>` for a link, so the digest covers the structure too.
    public static func manifestText(_ entries: [TreeEntry]) -> String {
        let sortedEntries = entries.sorted { Array($0.path.utf8).lexicographicallyPrecedes(Array($1.path.utf8)) }
        var out = ""
        for e in sortedEntries {
            let field: String
            switch e.type {
            case .file: field = e.sha256 ?? ""
            case .directory: field = "dir"
            case .symlink: field = "link:" + (e.symlinkTarget ?? "")
            case .other: field = "other"
            }
            out += e.path + "\u{0}" + field + "\n"
        }
        return out
    }

    // MARK: - Internals

    private static func index(_ entries: [TreeEntry]) -> [String: TreeEntry] {
        var map: [String: TreeEntry] = [:]
        map.reserveCapacity(entries.count)
        for e in entries { map[e.path] = e }
        return map
    }

    private static let kindOrder: [DifferenceKind] = [.missingOnDrive, .extraOnDrive, .typeDiffers, .sizeDiffers, .hashDiffers, .unreadable,
                                                       .modeDiffers, .symlinkTargetDiffers, .xattrDiffers, .changedDuringCopy]

    private static func sorted(_ list: [Difference]) -> [Difference] {
        list.sorted { a, b in
            if a.path != b.path { return Array(a.path.utf8).lexicographicallyPrecedes(Array(b.path.utf8)) }
            return (kindOrder.firstIndex(of: a.kind) ?? 99) < (kindOrder.firstIndex(of: b.kind) ?? 99)
        }
    }

    private static func xattrSignature(_ e: TreeEntry) -> [String] {
        e.xattrs.map { "\($0.name)=\($0.size)" }.sorted()
    }

    private static func allDifferences(source: [TreeEntry], destination: [TreeEntry]) -> [Difference] {
        let destMap = index(destination)
        let sourceMap = index(source)
        var out: [Difference] = []
        for s in source {
            guard let d = destMap[s.path] else {
                out.append(Difference(path: s.path, kind: .missingOnDrive, detail: "not on the drive"))
                continue
            }
            if s.type != d.type {
                out.append(Difference(path: s.path, kind: .typeDiffers, detail: "\(s.type.rawValue) on the Mac, \(d.type.rawValue) on the drive"))
                continue
            }
            switch s.type {
            case .file:
                if s.size != d.size {
                    out.append(Difference(path: s.path, kind: .sizeDiffers, detail: "\(Format.bytes(s.size)) on the Mac, \(Format.bytes(d.size)) on the drive"))
                } else if let a = s.sha256, let b = d.sha256 {
                    if a != b { out.append(Difference(path: s.path, kind: .hashDiffers, detail: "the contents differ")) }
                } else {
                    out.append(Difference(path: s.path, kind: .unreadable, detail: "not hashed on one side"))
                }
            case .symlink:
                if s.symlinkTarget != d.symlinkTarget {
                    out.append(Difference(path: s.path, kind: .symlinkTargetDiffers, detail: "the link points somewhere else"))
                }
            case .directory:
                break
            case .other:
                out.append(Difference(path: s.path, kind: .unreadable, detail: "a special file cannot be compared"))
            }
            if s.type != .symlink, s.mode & 0o7777 != d.mode & 0o7777 {
                out.append(Difference(path: s.path, kind: .modeDiffers, detail: "permissions differ"))
            }
            if xattrSignature(s) != xattrSignature(d) {
                out.append(Difference(path: s.path, kind: .xattrDiffers, detail: "extended attributes differ"))
            }
        }
        for d in destination where sourceMap[d.path] == nil {
            out.append(Difference(path: d.path, kind: .extraOnDrive, detail: "only on the drive"))
        }
        return sorted(out)
    }
}
