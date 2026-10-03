import Foundation

/// Crash recovery as a table (safety-ux §2.5, BUILD_PLAN §4.4). Pure and idempotent: the Mac layer gathers `RecoveryFacts` with `lstat`
/// and volume lookups, asks `decide`, and carries the action out through the same single-site verbs as a normal move, so recovery obeys
/// every rule. `RecoverySimulator` proves, for every record type and every combination of facts, that no action deletes, overwrites or
/// merges, that the original or a verified copy is always there, and that deciding again after the action gives `.noop`.
///
/// A crash before the original is renamed aborts and starts over (there is no resume in v1); after the rename the disk is observed
/// and the move is finished or rolled back. Anything the table does not recognise is `.needsAttention`: the facts are shown and nothing
/// is touched.
public enum Recovery {
    public static func decide(record r: RelocationRecord, facts f: RecoveryFacts) -> RecoveryAction {
        if r.state.isTerminal { return .noop }
        if r.direction == .returnToMac { return decideReturn(r, f) }
        switch r.state {
        case .planned, .preflight, .copying, .verifying: return decideBeforeSwap(r, f)
        case .swapped, .confirmed, .originalTrashed: return decideActive(r, f)
        case .rolledBack, .aborted, .returned, .forgotten: return .noop
        }
    }

    /// The state the record is in once the action's journal lines are written. A rollback of a move that never reached `swapped`
    /// ends `aborted`: the original is back and, net, the Mac is as it was.
    public static func resultingState(of action: RecoveryAction, record r: RelocationRecord) -> MoveState {
        switch action {
        case .noop, .finishPark, .createPlaceholder, .unpark, .recreateLink, .needsAttention: return r.state
        case .markReturned: return .returned
        case .abort: return .aborted
        case .rollbackOriginal, .setAsideForeignThenRollback, .continueRollback: return r.state == .swapped ? .rolledBack : .aborted
        case .adoptSwapped, .remainSwapped: return .swapped
        case .remainConfirmed: return .confirmed
        case .markTrashedUnrecorded: return .originalTrashed
        }
    }

    // MARK: - Before the swap (planned ... verifying, including the swap window)

    private enum Window { case beforeRename, renameIntent, afterRename }

    private static func window(_ r: RelocationRecord) -> Window {
        switch r.last.step {
        case .setAside:
            return r.last.phase == .result && (r.last.status == nil || r.last.status == .ok) ? .afterRename : .renameIntent
        case .redirect, .swapped, .undoRedirect, .undoSetAside, .setAsideForeign, .rollback:
            return .afterRename
        default:
            return .beforeRename
        }
    }

    private static func decideBeforeSwap(_ r: RelocationRecord, _ f: RecoveryFacts) -> RecoveryAction {
        let isDefaults = r.method == .defaults
        let redirected = isDefaults && f.setting == .new
        let leftovers = f.stagingPresent || f.publishedPresent
        switch (f.path, f.beforeMovePresent) {
        case (.real, false):
            // Nothing was renamed: the original is where it was. Stop, label what the copy left on the drive, start over later.
            return redirected ? .needsAttention(.unrecognisedState) : .abort(.interrupted, labelLeftovers: leftovers)
        case (.real, true):
            return .needsAttention(.twoOriginals)
        case (.missing, true):
            // The rename happened. Put the original back; if the setting already points at the drive, put that back first.
            if isDefaults && window(r) == .afterRename && f.setting == .new && f.healthPasses && f.publishedPresent && f.drivePresent {
                return .adoptSwapped
            }
            return redirected ? .continueRollback : .rollbackOriginal
        case (.other, true):
            return .setAsideForeignThenRollback
        case (.link, true):
            // A link is the redirect of a link recipe; at a setting's path it is something nobody here made.
            guard window(r) == .afterRename, !isDefaults else { return .needsAttention(.unrecognisedState) }
            if f.healthPasses && f.publishedPresent && f.drivePresent { return .adoptSwapped }
            return .continueRollback
        case (.placeholder, true):
            return .needsAttention(.unrecognisedState)
        case (.missing, false), (.other, false), (.link, false), (.placeholder, false):
            return .needsAttention(.originalNotAtPath)
        }
    }

    // MARK: - After the swap (swapped, confirmed, originalTrashed)

    private static func redirectInPlace(_ r: RelocationRecord, _ f: RecoveryFacts) -> Bool {
        r.method == .defaults ? f.setting == .new : f.path == .link
    }

    private static func parkedInPlace(_ r: RelocationRecord, _ f: RecoveryFacts) -> Bool {
        r.method == .defaults ? f.setting == .prior : f.path == .placeholder
    }

    /// What an active relocation needs when nothing was pending: usually nothing (the guard watches it); never a guess.
    private static func activeBase(_ r: RelocationRecord, _ f: RecoveryFacts) -> RecoveryAction {
        switch f.path {
        case .real:
            return f.beforeMovePresent ? .needsAttention(.twoOriginals) : .needsAttention(.unrecognisedState)
        case .missing:
            if r.method == .defaults { return .noop }
            if !f.drivePresent { return .createPlaceholder }
            return f.publishedPresent ? .recreateLink : .needsAttention(.unrecognisedState)
        case .link, .placeholder, .other:
            return .noop
        }
    }

