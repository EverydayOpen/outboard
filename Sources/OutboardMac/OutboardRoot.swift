import Darwin
import Foundation
import OutboardCore

/// What Outboard keeps on a drive, and the only code that creates it: `Outboard/.outboard/volume.json` (the marker "Use this
/// drive" writes, and nothing else), `Outboard/<recipe-id>/` (the folder for a recipe), and the sentinel beside the data
/// (`.sentinel-<moveID>.json`, never inside it). Nothing is created under `/Volumes` before the volume's UUID is confirmed mounted
/// at that mount point (invariant I7, pinned).
enum OutboardRoot {
    private static let maxSmallFile: Int64 = 1 << 16

    static let driveFolderText = "The Outboard folder on this drive is a link, or is not a plain folder on the drive itself, so Outboard did not use it. Nothing was changed."

    /// `<mount>/Outboard` must be a real folder on the drive: `lstat` (a symbolic link is not followed), a directory, and on the same
    /// device as the mount point, so a drive that carries `Outboard` as a link, or another volume mounted over it, cannot send the
    /// marker, the copy or the check files somewhere else. When `path` (under the mount point) is given, it must also resolve to a
    /// place under the mount point; the deepest part of it that exists is resolved, because the folder may not be made yet. A missing
    /// `Outboard` passes: it is made as a real folder by the next step. Ownership is not tested: a drive mounted with "ignore
    /// ownership" reports every item as owned by the current user.
    static func driveFolderIsSound(mountPoint: String, path: String? = nil) -> Bool {
        let root = Fs.info(mountPoint)
        guard root.err == 0, Fs.kind(root.st) == .directory else { return false }
        let folder = Fs.info(mountPoint + "/" + Names.driveFolder)
        if folder.err == ENOENT { return path.map { staysUnder(mountPoint, $0) } ?? true }
        guard folder.err == 0, Fs.kind(folder.st) == .directory, folder.st.st_dev == root.st.st_dev else { return false }
        return path.map { staysUnder(mountPoint, $0) } ?? true
    }

    private static func staysUnder(_ mountPoint: String, _ path: String) -> Bool {
        guard let base = resolved(mountPoint) else { return false }
        var existing = path
        while !Fs.exists(existing) {
            let up = Fs.parent(of: existing)
            if up == existing || up.isEmpty { return false }
            existing = up
        }
        guard let real = resolved(existing) else { return false }
        return real == base || real.hasPrefix(base + "/")
    }

