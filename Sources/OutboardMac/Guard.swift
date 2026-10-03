import Darwin
import Foundation
import OutboardCore

enum StampVerdict: Equatable {
    /// Still the object the stamp describes (or, with no stamp to compare, the object that is there now).
    case unchanged(FileStamp)
    case missing
    case changed(String)
    case unreadable(Int32)
}

enum RecheckVerdict: Equatable {
    case unchanged
    case changed(String)
}

/// What the comparison last saw of the source: its tree, and when V3 read it.
struct SourceSeen {
    var manifest: [TreeEntry]
    var at: Date
}

/// The Mac half of invariants I1 and I3 (BUILD_PLAN §5.1): re-reads the filesystem right now and caches nothing. Every verb asks
/// `verifyStamp` before it acts; the engine asks `recheck` at W1. Internal on purpose.
enum Guard {
    /// How old the comparison's read of the source may be before the W1 recheck reads it again.
    static let rewalkAfterSeconds: TimeInterval = 3

    /// Is the item at `path` still the object `expected` describes? `lstat`, never followed. With no `expected` the answer is the
    /// stamp of whatever is there (for items nobody recorded, like a folder an app created while a move ran).
    static func verifyStamp(path: String, expected: FileStamp?) -> StampVerdict {
        var st = stat()
        guard lstat(path, &st) == 0 else {
            let e = errno
            if e == ENOENT || e == ENOTDIR { return .missing }
            return .unreadable(e)
        }
        let found = Fs.stamp(st)
        guard let expected else { return .unchanged(found) }
        guard Int64(st.st_dev) == expected.device else { return .changed("It is on another volume than before.") }
        guard found.isSameObject(as: expected) else { return .changed("It is not the same item as before.") }
        return .unchanged(found)
    }

    /// W1: everything the swap leans on, read again. The source is still the object that was copied, the published copy is on the
    /// drive, the drive is the one in the plan and carries our sentinel, the original has not been renamed yet, the journal takes a
    /// line. Anything but `.unchanged` means nothing on the Mac is touched.
    ///
    /// A folder's stamp is its identity, not its contents, so when the comparison (`seen`) read the source more than a few seconds ago
    /// (the publish and the check files take their time on a big copy) the tree is read again and set against what the comparison
    /// saw: a file an app wrote since would otherwise exist only in `<name>.before-move`. Within those seconds the walk is skipped, so
    /// a small move costs nothing extra.
    static func recheck(_ plan: MovePlan, home: String, seen: SourceSeen? = nil) -> RecheckVerdict {
        switch verifyStamp(path: plan.sourcePath, expected: plan.sourceStamp) {
        case .unchanged: break
        case .missing: return .changed("The folder is gone.")
        case .changed(let why): return .changed(why)
        case .unreadable(let e): return .changed("The folder could not be looked at (error \(e)).")
        }
        if let seen, Date().timeIntervalSince(seen.at) > rewalkAfterSeconds {
            guard let now = SizeScanner.walk(plan.sourcePath, xattrs: false), now.isComplete else {
                return .changed("The folder on your Mac could not be read again.")
            }
            if !TreeCompare.changedDuringCopy(start: seen.manifest, now: now.entries, limit: 1).isEmpty {
                return .changed("The folder on your Mac changed after it was compared. Quit the app and start again.")
            }
        }
        if plan.direction == .toDrive, Fs.exists(plan.beforeMovePath) {
            return .changed("An earlier safety copy is still in the way.")
        }
        // A folder above the source may have become a link since the preflight.
        if plan.direction == .toDrive, let why = Fs.ancestorProblem(plan.sourcePath, home: home) { return .changed(why) }
        let d = plan.destination
        guard VolumeIdentity.mounted(uuid: d.volumeUUID, at: d.mountPoint) else { return .changed("The drive changed.") }
        guard OutboardRoot.driveFolderIsSound(mountPoint: d.mountPoint, path: d.finalPath) else { return .changed(OutboardRoot.driveFolderText) }
        guard Fs.isPlainDirectory(d.finalPath) else { return .changed("The copy on the drive is not there.") }
        let found = OutboardRoot.readSentinel(VolumeRef(uuid: d.volumeUUID, name: d.volumeName, token: d.volumeToken),
                                              relativePath: d.relativePath, moveID: plan.id, mountPoint: d.mountPoint)
        guard Sentinel.matches(found, moveID: plan.id, recipeID: plan.recipeID, volumeToken: d.volumeToken, relativePath: d.relativePath) else {
            return .changed("The drive's check file is missing or different.")
        }
        guard Journal.isWritable(home: home) else { return .changed(Say.journalBlocked) }
        return .unchanged
    }
}
