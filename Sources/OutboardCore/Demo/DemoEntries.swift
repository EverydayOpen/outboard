import Foundation

/// Small synthetic trees for the compare steps of a demo move. The real verifier walks tens of thousands of files; the demo
/// feeds the real `TreeCompare` a few representative entries (files, folders, a link) so that a flipped hash, a file that changed
/// during the copy, and a clean run all go through the real comparison. The counts in the journal come from the folder's
/// fingerprint, not from these lists. Hashes are computed here (a stand-in, not SHA-256) and never written as literals.
enum DemoEntries {
    private static func filePaths(_ recipeID: RecipeID) -> [String] {
        switch recipeID {
        case "xcode-deriveddata", "xcode-archives":
            return ["Build/Products/Debug/Sample.app/Contents/MacOS/Sample", "Build/Products/Debug/Sample.app/Contents/Info.plist",
                    "Index.noindex/DataStore/v5/units/Sample.o", "ModuleCache.noindex/Foundation.pcm",
                    "ModuleCache.noindex/Session.modulevalidation", "Logs/Build/Latest.xcactivitylog",
                    "SourcePackages/checkouts/Package.swift", "info.plist"]
        case "ollama-models":
            return ["blobs/blob-0001", "blobs/blob-0002", "blobs/blob-0003", "manifests/registry/library/model/latest"]
        case "ios-device-backups":
            return ["backup-0001/Manifest.db", "backup-0001/Info.plist", "backup-0001/Status.plist", "backup-0001/ab/file-0001",
                    "backup-0001/cd/file-0002"]
        case "huggingface-hub-cache":
            return ["models--example--model/blobs/blob-0001", "models--example--model/refs/main", "models--example--model/snapshots/rev-1/config.json"]
        default:
            return ["data/file-0001", "data/file-0002", "data/file-0003", "data/index"]
        }
    }

    /// The source side. Sorted by path, folders included, with a symbolic link where the recipe's data has them.
    static func source(_ plan: MovePlan) -> [TreeEntry] {
        var out: [TreeEntry] = []
        var folders = Set<String>()
        for (i, path) in filePaths(plan.recipeID).enumerated() {
            let parts = path.split(separator: "/").map(String.init)
            var prefix = ""
            for part in parts.dropLast() {
                prefix = prefix.isEmpty ? part : prefix + "/" + part
                folders.insert(prefix)
            }
            out.append(TreeEntry(path: path, type: .file, size: 1_000_003 * UInt64(i + 1), mode: 0o644, mtimeSeconds: 1_790_000_000 + Int64(i) * 61,
                                 sha256: fingerprint(path)))
        }
        for f in folders { out.append(TreeEntry(path: f, type: .directory, mode: 0o755, mtimeSeconds: 1_790_000_000)) }
        if plan.sourceFingerprint.symlinks > 0 {
            out.append(TreeEntry(path: "latest", type: .symlink, size: 4, mode: 0o755, mtimeSeconds: 1_790_000_000, symlinkTarget: "data/index"))
        }
        return out.sorted { $0.path < $1.path }
    }

    /// The destination side of a copy that went wrong: one file's contents differ (the hash is not the source's).
    static func withFlippedFile(_ entries: [TreeEntry]) -> [TreeEntry] {
        var out = entries
        if let i = out.firstIndex(where: { $0.type == .file && $0.size >= 3_000_000 }) { out[i].sha256 = fingerprint(out[i].path + "!") }
        return out
    }

    /// The source a moment later, after an app wrote to one file: the copy-start manifest no longer matches it (V3).
    static func withChangedFile(_ entries: [TreeEntry]) -> [TreeEntry] {
        var out = entries
        if let i = out.firstIndex(where: { $0.type == .file }) {
            out[i].size += 4_096
            out[i].mtimeSeconds += 90
        }
        return out
    }

    /// The same list as it stands on the Mac later: a few files changed since the manifest was taken ("Check and reconnect").
    static func withEditedFiles(_ entries: [TreeEntry], count: Int) -> [TreeEntry] {
        var out = entries
        var left = count
        for i in out.indices where left > 0 && out[i].type == .file {
            out[i].size += 512
            out[i].mtimeSeconds += 30
            left -= 1
        }
        return out
    }

    /// A stable stand-in for a content hash: 64 lowercase hex characters from four FNV-1a passes. Computed, never a literal.
    static func fingerprint(_ text: String) -> String {
        (0..<4).map { pass in
            var h: UInt64 = 0xcbf29ce484222325 &+ UInt64(pass) &* 0x9e3779b97f4a7c15
            for b in text.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
            return hex16(h)
        }.joined()
    }

    /// The `ManifestFile.digest` / `VerificationSummary.manifestDigest` stand-in: clearly a demo value.
    static func digest(_ entries: [TreeEntry]) -> String {
        "demo-" + String(fingerprint(TreeCompare.manifestText(entries)).prefix(16))
    }

    private static func hex16(_ v: UInt64) -> String {
        let s = String(v, radix: 16)
        return String(repeating: "0", count: 16 - s.count) + s
    }
}
