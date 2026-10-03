import Foundation

// Types that cross the Core / Mac line: the facts the Mac layer reads from the system (URLResourceValues, read-only diskutil and
// tmutil output parsed by Core `Parsers`), and the small JSON files Outboard writes on a drive. Core parses and decides; Mac reads
// and writes. Every key name that comes from a system tool is VERIFY on macOS 15 and 26 (BUILD_PLAN §12).

// MARK: - Facts read from the system

/// What `URLResourceValues` says about a mounted volume. Optional means "the key was not available", which Core treats as unknown.
public struct ResourceFacts: Codable, Hashable, Sendable {
    public var uuid: String?
    public var name: String
    public var mountPoint: String
    public var isLocal: Bool?
    public var isInternal: Bool?
    public var isReadOnly: Bool?
    public var isEjectable: Bool?
    public var isRemovable: Bool?
    public var supportsSymlinks: Bool?
    public var supportsHardLinks: Bool?
    public var isCaseSensitive: Bool?
    /// `volumeAvailableCapacityForImportantUsage`
    public var availableBytes: UInt64?
    public var totalBytes: UInt64?
    /// `volumeLocalizedFormatDescription`, for diagnostics.
    public var formatDescription: String?

    public init(uuid: String?, name: String, mountPoint: String, isLocal: Bool? = nil, isInternal: Bool? = nil, isReadOnly: Bool? = nil,
                isEjectable: Bool? = nil, isRemovable: Bool? = nil, supportsSymlinks: Bool? = nil, supportsHardLinks: Bool? = nil,
                isCaseSensitive: Bool? = nil, availableBytes: UInt64? = nil, totalBytes: UInt64? = nil, formatDescription: String? = nil) {
        self.uuid = uuid
        self.name = name
        self.mountPoint = mountPoint
        self.isLocal = isLocal
        self.isInternal = isInternal
        self.isReadOnly = isReadOnly
        self.isEjectable = isEjectable
        self.isRemovable = isRemovable
        self.supportsSymlinks = supportsSymlinks
        self.supportsHardLinks = supportsHardLinks
        self.isCaseSensitive = isCaseSensitive
        self.availableBytes = availableBytes
        self.totalBytes = totalBytes
        self.formatDescription = formatDescription
    }
}

/// `diskutil info -plist <mount>` as parsed by Core `Parsers.diskutilInfo`. Key names VERIFY.
public struct DiskutilInfo: Codable, Hashable, Sendable {
    public var deviceIdentifier: String?
    public var volumeUUID: String?
    public var volumeName: String?
    public var mountPoint: String?
    /// `FilesystemType`: apfs, hfs, exfat, msdos, ntfs ...
    public var filesystemType: String?
    public var busProtocol: String?
    public var isInternal: Tri
    public var isSolidState: Tri
    public var isWritable: Tri
    public var isEncrypted: Tri
    public var isLocked: Tri
    public var smart: SmartStatus
    /// False when the volume is set to ignore ownership. Key name VERIFY.
    public var ownershipHonoured: Tri
    public var totalSize: UInt64?
    public var parentWholeDisk: String?
    public var apfsPhysicalStores: [String]
    public var apfsContainerReference: String?

    public init(deviceIdentifier: String? = nil, volumeUUID: String? = nil, volumeName: String? = nil, mountPoint: String? = nil,
                filesystemType: String? = nil, busProtocol: String? = nil, isInternal: Tri = .unknown, isSolidState: Tri = .unknown,
                isWritable: Tri = .unknown, isEncrypted: Tri = .unknown, isLocked: Tri = .unknown, smart: SmartStatus = .unknown,
                ownershipHonoured: Tri = .unknown, totalSize: UInt64? = nil, parentWholeDisk: String? = nil,
                apfsPhysicalStores: [String] = [], apfsContainerReference: String? = nil) {
        self.deviceIdentifier = deviceIdentifier
        self.volumeUUID = volumeUUID
        self.volumeName = volumeName
        self.mountPoint = mountPoint
        self.filesystemType = filesystemType
        self.busProtocol = busProtocol
        self.isInternal = isInternal
        self.isSolidState = isSolidState
        self.isWritable = isWritable
        self.isEncrypted = isEncrypted
        self.isLocked = isLocked
        self.smart = smart
        self.ownershipHonoured = ownershipHonoured
        self.totalSize = totalSize
        self.parentWholeDisk = parentWholeDisk
        self.apfsPhysicalStores = apfsPhysicalStores
        self.apfsContainerReference = apfsContainerReference
    }
}

/// One volume of `diskutil apfs list -plist` as parsed by Core `Parsers.apfsList`. Key names VERIFY.
public struct ApfsVolumeInfo: Codable, Hashable, Sendable {
    public var volumeUUID: String?
    public var containerReference: String?
    /// "Backup" marks a Time Machine volume (role `T`). Other roles are kept as text for diagnostics.
    public var roles: [String]
    public var isEncrypted: Tri
    public var isLocked: Tri
    public var quotaBytes: UInt64?
    public var reserveBytes: UInt64?

