import Foundation

/// What `lstat` (never followed) says about the live path of a relocation. The Mac layer gathers it; Core decides.
public enum PathKind: String, Codable, CaseIterable, Sendable {
    /// Our original: a real directory whose stamp matches the one recorded (the move's source stamp).
    case real
    /// A symbolic link we wrote: its target is the recorded one.
    case link
    /// Our placeholder: a small regular file carrying our marker text, mode 0444, stamp unchanged.
    case placeholder
    /// Nothing at the path.
    case missing
    /// Anything else: a directory without our stamp or marker, a link we did not write, a file that is not our placeholder.
    case other
}

/// For `defaults` recipes: what `defaults read` says about the key now.
public enum SettingFact: String, Codable, CaseIterable, Sendable {
    /// The value the move wrote.
    case new
    /// The value (or absence) from before the move.
    case prior
    /// Something else: the user or the app changed it.
    case other
    /// Not a `defaults` recipe.
    case notApplicable
}

/// The facts recovery reads after a crash or on mount. Eight small values; the table is exhaustive over them.
public struct RecoveryFacts: Codable, Hashable, Sendable {
    /// The recorded drive is mounted and its UUID and sentinel match (`d`).
    public var drivePresent: Bool
    /// `X`
    public var path: PathKind
    /// `<name>.before-move` is present with the recorded stamp (`B`).
    public var beforeMovePresent: Bool
    /// `.staging-<id>` is present on the drive (`S`).
    public var stagingPresent: Bool
    /// The published copy is present on the drive (`F`).
    public var publishedPresent: Bool
    /// `K`
    public var setting: SettingFact
    /// The link resolves to the recorded volume, the sentinel matches and the listing count equals the manifest.
    public var healthPasses: Bool
    /// `Parked/<id>/link` exists.
    public var parkedLinkPresent: Bool
    /// A return of this relocation (a later record, direction `returnToMac`) reached Swapped: its copy took the path.
    public var returnSwapped: Bool

    public init(drivePresent: Bool, path: PathKind, beforeMovePresent: Bool, stagingPresent: Bool = false, publishedPresent: Bool = false,
                setting: SettingFact = .notApplicable, healthPasses: Bool = false, parkedLinkPresent: Bool = false,
                returnSwapped: Bool = false) {
        self.drivePresent = drivePresent
        self.path = path
        self.beforeMovePresent = beforeMovePresent
        self.stagingPresent = stagingPresent
        self.publishedPresent = publishedPresent
        self.setting = setting
        self.healthPasses = healthPasses
        self.parkedLinkPresent = parkedLinkPresent
        self.returnSwapped = returnSwapped
    }
}

/// Why recovery stops and shows the facts instead of acting.
public enum NeedsAttentionReason: String, Codable, CaseIterable, Sendable {
    /// Both the live path and `<name>.before-move` hold a directory: two originals.
    case twoOriginals
    /// The path is not the original and nothing explains it (should be impossible).
    case originalNotAtPath
    /// The journal and the disk disagree in a way the table does not cover.
    case unrecognisedState
}

/// What recovery (or the guard's reconcile on launch) tells the Mac layer to do. Each case is carried out through the same
/// single-site verbs and journal rules as a normal move, so recovery obeys every rule. There is no case that deletes,
/// overwrites or merges: the Core simulator asserts it for every row of the table.
public enum RecoveryAction: Codable, Hashable, Sendable {
    /// Nothing to do (already consistent).
    case noop
    /// Mark the move Aborted (interrupted). Nothing on the Mac was changed. `labelLeftovers`: staging or a published copy exists on
    /// the drive and is labelled "Incomplete copy" and offered for the Trash. No resume in v1.
    case abort(AbortReason, labelLeftovers: Bool)
    /// Rollback step R3: rename `<name>.before-move` back to `<name>`.
    case rollbackOriginal
    /// Something new sits at the path: rename it `<name>.created-while-moving`, then roll back.
    case setAsideForeignThenRollback
    /// The redirect is in place and healthy: write the missing result lines and treat the move as Swapped.
    case adoptSwapped
    /// Stay Swapped (confirm is only a journal event).
    case remainSwapped
    /// Stay Confirmed (the trash did not happen): "Ready to move the safety copy to the Trash."
    case remainConfirmed
    /// The safety copy is gone from the path: mark OriginalTrashed with "result not recorded".
    case markTrashedUnrecorded
    /// Continue an interrupted rollback by observing facts; each step is idempotent.
    case continueRollback
    /// The placeholder is in place: write the missing park result.
    case finishPark
    /// Create the placeholder (and keep the parked link as evidence).
    case createPlaceholder
    /// Put the link back (drive present, placeholder or parked link).
    case unpark
    /// Rebuild the link from the journal (target recomputed from the current mount point).
    case recreateLink
    /// A return swapped its copy in and the process stopped before it closed this record: write the missing `returned` result.
    case markReturned
    /// Show the facts; touch nothing.
    case needsAttention(NeedsAttentionReason)
}