    private static func decideActive(_ r: RelocationRecord, _ f: RecoveryFacts) -> RecoveryAction {
        // A return that swapped its copy in and stopped before it closed this record: its own record says Swapped, and a plain folder
        // stands at the path (not the original: that was renamed). Without this the record would show "attention" for ever.
        if r.state == .confirmed || r.state == .originalTrashed, f.returnSwapped, f.path == .other || f.path == .real { return .markReturned }
        let base = activeBase(r, f)
        // A rollback the user started and a crash interrupted (only a swapped move can be rolled back). `undoRedirect` and the other
        // steps have other writers too (older logs have the guard putting a setting back with `undoRedirect`), so only a `rollback`
        // line in the journal makes them part of a rollback.
        if r.state == .swapped, r.rollbackStarted, [.rollback, .undoRedirect, .undoSetAside, .setAsideForeign].contains(r.last.step) {
            if f.path == .real { return f.beforeMovePresent ? .needsAttention(.twoOriginals) : .continueRollback }
            guard f.beforeMovePresent else { return .needsAttention(.originalNotAtPath) }
            if r.method == .defaults && (f.path == .link || f.path == .placeholder) { return .needsAttention(.unrecognisedState) }
            return f.path == .other ? .setAsideForeignThenRollback : .continueRollback
        }
        guard r.last.phase == .intent, base == .noop else { return base }
        switch r.last.step {
        case .confirm where r.state == .swapped:
            // Confirm is only a journal event: stay swapped.
            return .remainSwapped
        case .trash where r.state == .confirmed:
            return f.beforeMovePresent ? .remainConfirmed : .markTrashedUnrecorded
        case .park:
            return parkedInPlace(r, f) ? .finishPark : .noop
        case .unpark:
            if redirectInPlace(r, f) { return f.drivePresent && f.healthPasses ? .unpark : .noop }
            if parkedInPlace(r, f) { return f.drivePresent ? .unpark : .noop }
            return .noop
        default:
            return .noop
        }
    }

    // MARK: - A move back to the Mac

    /// A return copies the drive's data to `<name>.returning-<id>` beside the path and swaps it in. Recovery stays simple: before the
    /// swap, stop and label what was copied; anything else is shown, not touched.
    private static func decideReturn(_ r: RelocationRecord, _ f: RecoveryFacts) -> RecoveryAction {
        switch r.state {
        case .planned, .preflight, .copying, .verifying:
            switch f.path {
            case .link, .placeholder: return .abort(.interrupted, labelLeftovers: true)
            case .missing where r.method == .defaults && f.setting != .other: return .abort(.interrupted, labelLeftovers: true)
            default: return .needsAttention(.unrecognisedState)
            }
        default:
            return .noop
        }
    }

    // MARK: - What the user reads

    public static func message(for action: RecoveryAction, record r: RelocationRecord) -> String {
        let leaf = PathNorm.leaf(r.macPath)
        let app = RecipeNames.appName(r.recipeID)
        let drive = r.volume.label
        switch action {
        case .noop:
            return ""
        case .abort(_, let labelLeftovers):
            if labelLeftovers { return "Stopped part way. Your original was not touched. A partial copy is on \(drive); you can move it to the Trash or try again." }
            if r.state == .planned || r.state == .preflight { return "The move was interrupted before anything was copied. Nothing on your Mac was changed." }
            return "The move was interrupted. Nothing on your Mac was changed."
        case .rollbackOriginal, .continueRollback:
            if action == .continueRollback && r.state == .swapped { return "Finishing the undo." }
            return "Restored your original \(leaf) after an interruption."
        case .setAsideForeignThenRollback:
            return "Something new appeared at \(leaf) while the move was running. We set it aside as \(leaf)\(Names.createdWhileMovingSuffix) and restored your original."
        case .adoptSwapped:
            return "The move finished. Please check \(app) and confirm."
        case .remainSwapped:
            return "The move is ready. Waiting for you to confirm."
        case .remainConfirmed:
            return "Ready to move the safety copy to the Trash."
        case .markTrashedUnrecorded:
            return "The safety copy is gone from \(leaf)\(Names.beforeMoveSuffix); check the Trash."
        case .finishPark, .createPlaceholder:
            return "Put a note where \(leaf) was."
        case .unpark:
            return "Put \(leaf) back."
        case .recreateLink:
            return "Rebuilt the link for \(app)."
        case .markReturned:
            return "\(app) is back on your Mac. The copy on \(drive) stays there until you move it to the Trash."
        case .needsAttention(let reason):
            switch reason {
            case .twoOriginals:
                return "Two originals of \(leaf) are on your Mac: \(leaf) and \(leaf)\(Names.beforeMoveSuffix). Nothing was changed."
            case .originalNotAtPath:
                return "Your original \(leaf) is not where it should be. Nothing was changed."
            case .unrecognisedState:
                return "What is on disk doesn't match the activity log for this move. Nothing was changed."
            }
        }
    }
}
