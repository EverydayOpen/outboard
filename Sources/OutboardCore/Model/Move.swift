import Foundation

public enum MoveDirection: String, Codable, Sendable {
    /// Mac to the drive (the normal move).
    case toDrive
    /// Drive back to the Mac ("Return to Mac"): a new record with the same machine, the other way.
    case returnToMac
}

/// The move state machine (APP6 §4.4). The journal's folded state of one `RelocationRecord`.
///
///     Planned -> Preflight -> Copying -> Verifying -> Swapped -> Confirmed -> OriginalTrashed   (success)
///        |          |           |           |            +-> RolledBack (user, or automatic)
///        +----------+-----------+-----------+-> Aborted (nothing on the Mac changed)
///     Returned: a closed relocation after a reverse move. Forgotten: the user gave up on a drive that is gone for good.
public enum MoveState: String, Codable, CaseIterable, Sendable {
    case planned, preflight, copying, verifying, swapped, confirmed, originalTrashed
    case rolledBack, aborted, returned, forgotten

    /// Terminal for a move that did not become (or no longer is) an active relocation.
    public var isTerminal: Bool { self == .rolledBack || self == .aborted || self == .returned || self == .forgotten }
    /// The guard watches these: the redirect is in place (swapped, confirmed, originalTrashed).
    public var isActive: Bool { self == .swapped || self == .confirmed || self == .originalTrashed }
    /// Something on the Mac or the drive is still being changed by Outboard.
    public var isInFlight: Bool { self == .preflight || self == .copying || self == .verifying }
    /// From the end of Verifying until OriginalTrashed a verified copy exists on the drive and the original exists on the Mac
    /// (renamed once swapped): invariant I1.
    public var keepsOriginalOnMac: Bool { self == .swapped || self == .confirmed }

    /// The only legal next states. Anything else is a bug; `NeedsAttention` is not a state, it is an overlay.
    public var legalSuccessors: Set<MoveState> {
        switch self {
        case .planned: return [.preflight, .aborted]
        case .preflight: return [.copying, .aborted]
        case .copying: return [.verifying, .aborted]
        case .verifying: return [.swapped, .aborted]
        case .swapped: return [.confirmed, .rolledBack, .forgotten]
        case .confirmed: return [.originalTrashed, .returned, .forgotten]
        case .originalTrashed: return [.returned, .forgotten]
        case .rolledBack, .aborted, .returned, .forgotten: return []
        }
    }

    public var displayName: String {
        switch self {
        case .planned: return "Planned"
        case .preflight: return "Checking"
        case .copying: return "Copying"
        case .verifying: return "Comparing"
        case .swapped: return "Ready to confirm"
        case .confirmed: return "Moved"
        case .originalTrashed: return "Moved"
        case .rolledBack: return "Rolled back"
        case .aborted: return "Stopped"
        case .returned: return "Returned to Mac"
        case .forgotten: return "Forgotten"
        }
    }
}

/// The verbs of the journal (APP6 §4.4, §4.5). Each is written by exactly one Mac function (its "only site"), as an `intent`
/// line before the act and a `result` line after. Unknown steps in an old or hand-edited file are shown raw, not dropped.
public enum MoveStep: String, Codable, CaseIterable, Sendable {
    // The move
    case begin, preflight, copy, verify, publish, setAside, redirect, swapped
    // The user's decisions
    case confirm, trash, rollback, undoRedirect, undoSetAside, setAsideForeign, returned, forget
    // The guard
    case park, unpark, retarget, recreate, checkAndReconnect
    // Bookkeeping
    case recover, abort, guideViewed, useDrive, startGuard
}

public enum JournalPhase: String, Codable, Sendable {
    /// Appended and `fsync`ed **before** the act. If this cannot be written, the act does not happen.
    case intent
    /// Appended after. A missing result means the step is ambiguous and recovery looks at the disk.
    case result
}

public enum StepStatus: String, Codable, Sendable {
    case ok
    case failed
    /// A rule or a check said no; nothing was changed.
    case refused
    /// Compared and different.
    case mismatch
    /// Stopped by a crash, a sleep, an unplug or the user.
    case interrupted
}

/// Why a move ended in `aborted`. Nothing on the Mac changed in any of these.
public enum AbortReason: String, Codable, CaseIterable, Sendable {
    case userCancelled
    /// A preflight check P1 to P14 failed (the report names which).
    case preflightFailed
    /// The app quit, crashed or lost power before the swap (recovery).
    case interrupted
    case destinationFull
    /// V3: the source changed while it was being copied. Quit the app and start over.
    case sourceChanged
    /// V2: a file differs between the source and the copy.
    case mismatch
    /// The target app launched before the swap.
    case appLaunched
    case journalUnwritable
    /// E18: the drive's UUID, mount path or presence changed since the plan.
    case driveChanged
    /// An app created a folder at the path between the rename and the redirect; it was set aside and the move rolled back.
    case foreignFolderAppeared
    /// W4: the link or setting did not resolve to the recorded volume and sentinel.
    case healthFailed
    /// W4: the check list (manifest) written at copy time could not be read back, so the copy on the drive could not be listed against it.
    case manifestUnreadable
    /// `EPERM` / `EACCES`: macOS blocked access (Full Disk Access or Removable Volumes).
    case needsPermission
    case copyFailed
    case sleepInterrupted
    case unknown
}

