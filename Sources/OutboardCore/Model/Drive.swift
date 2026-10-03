import Foundation

/// The format of a volume, as `diskutil` / `URLResourceValues` name it. Anything unrecognised is `.other` and the raw string
/// travels in `DriveFacts.fileSystemRaw`. Key values are VERIFY on macOS 15 and 26 (APP6 §6.2 item 1).
public enum FileSystemKind: String, Codable, CaseIterable, Sendable {
    case apfs, hfsPlus, exfat, fat, ntfs, network, other

    public var displayName: String {
        switch self {
        case .apfs: return "APFS"
        case .hfsPlus: return "Mac OS Extended"
        case .exfat: return "exFAT"
        case .fat: return "FAT"
        case .ntfs: return "NTFS"
        case .network: return "Network"
        case .other: return "Unknown format"
        }
    }
}

/// How the drive is attached, as plain labels. USB generation is not in `diskutil` output as far as known (VERIFY); a
/// negotiated link speed, when IOKit can give it, travels in `DriveFacts.linkMegabitsPerSecond`.
public enum BusKind: String, Codable, CaseIterable, Sendable {
    case usb, thunderbolt, nvme, sata, sdCard, firewire, diskImage, network, internalBus, other, unknown

    public var displayName: String {
        switch self {
        case .usb: return "USB"
        case .thunderbolt: return "Thunderbolt"
        case .nvme: return "NVMe"
        case .sata: return "SATA"
        case .sdCard: return "SD card"
        case .firewire: return "FireWire"
        case .diskImage: return "Disk image"
        case .network: return "Network"
        case .internalBus: return "Internal"
        case .other: return "Other"
        case .unknown: return "Unknown"
        }
    }
}

/// SMART as macOS reports it. "Not Supported" is common over USB and is information, not a problem.
public enum SmartStatus: String, Codable, Sendable {
    case verified, failing, notSupported, unknown
}

/// The three Time Machine signals (APP6 §1.3 R10). The volume is refused when **any** says yes. When all three are unknown,
/// irreplaceable recipes refuse and the others ask for a tick.
public struct TimeMachineSignals: Codable, Hashable, Sendable {
    /// `diskutil apfs list -plist` role `T` (Backup) on a volume of this container.
    public var apfsBackupRole: Tri
    /// `tmutil destinationinfo -X` lists this volume's UUID or mount point.
    public var listedByTmutil: Tri
    /// `Backups.backupdb` or a `*.sparsebundle` at the volume root.
    public var backupFolderAtRoot: Tri

    public init(apfsBackupRole: Tri = .unknown, listedByTmutil: Tri = .unknown, backupFolderAtRoot: Tri = .unknown) {
        self.apfsBackupRole = apfsBackupRole
        self.listedByTmutil = listedByTmutil
        self.backupFolderAtRoot = backupFolderAtRoot
    }

    public var all: [Tri] { [apfsBackupRole, listedByTmutil, backupFolderAtRoot] }
    public var anyYes: Bool { all.contains(.yes) }
    public var allUnknown: Bool { all.allSatisfy { $0 == .unknown } }
    /// Yes if any signal says yes; no only if none says yes and at least one says no; otherwise unknown.
    public var verdict: Tri {
        if anyYes { return .yes }
        return all.contains(.no) ? .no : .unknown
    }
}

/// Everything the eligibility table reads about one mounted volume. The Mac layer gathers it once per evaluation from
/// `URLResourceValues` and read-only `diskutil` and never caches it across a move (E18). **A missing key never becomes
/// "eligible"**: it stays `unknown` / nil and Core decides (refuse for irreplaceable recipes, ask for a tick otherwise).
public struct DriveFacts: Codable, Hashable, Sendable, Identifiable {
    /// The volume UUID when there is one; otherwise `mount:<mountPoint>` so the list still has a stable row id.
    public var id: String
    /// The volume UUID string, nil when the system gave none (then E8 refuses).
    public var uuid: String?
    /// Display name as mounted ("Outboard", "Backup").
    public var name: String
    /// `/Volumes/Outboard`.
    public var mountPoint: String
    public var fileSystem: FileSystemKind
    /// `FilesystemType` / `volumeLocalizedFormatDescription` as reported, for diagnostics and the report.
    public var fileSystemRaw: String
    public var bus: BusKind
    /// `BusProtocol` as reported (diagnostics).
    public var busRaw: String
    /// `volumeIsLocal`. False for smb/nfs/afp/webdav shares.
    public var isLocal: Bool
    /// External only: the app tests "not internal", never Removable or Ejectable (Apple DTS).
    public var isInternal: Tri
    public var isWritable: Tri
    public var isSolidState: Tri
    /// APFS volume encryption (`FileVault` / `Encryption` keys, VERIFY).
    public var isEncrypted: Tri
    /// APFS volume is locked (treated as absent for writes, labelled "locked").
    public var isLocked: Bool
    /// False when the volume is set to ignore ownership (E9). Key name VERIFY.
    public var ownershipHonoured: Tri
    public var supportsSymlinks: Tri
    public var supportsHardLinks: Tri
    public var isCaseSensitive: Tri
    public var smart: SmartStatus
    public var timeMachine: TimeMachineSignals
    /// Another volume of the same APFS container is a Time Machine destination (Info only).
    public var timeMachineSiblingInContainer: Bool
    public var capacityBytes: UInt64
    /// `volumeAvailableCapacityForImportantUsage` (VERIFY it honours an APFS quota).
    public var availableBytes: UInt64?
    /// APFS quota from `apfs list`, when set.
    public var quotaBytes: UInt64?
    /// Negotiated link speed in megabits per second when IOKit can say (USB 2 is 480). nil = unknown, and nothing is claimed.
    public var linkMegabitsPerSecond: Int?
    /// The mount path or a parent is a sync folder or a File Provider volume (E13).
    public var isSyncedLocation: Bool
    /// Mounted exactly at `/Volumes/<name>` with no ` 1` suffix (E8, E14).
    public var isStandardMount: Bool
    /// How many mounted volumes share this display name (E8 refuses above 1).
    public var sameNameCount: Int
    /// `Outboard/.outboard/volume.json` exists with our schema (E17).
    public var hasOutboardMarker: Bool
    /// The marker's random token, when the marker was read.
    public var markerToken: String?

