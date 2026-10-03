import Foundation

/// The pure merge of what the Mac layer read about one volume (`URLResourceValues`, read-only `diskutil` and `tmutil` output, the marker
/// file) into `DriveFacts`. No I/O. Every disagreement between sources resolves toward the stricter answer, and a missing key stays
/// `unknown`: it never becomes "eligible".
public enum DriveFactsBuilder {
    public static func build(resource: ResourceFacts, info: DiskutilInfo?, apfs: ApfsVolumeInfo?, tmDestinations: [TimeMachineDestination]?,
                             backupFolderAtRoot: Tri, siblingTimeMachineInContainer: Bool, marker: VolumeMarker?, sameNameCount: Int,
                             isSyncedLocation: Bool, linkMegabitsPerSecond: Int?) -> DriveFacts {
        let uuid = (resource.uuid ?? info?.volumeUUID).map { $0.uppercased() }.flatMap { $0.isEmpty ? nil : $0 }
        let mount = PathNorm.normalize(resource.mountPoint)
        let name = resource.name
        let fileSystem = fileSystemKind(info?.filesystemType, description: resource.formatDescription)
        let raw = info?.filesystemType ?? resource.formatDescription ?? ""

        // External: any "internal" answer wins; known disagreement is read as internal (the stricter answer).
        let isInternal: Tri = {
            let a = Tri(resource.isInternal), b = info?.isInternal ?? .unknown
            if a == .yes || b == .yes { return .yes }
            if a == .no && b == .no { return .no }
            if (a == .no && b == .unknown) || (a == .unknown && b == .no) { return .no }
            return .unknown
        }()
        let bus = busKind(info?.busProtocol, fileSystem: fileSystem, isInternal: isInternal)

        // Writable: any "not writable" answer wins.
        let isWritable: Tri = {
            let a: Tri = resource.isReadOnly.map { $0 ? .no : .yes } ?? .unknown
            let b = info?.isWritable ?? .unknown
            if a == .no || b == .no { return .no }
            if a == .yes || b == .yes { return .yes }
            return .unknown
        }()

        // Encryption: the APFS listing is the more specific source.
        let isEncrypted: Tri = {
            if let apfs, apfs.isEncrypted != .unknown { return apfs.isEncrypted }
            return info?.isEncrypted ?? .unknown
        }()
        let isLocked = (apfs?.isLocked == .yes) || (info?.isLocked == .yes)

        // Time Machine: three signals.
        let roleSignal: Tri = {
            if let apfs { return apfs.isBackupRole ? .yes : .no }
            return fileSystem == .apfs ? .unknown : .no
        }()
        let tmutilSignal: Tri = {
            guard let tmDestinations else { return .unknown }
            let byUUID = uuid.map { id in tmDestinations.contains { $0.volumeUUID?.uppercased() == id } } ?? false
            let byMount = tmDestinations.contains { ($0.mountPoint.map(PathNorm.normalize)) == mount }
            return byUUID || byMount ? .yes : .no
        }()

        // The marker belongs to this volume only if it names this UUID.
        let ownMarker: VolumeMarker? = {
            guard let marker, marker.schema == Limits.markerSchema, let uuid, marker.uuid.uppercased() == uuid else { return nil }
            return marker
        }()

        let components = PathNorm.components(mount)
        let standard = components.count == 2 && components[0] == "Volumes" && components[1] == name

        return DriveFacts(
            uuid: uuid, name: name, mountPoint: mount, fileSystem: fileSystem, fileSystemRaw: raw, bus: bus,
            busRaw: info?.busProtocol ?? "", isLocal: resource.isLocal ?? false, isInternal: isInternal, isWritable: isWritable,
            isSolidState: info?.isSolidState ?? .unknown, isEncrypted: isEncrypted, isLocked: isLocked,
            ownershipHonoured: info?.ownershipHonoured ?? .unknown, supportsSymlinks: Tri(resource.supportsSymlinks),
            supportsHardLinks: Tri(resource.supportsHardLinks), isCaseSensitive: Tri(resource.isCaseSensitive),
            smart: info?.smart ?? .unknown,
            timeMachine: TimeMachineSignals(apfsBackupRole: roleSignal, listedByTmutil: tmutilSignal, backupFolderAtRoot: backupFolderAtRoot),
            timeMachineSiblingInContainer: siblingTimeMachineInContainer, capacityBytes: resource.totalBytes ?? info?.totalSize ?? 0,
            availableBytes: resource.availableBytes, quotaBytes: apfs?.quotaBytes, linkMegabitsPerSecond: linkMegabitsPerSecond,
            isSyncedLocation: isSyncedLocation || NeverList.isSyncedPath(mount), isStandardMount: standard, sameNameCount: sameNameCount,
            hasOutboardMarker: ownMarker != nil, markerToken: ownMarker?.token)
    }

    /// `diskutil`'s `FilesystemType` first, then the localized description as a fallback. Anything else is `.other`.
    static func fileSystemKind(_ type: String?, description: String?) -> FileSystemKind {
        if let t = type?.lowercased(), !t.isEmpty {
            switch t {
            case "apfs": return .apfs
            case "hfs", "hfs+", "hfsx": return .hfsPlus
            case "exfat": return .exfat
            case "msdos", "fat", "fat32", "vfat", "fat16": return .fat
            case "ntfs", "ntfs-3g": return .ntfs
            case "smbfs", "nfs", "afpfs", "webdav", "cifs", "ftp": return .network
            default: break
            }
        }
        let d = (description ?? "").lowercased()
        if d.contains("apfs") { return .apfs }
        if d.contains("mac os extended") { return .hfsPlus }
        if d.contains("exfat") { return .exfat }
        if d.contains("ms-dos") || d.contains("fat") { return .fat }
        if d.contains("ntfs") { return .ntfs }
        if d.contains("smb") || d.contains("nfs") || d.contains("afp") || d.contains("webdav") { return .network }
        return .other
    }

    /// `BusProtocol` strings (VERIFY on a real USB and Thunderbolt drive).
    static func busKind(_ protocolName: String?, fileSystem: FileSystemKind, isInternal: Tri) -> BusKind {
        if fileSystem == .network { return .network }
        let p = (protocolName ?? "").lowercased()
        if p.isEmpty { return isInternal == .yes ? .internalBus : .unknown }
        if p.contains("disk image") { return .diskImage }
        if p.contains("usb") { return .usb }
        if p.contains("thunderbolt") { return .thunderbolt }
        if p.contains("digital") || p == "sd" || p.contains("sd card") { return .sdCard }
        if p.contains("firewire") { return .firewire }
        if p.contains("nvme") || p.contains("pci") || p.contains("apple fabric") { return .nvme }
        if p.contains("sata") || p.contains("ata") { return .sata }
        if p.contains("network") { return .network }
        return .other
    }
}
