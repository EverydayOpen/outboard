import Foundation

/// One row of the three-line space ledger: "On Outboard drive after the move   41 GB   Outboard drive has 45 GB free now".
public struct LedgerLine: Codable, Hashable, Sendable {
    public var label: String
    public var amount: String
    public var note: String

    public init(label: String, amount: String, note: String) {
        self.label = label
        self.amount = amount
        self.note = note
    }
}

/// Everything the consent sheet says. The live "Before you start" rows (which apps are running) come from `RunningCheck.blockers`.
public struct ConsentSheet: Codable, Hashable, Sendable {
    public var title: String
    public var subtitle: String
    /// "Not yet tried on a real Mac." when the recipe has not been closed in `docs/VERIFY_LOG.md` (added from the flag, never from the recipe).
    public var unverifiedLine: String?
    public var whatChanges: String
    public var whatToKnow: [String]
    /// The recipe's boxes, then one per eligibility acknowledgement. Every one must be ticked.
    public var checkboxes: [ConsentCheckbox]
    /// Shown quietly: format and speed warnings.
    public var warnings: [String]
    public var permissionNote: String
    /// "Ollama can restart by itself ..." when the recipe's app may relaunch.
    public var relaunchNote: String?
    /// A line to copy, shown as text only. Outboard never edits shell files.
    public var envLine: String?
    public var ledger: [LedgerLine]
    /// "Move 41 GB": the button names the amount.
    public var moveButtonTitle: String
    public var cancelButtonTitle: String
    /// Cancel is the default button for recipes that can't be replaced.
    public var cancelIsDefault: Bool
    public var footerLink: String

    public init(title: String, subtitle: String, unverifiedLine: String?, whatChanges: String, whatToKnow: [String], checkboxes: [ConsentCheckbox],
                warnings: [String], permissionNote: String, relaunchNote: String?, envLine: String?, ledger: [LedgerLine], moveButtonTitle: String,
                cancelButtonTitle: String = "Cancel", cancelIsDefault: Bool, footerLink: String = "What happens if I unplug the drive?") {
        self.title = title
        self.subtitle = subtitle
        self.unverifiedLine = unverifiedLine
        self.whatChanges = whatChanges
        self.whatToKnow = whatToKnow
        self.checkboxes = checkboxes
        self.warnings = warnings
        self.permissionNote = permissionNote
        self.relaunchNote = relaunchNote
        self.envLine = envLine
        self.ledger = ledger
        self.moveButtonTitle = moveButtonTitle
        self.cancelButtonTitle = cancelButtonTitle
        self.cancelIsDefault = cancelIsDefault
        self.footerLink = footerLink
    }
}

/// "Use the move for good?" The primary button is never the default for a recipe that can't be replaced.
public struct ConfirmDialog: Codable, Hashable, Sendable {
    public var title: String
    public var body: String
    public var checkboxText: String
    public var cancelTitle: String
    public var confirmTitle: String
    public var confirmIsDefault: Bool

    public init(title: String, body: String, checkboxText: String, cancelTitle: String, confirmTitle: String, confirmIsDefault: Bool) {
        self.title = title
        self.body = body
        self.checkboxText = checkboxText
        self.cancelTitle = cancelTitle
        self.confirmTitle = confirmTitle
        self.confirmIsDefault = confirmIsDefault
    }
}

public enum ConsentSheetText {
    /// What a recipe's own unplug bullet must say before it names the note or the setting change: the guard acts only while Outboard runs.
    /// `RecipeValidator` requires it for every recipe whose `onDriveMissing` is `parkPlaceholder` or `revertSetting`.
    public static let whileRunningPhrase = "While Outboard is running"

    /// The one fixed bullet added to the sheet of every recipe that parks a note or reverts a setting.
    public static let guardOnlyWhileRunning = "Outboard does this only while it is running. If it is closed when the drive is unplugged, the app finds a missing folder, or a setting that still points at the drive, until you open Outboard."

