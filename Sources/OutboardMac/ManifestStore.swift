import Darwin
import Foundation
import OutboardCore

/// The per-file manifest taken at copy time: `~/Library/Application Support/Outboard/Manifests/<moveID>.manifest.json` (0700
/// folder, 0600 file) and a copy beside the sentinel on the drive, so "Check and reconnect" and the return sample have something to
/// compare against. A manifest is written once and never rewritten; one that fails its own digest reads as missing.
enum ManifestStore {
    static func folder(home: String) -> String { Journal.directory(home: home) + "/" + Names.manifestFolder }

    static func fileName(moveID: String) -> String { moveID + Names.manifestFileSuffix }

    /// Writes the Mac copy and, when `driveFolder` is given, the drive copy, then reads each one back through the same reader `load` uses.
    /// False = a copy could not be written or does not read back intact (the move stops before anything on the Mac is renamed).
    /// A file that failed its read-back stays where it is: Outboard deletes nothing, and a move's id is never used twice.
    static func save(_ manifest: ManifestFile, home: String, driveFolder: URL?) -> Bool {
        guard Journal.prepare(home: home), let data = Parsers.manifestData(manifest) else { return false }
        let dir = folder(home: home)
        var st = stat()
        if lstat(dir, &st) != 0 {
            guard errno == ENOENT,
                  (try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: false,
                                                            attributes: [.posixPermissions: 0o700])) != nil else { return false }
        }
        guard Fs.isPlainDirectory(dir) else { return false }
        let name = fileName(moveID: manifest.moveID)
        guard !Fs.exists(dir + "/" + name),
              FileManager.default.createFile(atPath: dir + "/" + name, contents: data, attributes: [.posixPermissions: 0o600]),
              parsed(dir + "/" + name, moveID: manifest.moveID) != nil else { return false }
        if let driveFolder {
            let onDrive = driveFolder.appendingPathComponent(name).path
            guard !Fs.exists(onDrive), FileManager.default.createFile(atPath: onDrive, contents: data),
                  parsed(onDrive, moveID: manifest.moveID) != nil else { return false }
        }
        return true
    }

    /// The manifest of a move: the Mac copy, else the copy on the drive (`driveFolder`). nil when neither reads back intact.
    static func load(moveID: String, home: String, driveFolder: String? = nil) -> ManifestFile? {
        let name = fileName(moveID: moveID)
        var candidates = [folder(home: home) + "/" + name]
        if let driveFolder { candidates.append(driveFolder + "/" + name) }
        for path in candidates {
            if let manifest = parsed(path, moveID: moveID) { return manifest }
        }
        return nil
    }

    /// One reader for both directions: a regular file no larger than `Limits.maxManifestBytes` that parses, belongs to this move and
    /// matches its own digest.
    private static func parsed(_ path: String, moveID: String) -> ManifestFile? {
        let i = Fs.info(path)
        guard i.err == 0, Fs.kind(i.st) == .file, Int64(i.st.st_size) <= Int64(Limits.maxManifestBytes),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let manifest = Parsers.manifest(data), manifest.moveID == moveID else { return nil }
        return Verifier.sha256Hex(of: TreeCompare.manifestText(manifest.entries)) == manifest.digest ? manifest : nil
    }
}
