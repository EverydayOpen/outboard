import Foundation

/// What "Use this drive" did. It writes only `Outboard/.outboard/volume.json` (and the `Outboard/` folder around it), after a
/// UUID-mounted check; it never formats, erases, mounts or ejects anything.
public struct UseDriveResult: Codable, Hashable, Sendable {
    public var ok: Bool
    public var message: String
    /// The drive as read back after the marker was written (confirms APFS, encrypted yes/no/unknown, UUID recorded).
    public var facts: DriveFacts?

    public init(ok: Bool, message: String, facts: DriveFacts? = nil) {
        self.ok = ok
        self.message = message
        self.facts = facts
    }
}

/// What planning a move produced. The plan exists only if the drive passed eligibility and the preflight-lite checks; otherwise
/// `refusal` says why in plain English and `eligibility` carries the verdicts. Planning changes nothing on disk.
public struct MovePlanResult: Codable, Hashable, Sendable {
    public var plan: MovePlan?
    public var eligibility: EligibilityReport?
    public var refusal: String?

    public init(plan: MovePlan? = nil, eligibility: EligibilityReport? = nil, refusal: String? = nil) {
        self.plan = plan
        self.eligibility = eligibility
        self.refusal = refusal
    }
}

/// `SMAppService.Status` for the main app, as Outboard says it. Reported plainly, including after an update (an ad-hoc to
/// Developer ID change can leave the item `notFound` or `requiresApproval`).
public enum LoginItemState: String, Codable, CaseIterable, Sendable {
    case notRegistered, enabled, requiresApproval, notFound
    /// The platform call failed or is unavailable.
    case unavailable
}

/// The seam between the app and the system: a struct of closures with **exactly two implementations** (no protocol).
/// `OutboardMac.LiveBackend.make(home:appVersion:)` reads the real system and mutates real files through the single-site verbs;
/// `DemoBackend.make(_:)` (Core, `Demo/`) serves a scenario and runs the real Core state machine over an in-memory tree with an
/// in-memory journal. In demo mode nothing is read from or written to the real system.
public struct Backend: Sendable {
    // MARK: Read-only
    /// Sizes the catalogue entries' source folders (`lstat` only; never reads contents; performs no mutating verb). Unknown ids are
    /// ignored. Guided entries are measured too (they appear as muted lines).
    public var measure: @Sendable (_ recipeIDs: [RecipeID]) async -> [SizeScan]
    /// Every mounted volume with its facts (including internal ones; eligibility refuses them with a reason).
    public var volumes: @Sendable () async -> [DriveFacts]
    /// Re-reads the drive **now** and evaluates E1 to E19 for the recipe (nil = the general drive verdict used by the list).
    public var eligibility: @Sendable (_ volumeID: String, _ recipeID: RecipeID?) async -> EligibilityReport
    /// The consent sheet's blocker rows (target app, helpers, processes), read fresh. Re-evaluated on launch/terminate notifications.
    public var blockers: @Sendable (_ recipeID: RecipeID) -> [Blocker]
    /// Full Disk Access as far as a probe (`opendir` on a protected folder) can tell. Never nags.
    public var fullDiskAccess: @Sendable () -> Tri
    /// Relocation records folded from the journal (one model).
    public var relocations: @Sendable () -> [RelocationRecord]
    /// Incomplete copies and other things Outboard created and did not delete.
    public var leftovers: @Sendable () -> [Leftover]
    /// The journal, oldest first (tolerant of a torn last line). The Activity screen renders it through `ActivityText`.
    public var loadLog: @Sendable () -> [JournalEntry]
    /// "Copy diagnostics": the eligibility signals per volume and the errno matrix per measured folder. No file names.
    public var diagnostics: @Sendable () async -> String