// MARK: - Preflight

public enum PreflightID: String, Codable, CaseIterable, Sendable {
    case p1 = "P1"      // destination eligibility
    case p2 = "P2"      // recipe enabled in this build
    case p3 = "P3"      // source is a real local directory on the boot volume's data side, not a link
    case p4 = "P4"      // source not in the never-list
    case p5 = "P5"      // fully local (no dataless file)
    case p6 = "P6"      // no sockets, FIFOs or devices
    case p7 = "P7"      // no leftover .before-move, .staging-*, Parked/<id>
    case p8 = "P8"      // target app and helpers not running; manual checks ticked
    case p9 = "P9"      // journal writable
    case p10 = "P10"    // source readable end to end
    case p11 = "P11"    // case sensitivity compatible
    case p12 = "P12"    // hard links supported where needed
    case p13 = "P13"    // destination path length and names valid, and the folder's check list (manifest) fits in one file
    case p14 = "P14"    // no other mutation in flight
}

public struct PreflightCheck: Codable, Hashable, Sendable, Identifiable {
    public var check: PreflightID
    public var passed: Bool
    /// Plain English; names the signal when the check failed.
    public var detail: String

    public init(_ check: PreflightID, passed: Bool, detail: String = "") {
        self.check = check
        self.passed = passed
        self.detail = detail
    }

    public var id: String { check.rawValue }
}

public struct PreflightReport: Codable, Hashable, Sendable {
    public var checks: [PreflightCheck]

    public init(checks: [PreflightCheck]) {
        self.checks = checks
    }

    public var passed: Bool { !checks.isEmpty && checks.allSatisfy(\.passed) }
    public var firstFailure: PreflightCheck? { checks.first { !$0.passed } }
    /// "14 of 14 checks passed."
    public var passedCount: Int { checks.filter(\.passed).count }
}

// MARK: - The running check

public enum RunState: String, Codable, Sendable {
    case running, notRunning
    /// The process list could not be read. Unknown blocks (fail closed).
    case unknown
}

/// One row in the consent sheet's "Before you start" list: a name, a state, nothing clickable that kills it.
public struct Blocker: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var bundleID: String?
    public var processName: String?
    public var state: RunState

    public init(id: String, name: String, bundleID: String? = nil, processName: String? = nil, state: RunState) {
        self.id = id
        self.name = name
        self.bundleID = bundleID
        self.processName = processName
        self.state = state
    }

    public var isClear: Bool { state == .notRunning }
}

// MARK: - The plan of one move

/// How the app is pointed at the copy. Paths are absolute here (the plan is in memory); the journal stores `~` forms.
public enum RedirectPlan: Codable, Hashable, Sendable {
    /// A symbolic link at `linkPath` pointing to `target` on the drive.
    case symbolicLink(linkPath: String, target: String)
    /// `defaults write` of resolved values. `prior` is what `defaults read` returned before (nil value = key absent). `revert` is
    /// what putting the setting back writes, resolved when the plan is made from the recipe's `DefaultsRestore` and `prior`
    /// (a key with neither a prior value nor a neutral value is left alone). There is no delete.
    case defaults(domain: String, writes: [DefaultsWrite], prior: [PriorValue], revert: [DefaultsWrite])
}

public struct DefaultsWrite: Codable, Hashable, Sendable {
    public var key: String
    public var type: DefaultsValueType
    public var value: String

    public init(key: String, type: DefaultsValueType, value: String) {
        self.key = key
        self.type = type
        self.value = value
    }
}

public struct PriorValue: Codable, Hashable, Sendable {
    public var key: String
    public var type: DefaultsValueType?
    /// nil = the key did not exist.
    public var value: String?

    public init(key: String, type: DefaultsValueType? = nil, value: String? = nil) {
        self.key = key
        self.type = type
        self.value = value
    }
}

/// Where the copy lands on the drive. The volume's UUID is the identity; the name and mount point are display values.
public struct PlanDestination: Codable, Hashable, Sendable {
    public var volumeUUID: String
    public var volumeName: String
    public var mountPoint: String
    /// The random token in `Outboard/.outboard/volume.json` at planning time.
    public var volumeToken: String
    /// `Outboard/<recipe-id>`, relative to the mount point.
    public var recipeFolder: String
    /// The data folder's name: `DerivedData`, `models`, `Backup`.
    public var leaf: String