    public static func sheet(recipe: Recipe, scan: SizeScan, drive: VolumeRef, mountPoint: String, report: EligibilityReport, free: UInt64,
                             unverified: Bool) -> ConsentSheet {
        let consent = recipe.consent
        let what = consent?.what ?? recipe.name
        let bytes = scan.allocatedBytes
        let leaf = PathNorm.leaf(PathText.expandTilde(scan.path, home: "/"))
        var boxes = consent?.checkboxes ?? []
        for ack in report.acks { boxes.append(ConsentCheckbox(id: ack.ackID, text: ackText(ack))) }
        let app = RecipeNames.appName(recipe.id)
        var know = consent?.whatToKnow ?? []
        if recipe.onDriveMissing == .parkPlaceholder || recipe.onDriveMissing == .revertSetting {
            let after = know.firstIndex { $0.contains(whileRunningPhrase) }.map { $0 + 1 } ?? know.count
            know.insert(guardOnlyWhileRunning, at: after)
        }
        var relaunch: String?
        if recipe.mayRelaunch {
            relaunch = "\(app) can restart by itself. Quit it from its menu bar icon and wait for its row above to say Not running."
        }
        var env: String?
        var warnings = report.warnings.map(\.message)
        if let line = recipe.envLine {
            env = EnvLine.render(line, mountPoint: mountPoint, recipeID: recipe.id)
            if env == nil { warnings.append(EnvLine.setYourself) }
        }
        return ConsentSheet(
            title: "Move \(what) to \(drive.label)?",
            subtitle: [Format.bytes(bytes), recipe.kind.displayName, recipe.riskClass.displayName].joined(separator: " \u{00B7} "),
            unverifiedLine: unverified ? Names.notTriedMarker : nil,
            whatChanges: consent?.whatChanges ?? "",
            whatToKnow: know,
            checkboxes: boxes,
            warnings: warnings,
            permissionNote: "macOS may ask \(app) for permission to use the drive the first time.",
            relaunchNote: relaunch,
            envLine: env,
            ledger: ledger(bytes: bytes, drive: drive, free: free, state: .planned, leaf: leaf.isEmpty ? nil : leaf),
            moveButtonTitle: "Move \(Format.bytes(bytes))",
            cancelIsDefault: recipe.riskClass == .irreplaceable)
    }

    private static func ackText(_ v: EligibilityVerdict) -> String {
        if v.rule == .e16 && v.unknownSignal == nil {
            return "This drive isn't encrypted. I understand anyone with the drive can read what is on it."
        }
        return v.message
    }

    /// The three lines that always appear together, because the space does not come back until the end (BUILD_PLAN §8.1).
    /// `leaf` names the renamed original ("DerivedData"); without it the line says "the original".
    public static func ledger(bytes: UInt64, drive: VolumeRef, free: UInt64, state: MoveState, leaf: String? = nil) -> [LedgerLine] {
        let size = Format.bytes(bytes)
        let label = drive.label
        let kept = leaf.map { "\($0)\(Names.beforeMoveSuffix)" } ?? "the original with \(Names.beforeMoveSuffix) added to its name"
        switch state {
        case .planned, .preflight, .copying, .verifying, .swapped:
            return [
                LedgerLine(label: "On \(label) after the move", amount: size, note: "\(label) has \(Format.bytes(free)) free now"),
                LedgerLine(label: "Still on your Mac", amount: size, note: "as \(kept), until you confirm"),
                LedgerLine(label: "Back on your Mac's storage", amount: "0 GB", note: "after you confirm and empty the Trash"),
            ]
        case .confirmed, .originalTrashed:
            return [
                LedgerLine(label: "On \(label)", amount: size, note: "\(label) has \(Format.bytes(free)) free now"),
                LedgerLine(label: "In the Trash", amount: size, note: "as \(kept)"),
                LedgerLine(label: "Back on your Mac's storage", amount: size, note: "after you empty the Trash"),
            ]
        case .rolledBack, .aborted, .returned, .forgotten:
            return []
        }
    }

    /// "Use the move for good?" after the user has tried the app.
    public static func confirmDialog(record: RelocationRecord) -> ConfirmDialog {
        let recipe = Catalogue.recipe(record.recipeID)
        let what = RecipeNames.capitalized(recipe?.consent?.what ?? record.recipeName)
        let verb = RecipeNames.isPlural(recipe?.consent?.what ?? record.recipeName) ? "are" : "is"
        let leaf = PathNorm.leaf(record.macPath)
        let size = Format.bytes(record.logicalBytes)
        let app = RecipeNames.appName(record.recipeID)
        return ConfirmDialog(
            title: "Use the move for good?",
            body: "\(what) \(verb) now on \(record.volume.label). Your original is still on this Mac as \(leaf)\(Names.beforeMoveSuffix) (\(size)). Confirming does two things: it ends the option to roll back, and it moves the original to the Trash. Your Mac gets the space back when you empty the Trash.",
            checkboxText: "I opened \(app) and my data is there.",
            cancelTitle: "Not yet",
            confirmTitle: "Confirm and move to Trash",
            confirmIsDefault: record.risk != .irreplaceable)
    }

    /// "Roll back to your original from 3 Oct. 12 files changed on Outboard drive since then; they stay on the drive and are not copied back."
    public static func rollbackNote(record: RelocationRecord, changedFiles: Int) -> String {
        let from = Format.shortDate(record.createdAt)
        guard changedFiles > 0 else { return "Roll back to your original from \(from)." }
        return "Roll back to your original from \(from). \(Format.count(changedFiles, "file")) changed on \(record.volume.label) since then; they stay on the drive and are not copied back."
    }

    /// The two-step Forget flow: loud, never the default focus.
    public static let forgetWarning = "Outboard cannot get this data back without the drive."
}
