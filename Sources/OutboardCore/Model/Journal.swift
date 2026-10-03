import Foundation

/// The plan as the `begin` line stores it: enough to rebuild a `RelocationRecord`, to recompute the link target from a
/// drive's current mount point, and to put a setting back. Paths use `~` for the home folder.
public struct JournalPlan: Codable, Hashable, Sendable {
    public var direction: MoveDirection
    public var recipeID: RecipeID
    public var recipeVersion: Int
    public var recipeName: String
    public var method: MethodKind
    public var risk: RiskClass
    public var onDriveMissing: OnDriveMissing
    public var macPath: String
    public var volume: VolumeRef
    /// Relative to the drive's mount point.
    public var relativePath: String
    public var defaultsDomain: String?
    public var defaultsWrites: [DefaultsWrite]
    public var defaultsPrior: [PriorValue]
    public var defaultsRevert: [DefaultsWrite]
    public var logicalBytes: UInt64
    public var fileCount: Int
    public var groupID: String?
    public var consent: ConsentRecord

    public init(direction: MoveDirection, recipeID: RecipeID, recipeVersion: Int, recipeName: String, method: MethodKind,
                risk: RiskClass, onDriveMissing: OnDriveMissing, macPath: String, volume: VolumeRef, relativePath: String,
                defaultsDomain: String? = nil, defaultsWrites: [DefaultsWrite] = [], defaultsPrior: [PriorValue] = [],
                defaultsRevert: [DefaultsWrite] = [], logicalBytes: UInt64, fileCount: Int, groupID: String? = nil,
                consent: ConsentRecord) {
        self.direction = direction
        self.recipeID = recipeID
        self.recipeVersion = recipeVersion
        self.recipeName = recipeName
        self.method = method
        self.risk = risk
        self.onDriveMissing = onDriveMissing
        self.macPath = macPath
        self.volume = volume
        self.relativePath = relativePath
        self.defaultsDomain = defaultsDomain
        self.defaultsWrites = defaultsWrites
        self.defaultsPrior = defaultsPrior
        self.defaultsRevert = defaultsRevert
        self.logicalBytes = logicalBytes
        self.fileCount = fileCount
        self.groupID = groupID
        self.consent = consent
    }
}

/// Numbers a line may carry. Each is optional; the text renderer says only what is present.
public struct JournalCounts: Codable, Hashable, Sendable {
    public var files: Int?
    public var bytes: UInt64?
    public var differences: Int?
    public var checksPassed: Int?
    public var checksTotal: Int?
    /// Free bytes on the drive when it was checked.
    public var freeBytes: UInt64?
    /// "Checked 200 of 41,203 files": the sample and the total.
    public var sampled: Int?
    public var sampleOf: Int?

    public init(files: Int? = nil, bytes: UInt64? = nil, differences: Int? = nil, checksPassed: Int? = nil, checksTotal: Int? = nil,
                freeBytes: UInt64? = nil, sampled: Int? = nil, sampleOf: Int? = nil) {
        self.files = files
        self.bytes = bytes
        self.differences = differences
        self.checksPassed = checksPassed
        self.checksTotal = checksTotal
        self.freeBytes = freeBytes
        self.sampled = sampled
        self.sampleOf = sampleOf
    }
}

/// One line of the append-only journal (`journal-YYYY-MM.jsonl`, `ActivityLog.encode`). It is the audit trail, the input of
/// crash recovery and the source of the Activity screen and the export: **one record store** (invariant I10). It holds `~`
/// paths because recovery needs them; the file never leaves the Mac. 0600 in a 0700 folder, `O_APPEND | O_NOFOLLOW`, `fsync`
/// per line, a torn last line is ignored.
///
/// `intent` lines are appended and synced **before** the act and the act does not happen if the append fails; `result` lines
/// follow. A missing result means "ambiguous": recovery looks at the disk.
public struct JournalEntry: Codable, Hashable, Sendable {
    /// Schema version (`Limits.journalSchema`).
    public var v: Int
    /// The move id this line belongs to; `"app"` for lines that belong to no move (`startGuard`, `useDrive`, `guideViewed`).
    public var id: String
    /// 1-based position within the move's lines.
    public var seq: Int
    public var ts: Date
    public var phase: JournalPhase
    /// `MoveStep.rawValue`. Kept as a string so a step this build does not know is shown raw instead of dropping the line.
    public var step: String
    /// `<recipe-id>@<version>`.
    public var recipe: String?
    /// The state the move is in once this line is applied (set on the lines that change it).
    public var state: MoveState?
    public var src: String?
    public var to: String?
    public var stamp: FileStamp?
    /// Volume UUID.
    public var vol: String?
    public var volName: String?
    /// Format name as shown to the user ("APFS").
    public var fsName: String?
    public var status: StepStatus?
    public var errno: Int32?
    public var abort: AbortReason?
    public var note: String?
    /// Only on the `begin` line.
    public var plan: JournalPlan?
    public var counts: JournalCounts?
    public var verification: VerificationSummary?
    /// `resultingItemURL` path of a trashed item (`~`-relative on the Mac, drive-relative on a drive's Trash is not recorded).
    public var trashedPath: String?

