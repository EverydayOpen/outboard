import Foundation
import OutboardCore

/// Extra drive facts that need a look at the volume's top level (names only; no file is opened). DiskArbitration is not used in
/// v1 (grep G6 keeps the name in this file only). Unknown stays unknown: a folder that cannot be listed is never "no".
enum Disks {
    /// Time Machine signal 3: `Backups.backupdb` or a `*.sparsebundle` at the volume root.
    static func backupFolderAtRoot(mountPoint: String) -> Tri {
        let listing = Fs.names(in: mountPoint)
        if listing.err != 0 { return .unknown }
        return listing.names.contains { $0 == "Backups.backupdb" || $0.hasSuffix(".sparsebundle") } ? .yes : .no
    }

    /// Time Machine info: another volume of the same APFS container is a backup volume (role `T`).
    static func siblingTimeMachine(in container: String?, ownUUID: String?, volumes: [ApfsVolumeInfo]) -> Bool {
        guard let container else { return false }
        return volumes.contains { $0.containerReference == container && $0.isBackupRole && !VolumeIdentity.same($0.volumeUUID, ownUUID) }
    }

    /// Time Machine signal 1: this volume's APFS role is Backup.
    static func apfsBackupRole(_ apfs: ApfsVolumeInfo?) -> Bool { apfs?.isBackupRole ?? false }
}
