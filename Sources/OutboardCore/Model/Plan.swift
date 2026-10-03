import Foundation

public enum SizeState: String, Codable, Sendable {
    /// The whole tree was walked.
    case measured
    /// The walk was cut short (budget): the number is a floor. Shown as "at least 3 GB"; never counted in the headline.
    case atLeast
    case notMeasured
    /// The source does not exist on this Mac.
    case absent
}

public enum NotMeasuredReason: String, Codable, Sendable {
    /// `EPERM` / `EACCES` on a folder macOS protects (iOS backups): "not measured (needs Full Disk Access)".
    case needsFullDiskAccess
    case denied
    case failed
    /// The folder is a link or already points somewhere (see `SizeScan.redirectedTo`).
    case alreadyRedirected
}

/// What the read-only size scan found for one source folder (Mac `SizeScanner`, `lstat` only, never reads contents). The
/// scan performs no mutating verb (a Mac test proves it). Hard-linked files are counted once; sizes are allocated bytes.
public struct SizeScan: Codable, Hashable, Sendable, Identifiable {
    public var recipeID: RecipeID
    /// `~`-relative.
    public var path: String
    public var state: SizeState
    public var reason: NotMeasuredReason?
    public var fingerprint: TreeFingerprint
    /// The source is a symbolic link (somebody, maybe Outboard, already redirected it). Never offered; never moved.
    public var isLink: Bool
    /// Where the link points, `~`-relative when under home. For display only.
    public var linkTarget: String?
    /// The errno of the walk when it failed (the matrix in "Copy diagnostics"). No file names.
    public var errnoCode: Int32?
    public var stamp: FileStamp?
    public var measuredAt: Date

    public init(recipeID: RecipeID, path: String, state: SizeState, reason: NotMeasuredReason? = nil,
                fingerprint: TreeFingerprint = TreeFingerprint(), isLink: Bool = false, linkTarget: String? = nil,
                errnoCode: Int32? = nil, stamp: FileStamp? = nil, measuredAt: Date) {
        self.recipeID = recipeID
        self.path = path
        self.state = state
        self.reason = reason
        self.fingerprint = fingerprint
        self.isLink = isLink
        self.linkTarget = linkTarget
        self.errnoCode = errnoCode
        self.stamp = stamp
        self.measuredAt = measuredAt
    }

    public var id: String { "\(recipeID)|\(path)" }
    public var allocatedBytes: UInt64 { fingerprint.allocatedBytes }
}

/// What the plan says about one catalogue entry. Exactly one status per entry; the headline counts only `.movable`.
public enum PlanStatus: String, Codable, CaseIterable, Sendable {
    /// Automated, enabled in this build, source present, not already redirected, 1 GB or more: counted in the headline.
    case movable
    /// Automated but `verifiedOnRealMac` is false and the "Show moves not yet tried on a real Mac" preference is off.
    case hiddenUntilVerified
    /// A guided card: Outboard measures and explains, the vendor's app moves it. Not in the headline.
    case guided
    /// A never card: shown with its reason.
    case neverMove
    /// Already redirected (a link, or the setting already points at a drive).
    case alreadyMoved
    /// The source folder does not exist on this Mac.
    case absent
    /// Present but under `Limits.minOfferBytes`.
    case belowThreshold
    /// Present but the size could not be read (reason in `notMeasuredReason`).
    case notMeasured
    /// The recipe needs a newer macOS than this one.
    case needsNewerMacOS
}

/// One row of the Plan screen and one input of the Storage Plan card. Built by Core `StoragePlanBuilder` from the catalogue,
/// the size scans, the preferences and the OS version. Every count the UI shows comes from this (one model).
public struct PlanItem: Codable, Hashable, Sendable, Identifiable {
    public var recipeID: RecipeID
    public var name: String
    public var kind: MethodKind
    public var risk: RiskClass
    public var status: PlanStatus
    public var scans: [SizeScan]
    public var notMeasuredReason: NotMeasuredReason?
    /// Never cards: the reason shown on the card.
    public var neverReason: String?
    public var missingDriveEffect: String
    /// Not yet tried on a real Mac: the consent sheet and the row say so.
    public var isUnverified: Bool

    public init(recipeID: RecipeID, name: String, kind: MethodKind, risk: RiskClass, status: PlanStatus, scans: [SizeScan] = [],
                notMeasuredReason: NotMeasuredReason? = nil, neverReason: String? = nil, missingDriveEffect: String = "",
                isUnverified: Bool = false) {
        self.recipeID = recipeID
        self.name = name
        self.kind = kind
        self.risk = risk
        self.status = status
        self.scans = scans
        self.notMeasuredReason = notMeasuredReason
        self.neverReason = neverReason
        self.missingDriveEffect = missingDriveEffect
        self.isUnverified = isUnverified
    }