    public init(v: Int = Limits.journalSchema, id: String, seq: Int, ts: Date, phase: JournalPhase, step: String, recipe: String? = nil,
                state: MoveState? = nil, src: String? = nil, to: String? = nil, stamp: FileStamp? = nil, vol: String? = nil,
                volName: String? = nil, fsName: String? = nil, status: StepStatus? = nil, errno: Int32? = nil, abort: AbortReason? = nil,
                note: String? = nil, plan: JournalPlan? = nil, counts: JournalCounts? = nil, verification: VerificationSummary? = nil,
                trashedPath: String? = nil) {
        self.v = v
        self.id = id
        self.seq = seq
        self.ts = ts
        self.phase = phase
        self.step = step
        self.recipe = recipe
        self.state = state
        self.src = src
        self.to = to
        self.stamp = stamp
        self.vol = vol
        self.volName = volName
        self.fsName = fsName
        self.status = status
        self.errno = errno
        self.abort = abort
        self.note = note
        self.plan = plan
        self.counts = counts
        self.verification = verification
        self.trashedPath = trashedPath
    }

    public init(v: Int = Limits.journalSchema, id: String, seq: Int, ts: Date, phase: JournalPhase, step: MoveStep, recipe: String? = nil,
                state: MoveState? = nil, src: String? = nil, to: String? = nil, stamp: FileStamp? = nil, vol: String? = nil,
                volName: String? = nil, fsName: String? = nil, status: StepStatus? = nil, errno: Int32? = nil, abort: AbortReason? = nil,
                note: String? = nil, plan: JournalPlan? = nil, counts: JournalCounts? = nil, verification: VerificationSummary? = nil,
                trashedPath: String? = nil) {
        self.init(v: v, id: id, seq: seq, ts: ts, phase: phase, step: step.rawValue, recipe: recipe, state: state, src: src, to: to,
                  stamp: stamp, vol: vol, volName: volName, fsName: fsName, status: status, errno: errno, abort: abort, note: note,
                  plan: plan, counts: counts, verification: verification, trashedPath: trashedPath)
    }

    /// Unique per line (the move id repeats): `ForEach` and `ActivityEntry.id` use this.
    public var lineID: String { "\(id)|\(seq)|\(phase.rawValue)|\(step)" }
    /// The step, when this build knows it.
    public var moveStep: MoveStep? { MoveStep(rawValue: step) }
    /// A result that is not `ok` (a failed, refused, mismatched or interrupted step): shown under "problems only".
    public var isProblem: Bool {
        if let status, status != .ok { return true }
        return abort != nil
    }
}

/// Who a journal line is about, so the verbs (which act on a plan, a record or a recovery fact) write the same fields.
public struct JournalSubject: Codable, Hashable, Sendable {
    public var moveID: String
    /// `<recipe-id>@<version>`
    public var recipe: String

    public init(moveID: String, recipe: String) {
        self.moveID = moveID
        self.recipe = recipe
    }

    public init(_ plan: MovePlan) {
        self.init(moveID: plan.id, recipe: "\(plan.recipeID)@\(plan.recipeVersion)")
    }

    public init(_ record: RelocationRecord) {
        self.init(moveID: record.id, recipe: "\(record.recipeID)@\(record.recipeVersion)")
    }

    /// Lines that belong to no move (`useDrive`, `guideViewed`, `startGuard`).
    public static let app = JournalSubject(moveID: "app", recipe: "")
}
