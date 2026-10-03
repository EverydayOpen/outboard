import Foundation

/// The move state machine as pure functions (BUILD_PLAN §4.4). The journal line decides; a line that asks for an illegal step leaves
/// the state where it was and comes back with a problem the record shows.
public enum MoveMachine {
    /// `to` is one of `from.legalSuccessors`.
    public static func canTransition(_ from: MoveState, to: MoveState) -> Bool {
        from.legalSuccessors.contains(to)
    }

    public static func state(after entry: JournalEntry, current: MoveState) -> MoveState {
        apply(entry, current: current).state
    }

    public static let outOfOrderPrefix = "Ignored an out-of-order step"

    /// The state after one line, and a plain sentence when the line was ignored because it asked for an illegal step.
    public static func apply(_ entry: JournalEntry, current: MoveState) -> (state: MoveState, problem: String?) {
        guard let target = entry.state ?? impliedState(for: entry) else { return (current, nil) }
        if target == current { return (current, nil) }
        if canTransition(current, to: target) { return (target, nil) }
        return (current, "\(outOfOrderPrefix) (\(entry.step)): \(current.displayName) can't go to \(target.displayName).")
    }

    /// The state a known step implies when the line does not carry one. Only the lines that change the state imply one.
    public static func impliedState(for entry: JournalEntry) -> MoveState? {
        guard let step = entry.moveStep else { return nil }
        let ok = entry.status == nil || entry.status == .ok
        switch (step, entry.phase) {
        case (.preflight, .intent): return .preflight
        case (.copy, .intent): return .copying
        case (.verify, .intent): return .verifying
        case (.swapped, .result): return ok ? .swapped : nil
        case (.confirm, .result): return ok ? .confirmed : nil
        case (.trash, .result): return ok ? .originalTrashed : nil
        case (.rollback, .result): return ok ? .rolledBack : nil
        case (.abort, _): return .aborted
        case (.returned, .result): return ok ? .returned : nil
        case (.forget, .result): return ok ? .forgotten : nil
        default: return nil
        }
    }
}