    public init(id: String? = nil, uuid: String?, name: String, mountPoint: String, fileSystem: FileSystemKind = .apfs,
                fileSystemRaw: String = "apfs", bus: BusKind = .usb, busRaw: String = "USB", isLocal: Bool = true,
                isInternal: Tri = .no, isWritable: Tri = .yes, isSolidState: Tri = .yes, isEncrypted: Tri = .unknown,
                isLocked: Bool = false, ownershipHonoured: Tri = .yes, supportsSymlinks: Tri = .yes, supportsHardLinks: Tri = .yes,
                isCaseSensitive: Tri = .no, smart: SmartStatus = .notSupported, timeMachine: TimeMachineSignals = TimeMachineSignals(apfsBackupRole: .no, listedByTmutil: .no, backupFolderAtRoot: .no),
                timeMachineSiblingInContainer: Bool = false, capacityBytes: UInt64 = 0, availableBytes: UInt64? = nil,
                quotaBytes: UInt64? = nil, linkMegabitsPerSecond: Int? = nil, isSyncedLocation: Bool = false,
                isStandardMount: Bool = true, sameNameCount: Int = 1, hasOutboardMarker: Bool = false, markerToken: String? = nil) {
        self.id = id ?? uuid ?? "mount:\(mountPoint)"
        self.uuid = uuid
        self.name = name
        self.mountPoint = mountPoint
        self.fileSystem = fileSystem
        self.fileSystemRaw = fileSystemRaw
        self.bus = bus
        self.busRaw = busRaw
        self.isLocal = isLocal
        self.isInternal = isInternal
        self.isWritable = isWritable
        self.isSolidState = isSolidState
        self.isEncrypted = isEncrypted
        self.isLocked = isLocked
        self.ownershipHonoured = ownershipHonoured
        self.supportsSymlinks = supportsSymlinks
        self.supportsHardLinks = supportsHardLinks
        self.isCaseSensitive = isCaseSensitive
        self.smart = smart
        self.timeMachine = timeMachine
        self.timeMachineSiblingInContainer = timeMachineSiblingInContainer
        self.capacityBytes = capacityBytes
        self.availableBytes = availableBytes
        self.quotaBytes = quotaBytes
        self.linkMegabitsPerSecond = linkMegabitsPerSecond
        self.isSyncedLocation = isSyncedLocation
        self.isStandardMount = isStandardMount
        self.sameNameCount = sameNameCount
        self.hasOutboardMarker = hasOutboardMarker
        self.markerToken = markerToken
    }
}

/// What the source tree needs from a destination, measured by the size scan and the preflight walk (E10, E11, E12).
public struct SourceNeeds: Codable, Hashable, Sendable {
    public var logicalBytes: UInt64
    public var isCaseSensitive: Tri
    public var hasHardLinks: Bool
    public var hasSymlinks: Bool

    public init(logicalBytes: UInt64, isCaseSensitive: Tri = .unknown, hasHardLinks: Bool = false, hasSymlinks: Bool = true) {
        self.logicalBytes = logicalBytes
        self.isCaseSensitive = isCaseSensitive
        self.hasHardLinks = hasHardLinks
        self.hasSymlinks = hasSymlinks
    }
}

/// What the app may build at runtime. `Policy.release` is the **only** value the shipping app constructs; `Policy.testing`
/// exists only under `#if DEBUG` (grep G14, G16). The initializer is internal on purpose: Mac and App code cannot invent a
/// laxer policy, only pick one of the two.
public struct Policy: Sendable, Equatable {
    /// Disk images count as drives (CI tests mount sparse images; the shipping app refuses them: E2).
    public let allowsDiskImages: Bool
    /// Treat every recipe as `verifiedOnRealMac` (tests and demo screenshots).
    public let treatsAllRecipesAsVerified: Bool

    init(allowsDiskImages: Bool, treatsAllRecipesAsVerified: Bool) {
        self.allowsDiskImages = allowsDiskImages
        self.treatsAllRecipesAsVerified = treatsAllRecipesAsVerified
    }

    public static let release = Policy(allowsDiskImages: false, treatsAllRecipesAsVerified: false)
    #if DEBUG
    public static let testing = Policy(allowsDiskImages: true, treatsAllRecipesAsVerified: true)
    #endif
}
