import Foundation

/// An in-memory model of what a `RecoveryAction` does to the facts, used by the Core tests and by the demo backend. It carries out each
/// action as the Mac verbs would (every rename needs an empty target; nothing is removed) and reports every way an action could lose
/// data: an overwrite, a merge, a lost original, a copy that is not there, an action whose precondition does not hold.
public enum RecoverySimulator {
    public struct Outcome: Sendable {
        public var record: RelocationRecord
        public var facts: RecoveryFacts
        /// Problems found while applying the action (an overwrite, a missing precondition ...). Empty means clean.
        public var violations: [String]
    }

    /// Applies one action to a record and its facts. The record afterwards carries the state and the last journal mark the Mac layer
    /// would have written; the facts afterwards are what `lstat` would say.
    public static func apply(_ action: RecoveryAction, record: RelocationRecord, facts: RecoveryFacts) -> Outcome {
        var r = record
        var f = facts
        var v: [String] = []
        let isDefaults = r.method == .defaults
        func mark(_ step: MoveStep) { r.last = JournalMark(step: step, phase: .result, status: .ok) }
        func redirectLive() -> Bool { isDefaults ? f.setting == .new : f.path == .link }
        func revertSetting() { if isDefaults && f.setting == .new { f.setting = .prior } }
        /// R3: rename `<name>.before-move` back. The path must be empty.
        func renameBack() {
            if !f.beforeMovePresent { v.append("rolled back with no original to restore"); return }
            if f.path != .missing { v.append("renamed the original over something that is at the path (overwrite)"); return }
            f.path = .real
            f.beforeMovePresent = false
        }

        switch action {
        case .noop, .needsAttention:
            break
        case .abort(let reason, _):
            // A return changes nothing on the Mac before its swap, so only a move to the drive has an original to protect.
            if r.direction == .toDrive && (f.path != .real || f.beforeMovePresent) { v.append("aborted while the original is not the only thing at its path") }
            r.state = .aborted
            r.abort = reason
            mark(.abort)
        case .rollbackOriginal:
            if isDefaults && f.setting == .new { v.append("restored the original but the setting still points at the drive") }
            renameBack()
            r.state = Recovery.resultingState(of: action, record: record)
            mark(.undoSetAside)
        case .setAsideForeignThenRollback:
            if f.path == .other {
                f.path = .missing   // the foreign item is renamed to <name>.created-while-moving and kept
            } else {
                v.append("set aside something that is not a foreign item")
            }
            revertSetting()
            renameBack()
            r.state = Recovery.resultingState(of: action, record: record)
            mark(.undoSetAside)
        case .continueRollback:
            // R2: undo the redirect.
            if f.path == .link && !isDefaults { f.path = .missing; f.parkedLinkPresent = true }
            revertSetting()
            // R3: put the original back; anything else at the path is set aside, never merged.
            if f.path == .real {
                if f.beforeMovePresent { v.append("two originals: continuing would merge them") }
            } else {
                if f.path == .placeholder || f.path == .other { f.path = .missing }
                renameBack()
            }
            r.state = Recovery.resultingState(of: action, record: record)
            mark(.undoSetAside)
        case .adoptSwapped:
            if !redirectLive() || !f.healthPasses || !f.publishedPresent || !f.drivePresent || !f.beforeMovePresent {
                v.append("adopted a redirect that is not in place, healthy and backed by a copy and the original")
            }
            r.state = .swapped
            r.safetyCopy = .kept
            mark(.swapped)
        case .remainSwapped:
            if r.state != .swapped { v.append("stayed swapped from another state") }
            mark(.recover)
        case .remainConfirmed:
            if r.state != .confirmed || !f.beforeMovePresent { v.append("stayed confirmed without the safety copy") }
            mark(.recover)
        case .markTrashedUnrecorded:
            if f.beforeMovePresent { v.append("recorded the safety copy as gone while it is there") }
            r.state = .originalTrashed
            r.safetyCopy = .inTrash
            mark(.trash)
        case .finishPark:
            let parked = isDefaults ? f.setting == .prior : f.path == .placeholder
            if !parked { v.append("finished a park that did not happen") }
            r.isParked = true
            mark(.park)
        case .createPlaceholder:
            if isDefaults || f.path != .missing { v.append("put a note where something already is") }
            else { f.path = .placeholder }
            r.isParked = true
            mark(.park)
        case .unpark:
            if !f.drivePresent { v.append("unparked while the drive is away") }
            if isDefaults {
                if f.setting == .prior { f.setting = .new } else if f.setting != .new { v.append("unparked a setting that is neither parked nor in place") }
            } else if f.path == .placeholder {
                f.path = .link   // the note is renamed into Parked/, a new link is made from the current mount point
            } else if f.path != .link {
                v.append("unparked something that is neither the note nor the link")
            }
            r.isParked = false
            mark(.unpark)
        case .markReturned:
            if !f.returnSwapped || (f.path != .other && f.path != .real) || r.state.isTerminal {
                v.append("closed a record as returned without a swapped return and a plain folder at the path")
            }
            r.state = .returned
            mark(.returned)
        case .recreateLink:
            if isDefaults || f.path != .missing || !f.drivePresent || !f.publishedPresent {
                v.append("rebuilt a link where something is, or to a copy that is not there")
            } else {
                f.path = .link
            }
            mark(.recreate)
        }

        // The health the Mac layer would read now.
        switch action {
        case .noop, .needsAttention, .remainSwapped, .remainConfirmed, .markTrashedUnrecorded, .adoptSwapped, .markReturned: break
        default:
            f.healthPasses = (isDefaults ? f.setting == .new : f.path == .link) && f.drivePresent && f.publishedPresent
        }
        return Outcome(record: r, facts: f, violations: v)
    }

