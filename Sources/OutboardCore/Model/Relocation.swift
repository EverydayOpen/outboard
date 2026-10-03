import Foundation

/// A drive as a record remembers it. Identity is the UUID plus the token plus the sentinel, **never the name or the path**
/// (invariant I7: a stale `/Volumes/<Name>` folder makes the real drive mount as `<Name> 1`).
public struct VolumeRef: Codable, Hashable, Sendable {
    public var uuid: String
    /// The name when the move was made. A display value only; renames are followed by UUID.
    public var name: String
    /// The random token of `Outboard/.outboard/volume.json`.
    public var token: String

    public init(uuid: String, name: String, token: String) {
        self.uuid = uuid
        self.name = name
        self.token = token
    }

    /// What banners and the ledger call the drive: "Outboard drive" for a volume named Outboard (the recommended name),
    /// otherwise the volume's own name.
    public var label: String { name.lowercased() == "outboard" ? "Outboard drive" : name }
}

/// What happened to the renamed original (`<name>.before-move`).
public enum SafetyCopyState: String, Codable, Sendable {
    /// No safety copy yet (before the swap) or none needed (Aborted).
    case none
    /// `<name>.before-move` is on the Mac. Rolling back is possible until the user confirms.
    case kept
    /// Moved to the Trash after the user confirmed. Space returns when the Trash is emptied.
    case inTrash
    /// Not found where the record expects it (the user emptied the Trash or removed it): "rolling back is no longer possible".
    case gone
}

public enum DifferenceKind: String, Codable, Sendable {
    case missingOnDrive, extraOnDrive, typeDiffers, sizeDiffers, hashDiffers, modeDiffers
    case symlinkTargetDiffers, xattrDiffers, unreadable, changedDuringCopy
}

/// One difference found by the verifier. `path` is relative to the compared folder: no home folder, no user name.
public struct Difference: Codable, Hashable, Sendable, Identifiable {
    public var path: String
    public var kind: DifferenceKind
    public var detail: String

    public init(path: String, kind: DifferenceKind, detail: String = "") {
        self.path = path
        self.kind = kind
        self.detail = detail
    }

    public var id: String { "\(kind.rawValue)|\(path)" }
}

/// What the verifier compared. "Compared", never "protected" or "intact": equality at one moment is all this shows.
public struct VerificationSummary: Codable, Hashable, Sendable {
    public var algorithm: String
    public var filesCompared: Int
    public var bytesCompared: UInt64
    public var symlinksCompared: Int
    public var differences: Int
    /// Files that were hard links on the Mac and were copied as separate files ("N hard-linked files were copied as separate files").
    public var hardLinkedCopiedSeparately: Int
    /// The destination tree was read with the page cache bypassed (`F_NOCACHE`).
    public var destinationReadUncached: Bool
    /// SHA-256 of the sorted `relativePath NUL sha256 NL` listing of the whole tree.
    public var manifestDigest: String
    public var completedAt: Date

    public init(algorithm: String = "SHA-256", filesCompared: Int, bytesCompared: UInt64, symlinksCompared: Int = 0, differences: Int = 0,
                hardLinkedCopiedSeparately: Int = 0, destinationReadUncached: Bool = true, manifestDigest: String = "", completedAt: Date) {
        self.algorithm = algorithm
        self.filesCompared = filesCompared
        self.bytesCompared = bytesCompared
        self.symlinksCompared = symlinksCompared
        self.differences = differences
        self.hardLinkedCopiedSeparately = hardLinkedCopiedSeparately
        self.destinationReadUncached = destinationReadUncached
        self.manifestDigest = manifestDigest
        self.completedAt = completedAt
    }
}

/// The last journal line of a record. Recovery reads it (APP6 §4.4); nothing else does.
public struct JournalMark: Codable, Hashable, Sendable {
    public var step: MoveStep
    public var phase: JournalPhase
    public var status: StepStatus?

    public init(step: MoveStep, phase: JournalPhase, status: StepStatus? = nil) {
        self.step = step
        self.phase = phase
        self.status = status
    }
}