    // MARK: Writes (each goes through the single-site verbs, journal first)
    /// "Use this drive": writes only the marker file.
    public var useDrive: @Sendable (_ volumeID: String) async -> UseDriveResult
    /// Builds a `MovePlan` for a recipe and a drive from the ticked consent boxes. Changes nothing.
    public var plan: @Sendable (_ recipeID: RecipeID, _ volumeID: String, _ consent: ConsentRecord) async -> MovePlanResult
    /// Runs the whole move: preflight, copy, verify, swap. Never throws; the outcome carries the state it left behind.
    public var move: @Sendable (_ plan: MovePlan, _ progress: @escaping @Sendable (MoveProgress) -> Void) async -> MoveOutcome
    /// "Confirm and move to Trash": records the decision, then trashes `<name>.before-move`.
    public var confirm: @Sendable (_ moveID: String) async -> MoveOutcome
    /// Roll back to the original (Swapped only).
    public var rollback: @Sendable (_ moveID: String) async -> MoveOutcome
    /// Return to Mac: a new record in the other direction, verified, with the drive copy kept.
    public var returnToMac: @Sendable (_ moveID: String, _ progress: @escaping @Sendable (MoveProgress) -> Void) async -> MoveOutcome
    /// Forget a relocation whose drive is gone for good.
    public var forget: @Sendable (_ moveID: String) async -> MoveOutcome
    /// The user's "Check and reconnect" after an unclean removal: hash every unchanged file, then unpark.
    public var checkAndReconnect: @Sendable (_ moveID: String, _ progress: @escaping @Sendable (MoveProgress) -> Void) async -> MoveOutcome
    /// The user's "Set it aside and reconnect" for a Conflict: the foreign item is renamed, never merged or deleted.
    public var setAsideAndReconnect: @Sendable (_ moveID: String) async -> MoveOutcome
    /// Moves a leftover that Outboard created to the Trash (`trashItem`, matched against the journal).
    public var trashLeftover: @Sendable (_ leftoverID: String) async -> MoveOutcome
    /// Guided steps are viewed: the journal records "guide viewed" and nothing else.
    public var recordGuideViewed: @Sendable (_ recipeID: RecipeID) -> Void

    // MARK: Drive Guard
    /// One idempotent pass over every watched relocation. Triggers are advisory; it is safe to call at any time.
    public var reconcile: @Sendable (_ trigger: ReconcileTrigger) async -> GuardSnapshot
    /// Starts the volume watcher (mount, unmount, rename, wake notifications and the timer while any relocation exists). Returns
    /// a cancel closure. The live implementation is the only observer of those notifications.
    public var watch: @Sendable (_ onTrigger: @escaping @Sendable (ReconcileTrigger) -> Void) -> @Sendable () -> Void
    public var loginItemState: @Sendable () -> LoginItemState
    /// Registers or unregisters the main app as a login item (`SMAppService.mainApp` only) and returns the state afterwards.
    public var setLoginItem: @Sendable (_ enabled: Bool) -> LoginItemState

    /// True for the demo implementation: the window shows a "Sample data" badge and the card is watermarked.
    public var isDemo: Bool

    public init(measure: @escaping @Sendable (_ recipeIDs: [RecipeID]) async -> [SizeScan],
                volumes: @escaping @Sendable () async -> [DriveFacts],
                eligibility: @escaping @Sendable (_ volumeID: String, _ recipeID: RecipeID?) async -> EligibilityReport,
                blockers: @escaping @Sendable (_ recipeID: RecipeID) -> [Blocker],
                fullDiskAccess: @escaping @Sendable () -> Tri,
                relocations: @escaping @Sendable () -> [RelocationRecord],
                leftovers: @escaping @Sendable () -> [Leftover],
                loadLog: @escaping @Sendable () -> [JournalEntry],
                diagnostics: @escaping @Sendable () async -> String,
                useDrive: @escaping @Sendable (_ volumeID: String) async -> UseDriveResult,
                plan: @escaping @Sendable (_ recipeID: RecipeID, _ volumeID: String, _ consent: ConsentRecord) async -> MovePlanResult,
                move: @escaping @Sendable (_ plan: MovePlan, _ progress: @escaping @Sendable (MoveProgress) -> Void) async -> MoveOutcome,
                confirm: @escaping @Sendable (_ moveID: String) async -> MoveOutcome,
                rollback: @escaping @Sendable (_ moveID: String) async -> MoveOutcome,
                returnToMac: @escaping @Sendable (_ moveID: String, _ progress: @escaping @Sendable (MoveProgress) -> Void) async -> MoveOutcome,
                forget: @escaping @Sendable (_ moveID: String) async -> MoveOutcome,
                checkAndReconnect: @escaping @Sendable (_ moveID: String, _ progress: @escaping @Sendable (MoveProgress) -> Void) async -> MoveOutcome,
                setAsideAndReconnect: @escaping @Sendable (_ moveID: String) async -> MoveOutcome,
                trashLeftover: @escaping @Sendable (_ leftoverID: String) async -> MoveOutcome,
                recordGuideViewed: @escaping @Sendable (_ recipeID: RecipeID) -> Void,
                reconcile: @escaping @Sendable (_ trigger: ReconcileTrigger) async -> GuardSnapshot,
                watch: @escaping @Sendable (_ onTrigger: @escaping @Sendable (ReconcileTrigger) -> Void) -> @Sendable () -> Void,
                loginItemState: @escaping @Sendable () -> LoginItemState,
                setLoginItem: @escaping @Sendable (_ enabled: Bool) -> LoginItemState,
                isDemo: Bool = false) {
        self.measure = measure
        self.volumes = volumes
        self.eligibility = eligibility
        self.blockers = blockers
        self.fullDiskAccess = fullDiskAccess
        self.relocations = relocations
        self.leftovers = leftovers
        self.loadLog = loadLog
        self.diagnostics = diagnostics
        self.useDrive = useDrive
        self.plan = plan
        self.move = move
        self.confirm = confirm
        self.rollback = rollback
        self.returnToMac = returnToMac
        self.forget = forget
        self.checkAndReconnect = checkAndReconnect
        self.setAsideAndReconnect = setAsideAndReconnect
        self.trashLeftover = trashLeftover
        self.recordGuideViewed = recordGuideViewed
        self.reconcile = reconcile
        self.watch = watch
        self.loginItemState = loginItemState
        self.setLoginItem = setLoginItem
        self.isDemo = isDemo
    }
}