    public init(volumeUUID: String? = nil, containerReference: String? = nil, roles: [String] = [], isEncrypted: Tri = .unknown,
                isLocked: Tri = .unknown, quotaBytes: UInt64? = nil, reserveBytes: UInt64? = nil) {
        self.volumeUUID = volumeUUID
        self.containerReference = containerReference
        self.roles = roles
        self.isEncrypted = isEncrypted
        self.isLocked = isLocked
        self.quotaBytes = quotaBytes
        self.reserveBytes = reserveBytes
    }

    public var isBackupRole: Bool { roles.contains { $0.lowercased() == "backup" || $0 == "T" } }
}

/// One destination of `tmutil destinationinfo -X` as parsed by Core `Parsers.tmutilDestinations`. Key names VERIFY.
public struct TimeMachineDestination: Codable, Hashable, Sendable {
    public var name: String?
    public var mountPoint: String?
    public var volumeUUID: String?

    public init(name: String? = nil, mountPoint: String? = nil, volumeUUID: String? = nil) {
        self.name = name
        self.mountPoint = mountPoint
        self.volumeUUID = volumeUUID
    }
}

// MARK: - Files Outboard writes on a drive

/// `/Volumes/<name>/Outboard/.outboard/volume.json`: what "Use this drive" writes, and nothing else. The UUID is the identity; the
/// token ties a relocation to this volume (a reformatted or cloned drive with the same UUID but another token is `Suspect`).
public struct VolumeMarker: Codable, Hashable, Sendable {
    public var schema: Int
    public var uuid: String
    public var token: String
    public var createdAt: Date
    public var appVersion: String

    public init(schema: Int = Limits.markerSchema, uuid: String, token: String, createdAt: Date, appVersion: String) {
        self.schema = schema
        self.uuid = uuid
        self.token = token
        self.createdAt = createdAt
        self.appVersion = appVersion
    }
}

/// `/Volumes/<name>/Outboard/<recipe-id>/.sentinel-<moveID>.json`, **beside** the data folder, never inside it. Identity on
/// return is the volume UUID plus this file plus the recorded root stamp; "the path exists" is never enough.
public struct Sentinel: Codable, Hashable, Sendable {
    public var schema: Int
    public var moveID: String
    public var recipeID: RecipeID
    public var volumeToken: String
    /// Relative to the mount point: `Outboard/<recipe-id>/<leaf>`.
    public var relativePath: String
    public var createdAt: Date

    public init(schema: Int = Limits.markerSchema, moveID: String, recipeID: RecipeID, volumeToken: String, relativePath: String, createdAt: Date) {
        self.schema = schema
        self.moveID = moveID
        self.recipeID = recipeID
        self.volumeToken = volumeToken
        self.relativePath = relativePath
        self.createdAt = createdAt
    }

    /// The sentinel found on the drive is the one this relocation expects (same move, same recipe, same volume token, same path).
    public static func matches(_ found: Sentinel?, moveID: String, recipeID: RecipeID, volumeToken: String, relativePath: String) -> Bool {
        guard let found else { return false }
        return found.moveID == moveID && found.recipeID == recipeID && found.volumeToken == volumeToken && found.relativePath == relativePath
    }
}

public struct XattrInfo: Codable, Hashable, Sendable {
    public var name: String
    public var size: UInt64

    public init(name: String, size: UInt64) {
        self.name = name
        self.size = size
    }
}

/// One entry of a tree walk, as the verifier and the manifest see it. `path` is relative to the walked folder.
public struct TreeEntry: Codable, Hashable, Sendable {
    public var path: String
    public var type: FileType
    public var size: UInt64
    public var mode: UInt16
    public var mtimeSeconds: Int64
    public var symlinkTarget: String?
    public var xattrs: [XattrInfo]
    /// Lowercase hex SHA-256 of a regular file's contents; nil for directories and links, and in a walk that did not hash.
    public var sha256: String?
    /// The inode, when the file has more than one name (a hard-link group); nil otherwise. Compared by group, not by number.
    public var hardLinkGroup: UInt64?

    public init(path: String, type: FileType, size: UInt64 = 0, mode: UInt16 = 0o644, mtimeSeconds: Int64 = 0, symlinkTarget: String? = nil,
                xattrs: [XattrInfo] = [], sha256: String? = nil, hardLinkGroup: UInt64? = nil) {
        self.path = path
        self.type = type
        self.size = size
        self.mode = mode
        self.mtimeSeconds = mtimeSeconds
        self.symlinkTarget = symlinkTarget
        self.xattrs = xattrs
        self.sha256 = sha256
        self.hardLinkGroup = hardLinkGroup
    }
}

/// The per-file manifest taken at copy time (path, size, mtime, SHA-256): kept in `~/Library/Application Support/Outboard/Manifests/`
/// and beside the sentinel on the drive, so the return sample and "Check and reconnect" have something to compare against.
public struct ManifestFile: Codable, Hashable, Sendable {
    public var schema: Int
    public var moveID: String
    public var recipeID: RecipeID
    public var createdAt: Date
    public var entries: [TreeEntry]
    /// SHA-256 of `TreeCompare.manifestText(entries)`.
    public var digest: String

    public init(schema: Int = Limits.manifestSchema, moveID: String, recipeID: RecipeID, createdAt: Date, entries: [TreeEntry], digest: String) {
        self.schema = schema
        self.moveID = moveID
        self.recipeID = recipeID
        self.createdAt = createdAt
        self.entries = entries
        self.digest = digest
    }
}
