import Foundation
import OutboardCore

/// Who a volume is: its UUID, never its name or its path (invariant I7). A stale `/Volumes/<Name>` folder makes the real drive
/// mount as `<Name> 1`, so every question here is asked of the mount table. Reads only; nothing is cached.
enum VolumeIdentity {
    struct Mounted: Equatable {
        var uuid: String?
        var name: String
        var mountPoint: String
        var isReadOnly: Bool
    }

    private static let keys: [URLResourceKey] = [.volumeUUIDStringKey, .volumeNameKey, .volumeIsReadOnlyKey]

    /// Every mounted volume, hidden system volumes included. nil = the mount table could not be read (callers fail closed).
    static func all() -> [Mounted]? {
        guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: []) else { return nil }
        return urls.map { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            return Mounted(uuid: v?.volumeUUIDString, name: v?.volumeName ?? url.lastPathComponent, mountPoint: Fs.normalized(url.path),
                           isReadOnly: v?.volumeIsReadOnly ?? false)
        }
    }

    static func same(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return a.caseInsensitiveCompare(b) == .orderedSame
    }

    /// The volume with this UUID is mounted exactly at `mountPoint`.
    static func mounted(uuid: String, at mountPoint: String) -> Bool {
        guard let list = all() else { return false }
        let wanted = Fs.normalized(mountPoint)
        return list.contains { same($0.uuid, uuid) && $0.mountPoint == wanted }
    }

    static func matches(_ ref: VolumeRef, mountPoint: String) -> Bool {
        mounted(uuid: ref.uuid, at: mountPoint)
    }

    /// The drive is gone: no mounted volume has its UUID. If the mount table cannot be read this is **false** (never park on a guess).
    static func absent(_ ref: VolumeRef) -> Bool {
        guard let list = all() else { return false }
        return !list.contains { same($0.uuid, ref.uuid) }
    }

    /// Where the drive is mounted now, by UUID.
    static func currentMountPoint(of ref: VolumeRef) -> String? {
        all()?.first { same($0.uuid, ref.uuid) }?.mountPoint
    }

    static func mounted(_ ref: VolumeRef) -> Mounted? {
        all()?.first { same($0.uuid, ref.uuid) }
    }

    /// The UUID of the volume that `path` really lives on after following every link (the stale `/Volumes/<Name>` case).
    static func volumeUUID(ofResolved path: String) -> String? {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        return (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
    }

    /// Another mounted volume carries this name with a different UUID.
    static func sameNameDifferentDrive(_ ref: VolumeRef) -> Bool {
        guard let list = all() else { return false }
        return list.contains { $0.name == ref.name && !same($0.uuid, ref.uuid) }
    }
}