    public var id: RecipeID { recipeID }
    /// Allocated bytes over all parts (the recipe's folder and companions), hard links once.
    public var allocatedBytes: UInt64 { scans.reduce(0) { $0 + $1.allocatedBytes } }
    /// Some part was cut short: the number is a floor.
    public var isLowerBound: Bool { scans.contains { $0.state == .atLeast } }
    /// What this row adds to the headline: its bytes when movable and fully measured, otherwise 0.
    public var offeredBytes: UInt64 { status == .movable && !isLowerBound ? allocatedBytes : 0 }
}

/// The ranked plan: what the Plan screen lists and the card summarises. `items` is sorted by the builder: movable by bytes
/// descending, then guided, then not measured, then the rest, then never cards.
public struct StoragePlan: Codable, Hashable, Sendable {
    public var items: [PlanItem]
    public var measuredAt: Date

    public init(items: [PlanItem], measuredAt: Date) {
        self.items = items
        self.measuredAt = measuredAt
    }

    public var movable: [PlanItem] { items.filter { $0.status == .movable } }
    public var guided: [PlanItem] { items.filter { $0.status == .guided } }
    public var never: [PlanItem] { items.filter { $0.status == .neverMove } }
    /// Hidden moves whose folder is on this Mac at 1 GB or more: the card and the Plan screen's hidden note mention only these.
    public var hiddenPresent: [PlanItem] { items.filter { $0.status == .hiddenUntilVerified && $0.allocatedBytes >= Limits.minOfferBytes } }
    /// Sum of unrounded bytes of the movable rows: the headline's number before rounding.
    public var headlineBytes: UInt64 { movable.reduce(0) { $0 + $1.offeredBytes } }
}

// MARK: - The Storage Plan card (APP6 §3.3)

public enum CardVariant: String, Codable, CaseIterable, Sendable {
    /// At least one movable folder of 1 GB or more: "Your Mac could free up to 87 GB".
    case plan
    /// As `plan`, plus a muted line for guided apps (not in the total).
    case planWithGuided
    /// A folder needs Full Disk Access and it was not granted: that row says "not measured".
    case partlyMeasured
    /// Movable total under 5 GB: "Nothing big to move". No share button.
    case small
    /// No catalogued folder over 1 GB.
    case nothingFound
    /// At least one relocation is active: "Moved 41 GB to your Outboard drive".
    case afterMoves
}

/// One bar on the card. `fraction` is proportional to the **unrounded** bytes (largest = 1.0); `text` is rounded by the
/// largest-remainder method so the rows add up to the headline (a Core test asserts it). Labels never truncate.
public struct CardRow: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var bytes: UInt64
    /// "41 GB". For a row that was not measured: "not measured".
    public var text: String
    public var fraction: Double
    /// "needs Full Disk Access" on a not-measured row.
    public var note: String?

    public init(id: String, label: String, bytes: UInt64, text: String, fraction: Double, note: String? = nil) {
        self.id = id
        self.label = label
        self.bytes = bytes
        self.text = text
        self.fraction = fraction
        self.note = note
    }
}

/// The shareable card as plain text and numbers. Rendered by `App/Report/PlanCardView.swift` (1200x630, `ImageRenderer`),
/// copied as text by Core `StoragePlanText`. It never shows paths, file names, the user's name, drive names or UUIDs.
public struct StoragePlanCard: Codable, Hashable, Sendable {
    public var variant: CardVariant
    public var headline: String
    public var rows: [CardRow]
    /// "and 2 more (3 GB)" when there are more than three movable rows.
    public var moreLine: String?
    /// "Also on this Mac: Photos library 212 GB. Photos moves it itself; Outboard shows the steps." Not in the total.
    public var guidedLines: [String]
    /// "Measured on this Mac. Nothing was moved." (or the after-moves ledger line)
    public var measuredLine: String
    /// "Sizes are what these folders take on disk. Space comes back when the originals are trashed and the Trash is emptied."
    public var footnote: String
    public var website: String
    /// Unrounded total of the counted rows.
    public var totalBytes: UInt64
    /// "Sample data" watermark in demo mode.
    public var isSample: Bool
    /// False when the app names are turned into "3 folders".
    public var showsAppNames: Bool
    public var measuredAt: Date

    public init(variant: CardVariant, headline: String, rows: [CardRow], moreLine: String? = nil, guidedLines: [String] = [],
                measuredLine: String, footnote: String, website: String = Names.websiteShort, totalBytes: UInt64,
                isSample: Bool = false, showsAppNames: Bool = true, measuredAt: Date) {
        self.variant = variant
        self.headline = headline
        self.rows = rows
        self.moreLine = moreLine
        self.guidedLines = guidedLines
        self.measuredLine = measuredLine
        self.footnote = footnote
        self.website = website
        self.totalBytes = totalBytes
        self.isSample = isSample
        self.showsAppNames = showsAppNames
        self.measuredAt = measuredAt
    }

    /// The share button is hidden on the "small" and "nothing found" cards.
    public var isShareable: Bool { variant != .small && variant != .nothingFound }
}