/// Launch scenarios for demo mode (BUILD_PLAN §9). Raw values are what `-demoScenario <name>` accepts. Deterministic, home
/// `/Users/jane`, real catalogue app names (the recipes are the product), fictional sizes.
public enum DemoScenario: String, Codable, CaseIterable, Sendable {
    /// No drive attached, nothing measured yet.
    case fresh
    /// The 87 GB plan: Xcode 41, Ollama 30, iPhone backups 16.
    case plan
    /// As `plan`, plus Photos library 212 GB as a muted guided line.
    case planGuided = "plan-guided"
    /// iPhone backups "not measured (needs Full Disk Access)".
    case partlyMeasured = "partly-measured"
    /// Movable total under 5 GB: "Nothing big to move".
    case small
    /// No catalogued folder over 1 GB.
    case nothingFound = "nothing-found"
    /// One eligible drive and the refusals: exFAT SSD, USB hard disk, the Time Machine disk, two drives named Backup, a NAS, an SD card, a disk image.
    case drives
    /// One consent sheet per automated recipe.
    case consentXcodeDerivedData = "consent-xcode-deriveddata"
    case consentXcodeArchives = "consent-xcode-archives"
    case consentHuggingFace = "consent-huggingface-hub-cache"
    case consentOllama = "consent-ollama-models"
    case consentLlamaCpp = "consent-llamacpp-cache"
    case consentNpm = "consent-npm-cache"
    case consentIOSBackups = "consent-ios-device-backups"
    /// A guided card (Photos library) with the drive check.
    case guided
    /// Copying, frozen at 41%.
    case copying
    case verifying
    /// Ready to try the app and confirm.
    case swapped
    /// Confirmed and the original in the Trash.
    case confirmed
    /// The card after moves: "Moved 41 GB to your Outboard drive".
    case afterMoves = "after-moves"
    /// The drive was ejected: banner, placeholder note, parked.
    case driveAway = "drive-away"
    /// The drive is back and reconnected: "Checked 200 of 41,203 files: all matched."
    case driveBack = "drive-back"
    /// Removed without ejecting: Held until "Check and reconnect".
    case held
    /// Something new appeared where the folder should be.
    case conflict
    case rolledBack = "rolled-back"
    /// After a simulated crash: "Restored your original ... after an interruption."
    case recovered
    /// Recovery stopped and shows the facts.
    case needsAttention = "needs-attention"
    /// The journal is not writable, so nothing was changed.
    case journalBlocked = "journal-blocked"
    /// The Forget flow for a drive that is gone for good.
    case forget
    /// The export report preview.
    case report
    /// The five education cards over an empty Plan.
    case firstRun = "first-run"

    /// For the `consent-*` scenarios, the recipe the sheet is for.
    public var consentRecipeID: RecipeID? {
        switch self {
        case .consentXcodeDerivedData: return "xcode-deriveddata"
        case .consentXcodeArchives: return "xcode-archives"
        case .consentHuggingFace: return "huggingface-hub-cache"
        case .consentOllama: return "ollama-models"
        case .consentLlamaCpp: return "llamacpp-cache"
        case .consentNpm: return "npm-cache"
        case .consentIOSBackups: return "ios-device-backups"
        default: return nil
        }
    }
}