    public init(volumeUUID: String, volumeName: String, mountPoint: String, volumeToken: String, recipeFolder: String, leaf: String) {
        self.volumeUUID = volumeUUID
        self.volumeName = volumeName
        self.mountPoint = mountPoint
        self.volumeToken = volumeToken
        self.recipeFolder = recipeFolder
        self.leaf = leaf
    }

    /// `<recipeFolder>/<leaf>`, relative to the mount point. Stored in the journal; the absolute path is recomputed from the
    /// current mount point (a drive can come back under another name).
    public var relativePath: String { recipeFolder + "/" + leaf }
    public var finalPath: String { mountPoint + "/" + relativePath }
}

/// What the user agreed to, journaled with the plan.
public struct ConsentRecord: Codable, Hashable, Sendable {
    /// Bumped when a recipe's consent text changes.
    public var recipeVersion: Int
    public var tickedIDs: [String]
    /// Eligibility acknowledgements ticked (`ack-e16`).
    public var ackIDs: [String]
    /// The sheet carried "Not yet tried on a real Mac."
    public var sawUnverifiedNote: Bool

    public init(recipeVersion: Int, tickedIDs: [String], ackIDs: [String] = [], sawUnverifiedNote: Bool = false) {
        self.recipeVersion = recipeVersion
        self.tickedIDs = tickedIDs
        self.ackIDs = ackIDs
        self.sawUnverifiedNote = sawUnverifiedNote
    }
}

/// The plan of one move: built by Core `MovePlanner` from a recipe, a measured source, a verified drive and the ticked consent
/// boxes; handed to the engine; written to the journal as the `begin` record. Nothing runs without one.
public struct MovePlan: Codable, Hashable, Sendable, Identifiable {
    /// `20261003T101500Z-3fa9c1`
    public var id: String
    public var direction: MoveDirection
    public var recipeID: RecipeID
    public var recipeVersion: Int
    public var recipeName: String
    public var method: MethodKind
    public var risk: RiskClass
    /// Absolute source path (for `toDrive`: the folder on the Mac; for `returnToMac`: the folder on the drive).
    public var sourcePath: String
    /// Absolute path of the folder on the Mac that is renamed, linked or redirected. Equals `sourcePath` for `toDrive`.
    public var macPath: String
    public var sourceStamp: FileStamp
    public var sourceFingerprint: TreeFingerprint
    public var destination: PlanDestination
    public var redirect: RedirectPlan
    public var consent: ConsentRecord
    /// A recipe with a companion folder (Hugging Face `xet`) plans one move per folder; they share this id and run in turn.
    public var groupID: String?
    public var createdAt: Date

    public init(id: String, direction: MoveDirection = .toDrive, recipeID: RecipeID, recipeVersion: Int, recipeName: String,
                method: MethodKind, risk: RiskClass, sourcePath: String, macPath: String, sourceStamp: FileStamp,
                sourceFingerprint: TreeFingerprint, destination: PlanDestination, redirect: RedirectPlan, consent: ConsentRecord,
                groupID: String? = nil, createdAt: Date) {
        self.id = id
        self.direction = direction
        self.recipeID = recipeID
        self.recipeVersion = recipeVersion
        self.recipeName = recipeName
        self.method = method
        self.risk = risk
        self.sourcePath = sourcePath
        self.macPath = macPath
        self.sourceStamp = sourceStamp
        self.sourceFingerprint = sourceFingerprint
        self.destination = destination
        self.redirect = redirect
        self.consent = consent
        self.groupID = groupID
        self.createdAt = createdAt
    }

    /// `<macPath>.before-move`
    public var beforeMovePath: String { macPath + Names.beforeMoveSuffix }
    /// `<mount>/Outboard/<recipe>/.staging-<id>`
    public var stagingPath: String { destination.mountPoint + "/" + destination.recipeFolder + "/" + Names.stagingPrefix + id }
    /// `<mount>/Outboard/<recipe>/.sentinel-<id>.json`, beside the data folder, never inside it.
    public var sentinelPath: String { destination.mountPoint + "/" + destination.recipeFolder + "/" + Names.sentinelPrefix + id + Names.sentinelSuffix }
    public var logicalBytes: UInt64 { sourceFingerprint.logicalBytes }
}

// MARK: - Progress and outcome

public enum ProgressPhase: String, Codable, Sendable {
    case preflight, copying, verifying, swapping, finishing
}