/// The folded journal of one move: **the one model** every state and count on screen comes from (invariant I10). Built by Core
/// `RelocationFold` from `JournalEntry` lines; health is derived from this plus the facts, never stored here.
public struct RelocationRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var direction: MoveDirection
    public var recipeID: RecipeID
    public var recipeVersion: Int
    public var recipeName: String
    public var method: MethodKind
    public var risk: RiskClass
    /// Frozen at move time so a later catalogue change cannot change what the guard does to an old relocation.
    public var onDriveMissing: OnDriveMissing
    public var state: MoveState
    /// `~`-relative path of the folder on the Mac (the link, or the setting's default folder).
    public var macPath: String
    public var volume: VolumeRef
    /// Relative to the drive's mount point: `Outboard/<recipe-id>/<leaf>`.
    public var relativePath: String
    /// For `defaults` recipes: the domain and what putting the setting back writes.
    public var defaultsDomain: String?
    public var defaultsWrites: [DefaultsWrite]
    public var defaultsRevert: [DefaultsWrite]
    public var logicalBytes: UInt64
    public var fileCount: Int
    public var safetyCopy: SafetyCopyState
    public var verification: VerificationSummary?
    public var abort: AbortReason?
    public var last: JournalMark
    public var createdAt: Date
    public var updatedAt: Date
    public var swappedAt: Date?
    public var confirmedAt: Date?
    public var trashedAt: Date?
    /// The guard has parked this relocation (the link is in `Parked/<id>/`, a note file is at the path).
    public var isParked: Bool
    /// The drive was last seen removed without an eject; "Check and reconnect" is needed before unparking.
    public var needsCheckBeforeReconnect: Bool
    /// How the drive left, as the park line's note recorded it; nil while the relocation is not parked. `unknown` means Outboard did
    /// not see how it left (it was already gone when Outboard looked).
    public var removalKind: RemovalKind?
    public var groupID: String?
    /// Plain-English problems recorded for the report (aborts, rollbacks, held, conflicts).
    public var problems: [String]
    /// A `rollback` line is in the journal for this move: a rollback was begun (by the user, or by recovery after a crash). Recovery
    /// finishes an interrupted rollback only when this is set, whatever other line (`undoRedirect` ...) happens to come last.
    public var rollbackStarted: Bool

    public init(id: String, direction: MoveDirection = .toDrive, recipeID: RecipeID, recipeVersion: Int, recipeName: String,
                method: MethodKind, risk: RiskClass, onDriveMissing: OnDriveMissing, state: MoveState, macPath: String,
                volume: VolumeRef, relativePath: String, defaultsDomain: String? = nil, defaultsWrites: [DefaultsWrite] = [],
                defaultsRevert: [DefaultsWrite] = [], logicalBytes: UInt64 = 0, fileCount: Int = 0, safetyCopy: SafetyCopyState = .none,
                verification: VerificationSummary? = nil, abort: AbortReason? = nil, last: JournalMark, createdAt: Date,
                updatedAt: Date, swappedAt: Date? = nil, confirmedAt: Date? = nil, trashedAt: Date? = nil, isParked: Bool = false,
                needsCheckBeforeReconnect: Bool = false, removalKind: RemovalKind? = nil, groupID: String? = nil, problems: [String] = [],
                rollbackStarted: Bool = false) {
        self.id = id
        self.direction = direction
        self.recipeID = recipeID
        self.recipeVersion = recipeVersion
        self.recipeName = recipeName
        self.method = method
        self.risk = risk
        self.onDriveMissing = onDriveMissing
        self.state = state
        self.macPath = macPath
        self.volume = volume
        self.relativePath = relativePath
        self.defaultsDomain = defaultsDomain
        self.defaultsWrites = defaultsWrites
        self.defaultsRevert = defaultsRevert
        self.logicalBytes = logicalBytes
        self.fileCount = fileCount
        self.safetyCopy = safetyCopy
        self.verification = verification
        self.abort = abort
        self.last = last
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.swappedAt = swappedAt
        self.confirmedAt = confirmedAt
        self.trashedAt = trashedAt
        self.isParked = isParked
        self.needsCheckBeforeReconnect = needsCheckBeforeReconnect
        self.removalKind = removalKind
        self.groupID = groupID
        self.problems = problems
        self.rollbackStarted = rollbackStarted
    }

    /// The guard watches this record (swapped, confirmed, originalTrashed) and it is a drive-to-Mac redirect.
    public var isWatchedByGuard: Bool { state.isActive }
    /// Rolling back is offered (the safety copy is still on the Mac and the user has not confirmed).
    public var canRollBack: Bool { state == .swapped && safetyCopy == .kept }
    /// Confirm and move to Trash is offered.
    public var canConfirm: Bool { state == .swapped }
    /// Return to Mac is offered (after confirm; needs the drive).
    public var canReturn: Bool { (state == .confirmed || state == .originalTrashed) && direction == .toDrive }
    /// The 14-day in-app reminder that a safety copy is still on the Mac applies.
    public func safetyCopyReminderDue(now: Date) -> Bool {
        guard safetyCopy == .kept, let swappedAt else { return false }
        return now.timeIntervalSince(swappedAt) >= Double(Limits.safetyCopyReminderDays) * 86_400
    }
}

public enum LeftoverKind: String, Codable, Sendable {
    /// A staging folder or an unpublished copy from an aborted move.
    case incompleteCopy
    /// The published copy of a rolled-back move (kept on the drive, labelled).
    case rolledBackCopy
    /// `<name>.before-move` still on the Mac (offered for the Trash only after Confirm).
    case safetyCopy
    /// The drive copy that stays after a Return to Mac.
    case driveCopyAfterReturn
    /// An item an app created while a move or rollback ran, set aside and never merged.
    case setAsideForeign
}

/// Something Outboard created and did not delete, labelled and offered for the Trash ("Incomplete copy from 3 Oct, 38 GB").
public struct Leftover: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var moveID: String
    public var kind: LeftoverKind
    /// `~`-relative on the Mac; for a drive item: the drive-relative path.
    public var path: String
    public var onDrive: Bool
    public var volume: VolumeRef?
    public var bytes: UInt64
    public var createdAt: Date

    public init(id: String, moveID: String, kind: LeftoverKind, path: String, onDrive: Bool, volume: VolumeRef? = nil, bytes: UInt64, createdAt: Date) {
        self.id = id
        self.moveID = moveID
        self.kind = kind
        self.path = path
        self.onDrive = onDrive
        self.volume = volume
        self.bytes = bytes
        self.createdAt = createdAt
    }
}