    private static func resolved(_ path: String) -> String? {
        guard let p = realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    static func markerPath(mountPoint: String) -> String {
        mountPoint + "/" + Names.driveFolder + "/" + Names.markerFolder + "/" + Names.markerFile
    }

    static func sentinelPath(mountPoint: String, relativePath: String, moveID: String) -> String {
        mountPoint + "/" + Fs.parent(of: relativePath) + "/" + Names.sentinelPrefix + moveID + Names.sentinelSuffix
    }

    /// One small regular file (not a link), at most 64 KB. Anything else reads as nothing.
    private static func smallFile(_ path: String) -> Data? {
        let i = Fs.info(path)
        guard i.err == 0, Fs.kind(i.st) == .file, Int64(i.st.st_size) <= maxSmallFile else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: path))
    }

    static func readMarker(mountPoint: String) -> VolumeMarker? {
        guard driveFolderIsSound(mountPoint: mountPoint) else { return nil }
        return smallFile(markerPath(mountPoint: mountPoint)).flatMap { Parsers.volumeMarker($0) }
    }

    static func readSentinel(_ ref: VolumeRef, relativePath: String, moveID: String, mountPoint: String) -> Sentinel? {
        guard driveFolderIsSound(mountPoint: mountPoint) else { return nil }
        return smallFile(sentinelPath(mountPoint: mountPoint, relativePath: relativePath, moveID: moveID)).flatMap { Parsers.sentinel($0) }
    }

    /// "Use this drive": the marker, once. An existing marker with this UUID is left exactly as it is (its token is the drive's
    /// identity). Nothing else is written, and nothing is formatted, erased, mounted or ejected.
    static func useDrive(_ drive: DriveFacts, appVersion: String, now: Date) -> UseDriveResult {
        guard let uuid = drive.uuid, VolumeIdentity.mounted(uuid: uuid, at: drive.mountPoint) else {
            return UseDriveResult(ok: false, message: Say.driveGone)
        }
        guard driveFolderIsSound(mountPoint: drive.mountPoint) else { return UseDriveResult(ok: false, message: driveFolderText) }
        if let existing = readMarker(mountPoint: drive.mountPoint) {
            return existing.uuid.caseInsensitiveCompare(uuid) == .orderedSame
                ? UseDriveResult(ok: true, message: "This is already your Outboard drive.")
                : UseDriveResult(ok: false, message: "This drive carries another drive's Outboard marker. Nothing was changed.")
        }
        let folder = drive.mountPoint + "/" + Names.driveFolder + "/" + Names.markerFolder
        let marker = VolumeMarker(uuid: uuid, token: randomToken(), createdAt: now.wholeSeconds, appVersion: appVersion)
        guard let data = Parsers.markerData(marker) else { return UseDriveResult(ok: false, message: "The marker could not be prepared.") }
        do {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        } catch {
            return UseDriveResult(ok: false, message: failureText(error))
        }
        let path = markerPath(mountPoint: drive.mountPoint)
        guard !Fs.exists(path), FileManager.default.createFile(atPath: path, contents: data) else {
            return UseDriveResult(ok: false, message: "The marker could not be written to the drive.")
        }
        return UseDriveResult(ok: true, message: "This drive is ready. Outboard wrote one small file on it: Outboard/.outboard/volume.json.")
    }

    /// `Outboard/<recipe-id>` on the plan's drive, after the same UUID check. Idempotent.
    static func ensureRecipeFolder(plan: MovePlan) -> Bool {
        let d = plan.destination
        guard VolumeIdentity.mounted(uuid: d.volumeUUID, at: d.mountPoint) else { return false }
        let folder = d.mountPoint + "/" + d.recipeFolder
        guard driveFolderIsSound(mountPoint: d.mountPoint, path: folder) else { return false }
        if !Fs.isPlainDirectory(folder) {
            guard !Fs.exists(folder), (try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)) != nil else { return false }
        }
        return recipeFolderIsOnDrive(plan)
    }

    /// `<mount>/Outboard/<recipe-id>` is a real folder (`lstat`, never a link) inside a sound `Outboard` folder, and, with every link
    /// followed, it lives on the plan's own volume by UUID. Asked after the folder is made and again by the copy, right before it starts.
    static func recipeFolderIsOnDrive(_ plan: MovePlan) -> Bool {
        let d = plan.destination
        let folder = d.mountPoint + "/" + d.recipeFolder
        guard driveFolderIsSound(mountPoint: d.mountPoint, path: folder), Fs.isPlainDirectory(folder) else { return false }
        return VolumeIdentity.same(VolumeIdentity.volumeUUID(ofResolved: folder), d.volumeUUID)
    }

    /// The sentinel for a published copy, beside it. Never overwrites.
    static func writeSentinel(plan: MovePlan, now: Date) -> Bool {
        let d = plan.destination
        let sentinel = Sentinel(moveID: plan.id, recipeID: plan.recipeID, volumeToken: d.volumeToken, relativePath: d.relativePath,
                                createdAt: now.wholeSeconds)
        guard let data = Parsers.sentinelData(sentinel) else { return false }
        let path = plan.sentinelPath
        return !Fs.exists(path) && FileManager.default.createFile(atPath: path, contents: data)
    }

    private static func randomToken() -> String {
        (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func failureText(_ error: Error) -> String {
        switch Fs.posix(error) {
        case EPERM?, EACCES?: return "macOS blocked access to the drive. Nothing was changed."
        case EROFS?: return "This drive is read-only. Nothing was changed."
        default: return "The drive could not be prepared. Nothing was changed."
        }
    }
}
