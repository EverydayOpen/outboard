import Foundation

public enum FileType: String, Codable, Sendable {
    case file, directory, symlink, other
}

/// The identity of a filesystem object at one moment (BUILD_PLAN §3 invariants I1, I3). Taken with `lstat` (never followed),
/// recorded in the plan and the journal, and compared right before every verb acts. A directory's `size` is always 0: its size
/// changes as apps write, and the stamp never includes it.
public struct FileStamp: Codable, Hashable, Sendable {
    public var device: Int64
    public var inode: UInt64
    public var type: FileType
    public var size: UInt64
    public var mtimeSeconds: Int64
    public var mtimeNanoseconds: Int64
    public var linkCount: UInt32

    public init(device: Int64, inode: UInt64, type: FileType, size: UInt64 = 0, mtimeSeconds: Int64 = 0,
                mtimeNanoseconds: Int64 = 0, linkCount: UInt32 = 1) {
        self.device = device
        self.inode = inode
        self.type = type
        self.size = size
        self.mtimeSeconds = mtimeSeconds
        self.mtimeNanoseconds = mtimeNanoseconds
        self.linkCount = linkCount
    }

    public var mtime: Date { Date(timeIntervalSince1970: Double(mtimeSeconds) + Double(mtimeNanoseconds) / 1_000_000_000) }

    /// Same object: device, inode and type. A directory's mtime moves whenever an app adds a file, so the identity of a
    /// directory is not its mtime. For a file or a link, size and mtime must also match.
    public func isSameObject(as other: FileStamp) -> Bool {
        guard device == other.device, inode == other.inode, type == other.type else { return false }
        if type == .directory { return true }
        return size == other.size && mtimeSeconds == other.mtimeSeconds && mtimeNanoseconds == other.mtimeNanoseconds
    }
}

/// What a walk of a folder found: the unit the plan, the copy and the verifier agree on. Counts hard-linked files once.
public struct TreeFingerprint: Codable, Hashable, Sendable {
    public var files: Int
    public var directories: Int
    public var symlinks: Int
    /// Sum of regular-file sizes (logical bytes), hard-linked files counted once.
    public var logicalBytes: UInt64
    /// Sum of allocated bytes (`st_blocks * 512`), hard-linked files counted once.
    public var allocatedBytes: UInt64
    /// Regular files that are a second or later name for an inode already counted.
    public var hardLinkedFiles: Int
    /// Sockets, FIFOs, devices: any count above 0 refuses the move (preflight P6).
    public var specialFiles: Int
    /// Files the system reports as not stored locally (iCloud placeholders; `EDEADLK`): any count above 0 refuses (P5).
    public var datalessFiles: Int
    /// Files whose allocated size is much smaller than their length (sparse): refused in v1.
    public var sparseFiles: Int

    public init(files: Int = 0, directories: Int = 0, symlinks: Int = 0, logicalBytes: UInt64 = 0, allocatedBytes: UInt64 = 0,
                hardLinkedFiles: Int = 0, specialFiles: Int = 0, datalessFiles: Int = 0, sparseFiles: Int = 0) {
        self.files = files
        self.directories = directories
        self.symlinks = symlinks
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
        self.hardLinkedFiles = hardLinkedFiles
        self.specialFiles = specialFiles
        self.datalessFiles = datalessFiles
        self.sparseFiles = sparseFiles
    }

    public var entries: Int { files + directories + symlinks }
}