    /// Every way this action, on this record and these facts, breaks the rules of crash recovery. Empty means it is fine.
    ///
    /// The four theorem checks: (a) no step deletes, overwrites or merges (each step's precondition holds); (b) afterwards the
    /// original is at the path, or the path redirects to a verified copy, whenever the action claims so; (c) a complete copy of the
    /// data still exists somewhere; (d) deciding again on the result gives `.noop` (or the same `.needsAttention`).
    public static func violations(of action: RecoveryAction, record: RelocationRecord, facts: RecoveryFacts) -> [String] {
        let out = apply(action, record: record, facts: facts)
        var v = out.violations
        let after = out.facts

        func originals(_ f: RecoveryFacts) -> Int { (f.path == .real ? 1 : 0) + (f.beforeMovePresent ? 1 : 0) }
        func redirectOK(_ f: RecoveryFacts) -> Bool {
            let live = record.method == .defaults ? f.setting == .new : f.path == .link
            return live && f.healthPasses && f.publishedPresent && f.drivePresent
        }

        // (b) the action's own promise.
        switch action {
        case .abort, .rollbackOriginal, .setAsideForeignThenRollback, .continueRollback:
            if record.direction == .toDrive && after.path != .real { v.append("the original is not at its path afterwards") }
        case .adoptSwapped:
            if !redirectOK(after) { v.append("the redirect does not lead to a verified copy afterwards") }
        case .finishPark, .createPlaceholder:
            if record.method != .defaults && after.path != .placeholder { v.append("no note at the path afterwards") }
        case .unpark, .recreateLink:
            if !(record.method == .defaults ? after.setting == .new : after.path == .link) { v.append("the redirect is not in place afterwards") }
        case .noop, .remainSwapped, .remainConfirmed, .markTrashedUnrecorded, .needsAttention, .markReturned:
            break
        }
        // (c) nothing that held the data is gone: originals are not lost, staging and the published copy are kept.
        if originals(facts) >= 1 && originals(after) == 0 && !redirectOK(after) { v.append("no original and no verified copy afterwards") }
        if facts.stagingPresent != after.stagingPresent || facts.publishedPresent != after.publishedPresent {
            v.append("a copy on the drive changed")
        }
        if originals(after) < min(1, originals(facts)) { v.append("an original was lost") }
        // (d) idempotence.
        let again = Recovery.decide(record: out.record, facts: after)
        let stable: Bool
        if case .needsAttention = action { stable = again == action } else { stable = again == .noop }
        if !stable { v.append("deciding again gives \(again), not a no-op") }
        return v
    }
}