/// Live progress. **There is no estimate and no rate** (honest wording): copying shows bytes and elapsed time, verifying shows
/// files.
public struct MoveProgress: Codable, Hashable, Sendable {
    public var moveID: String
    public var phase: ProgressPhase
    public var bytesDone: UInt64
    public var bytesTotal: UInt64
    public var filesDone: Int
    public var filesTotal: Int
    public var elapsedSeconds: Double
    /// "Xcode opened. If it changes the data, the move will start over." when a blocker launches during the copy.
    public var note: String?

    public init(moveID: String, phase: ProgressPhase, bytesDone: UInt64 = 0, bytesTotal: UInt64 = 0, filesDone: Int = 0,
                filesTotal: Int = 0, elapsedSeconds: Double = 0, note: String? = nil) {
        self.moveID = moveID
        self.phase = phase
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
        self.filesDone = filesDone
        self.filesTotal = filesTotal
        self.elapsedSeconds = elapsedSeconds
        self.note = note
    }

    /// 0...1 for the bar of the current phase (bytes while copying, files while verifying).
    public var fraction: Double {
        switch phase {
        case .copying: return bytesTotal == 0 ? 0 : min(1, Double(bytesDone) / Double(bytesTotal))
        case .verifying: return filesTotal == 0 ? 0 : min(1, Double(filesDone) / Double(filesTotal))
        case .preflight: return 0
        case .swapping, .finishing: return 1
        }
    }
}

/// Which user-visible action an outcome is the result of.
public enum MoveActionKind: String, Codable, CaseIterable, Sendable {
    case move, confirm, rollback, returnToMac, forget, checkAndReconnect, trashLeftover, setAsideAndReconnect, recover
}

/// The result of any action. Never thrown: failures are values with a plain message and the state they left behind.
public struct MoveOutcome: Codable, Hashable, Sendable {
    public var action: MoveActionKind
    public var moveID: String
    public var state: MoveState
    public var ok: Bool
    public var abort: AbortReason?
    /// One plain sentence: "Moved 41 GB to Outboard drive. Your original is kept until you confirm."
    public var message: String
    public var preflight: PreflightReport?
    public var verification: VerificationSummary?
    /// Up to `Limits.firstDifferencesListed`.
    public var differences: [Difference]
    public var errnoCode: Int32?

    public init(action: MoveActionKind, moveID: String, state: MoveState, ok: Bool, abort: AbortReason? = nil, message: String = "",
                preflight: PreflightReport? = nil, verification: VerificationSummary? = nil, differences: [Difference] = [],
                errnoCode: Int32? = nil) {
        self.action = action
        self.moveID = moveID
        self.state = state
        self.ok = ok
        self.abort = abort
        self.message = message
        self.preflight = preflight
        self.verification = verification
        self.differences = differences
        self.errnoCode = errnoCode
    }
}

// MARK: - Closed verbs and rule verdicts

/// The only renames Outboard performs (APP6 §4.4). `Renamer.perform(_:)` takes one of these, never two free URLs, so a call
/// site cannot invent a rename. Core `RenameRules.check` approves the exact pair for each.
public enum RenameOp: String, Codable, CaseIterable, Sendable {
    /// `<name>` to `<name>.before-move` (the original, kept until the user confirms).
    case setAside
    /// `<name>.before-move` back to `<name>` (rollback R3).
    case undoSetAside
    /// Staging to its final name on the drive, once verified.
    case publish
    /// The link at the path into `Parked/<moveID>/link` (the drive is missing).
    case park
    /// The parked link or the note out of the way when the drive returns.
    case unpark
    /// A folder an app created in the gap, set aside as `<name>.created-while-moving` (or `.created-while-rolling-back`, `.while-away-<date>`). Never merged.
    case setAsideForeign
}

/// The answer of every pure `*Rules.check` / `*Rules.allows` function in Core. A refusal carries a plain reason for the journal and the UI.
public enum RuleVerdict: Codable, Hashable, Sendable {
    case allowed
    case refused(String)

    public var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }

    public var reason: String? {
        if case .refused(let r) = self { return r }
        return nil
    }
}

/// What the Mac layer saw running, read fresh: the input of Core `RunningCheck.state` and `RunningCheck.blockers`.
public struct RunningSnapshot: Codable, Hashable, Sendable {
    /// False when the process list could not be read. Unreadable blocks (fail closed).
    public var readable: Bool
    public var bundleIDs: Set<String>
    /// Process names from libproc (`ollama`, `xcodebuild`). A name match from any user counts as running.
    public var processNames: Set<String>
    /// Names of processes holding files open under the source folder (same-user `PROC_PIDLISTFDS`; nil = not enumerated).
    public var openHandleHolders: [String]?

    public init(readable: Bool, bundleIDs: Set<String> = [], processNames: Set<String> = [], openHandleHolders: [String]? = nil) {
        self.readable = readable
        self.bundleIDs = bundleIDs
        self.processNames = processNames
        self.openHandleHolders = openHandleHolders
    }
}
