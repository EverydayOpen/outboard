import Foundation

/// Unpark preconditions, all of them (BUILD_PLAN §4.4): the drive's UUID and sentinel match; macOS has not blocked access; the drive is
/// writable; the placeholder is unchanged; the target app is not running; and the checks on return passed (the bounded sample after a
/// clean eject, every unchanged file after "Check and reconnect" when the drive was removed without ejecting). The first one that fails
/// is the reason shown on the Held pill and in the banner. Unknown fails closed.
public enum Held {
    public static func evaluate(facts: GuardFacts, record: RelocationRecord, check: ReturnCheckResult?) -> HeldDecision {
        // 1. The drive is the one we moved the data to.
        if facts.drive == .absent {
            return .hold(facts.sameNameDifferentDrive ? .wrongDrive : .quickCheckFailed)
        }
        if facts.targetErrno == 1 || facts.targetErrno == 13 { return .hold(.needsPermission) }
        if facts.sentinel != .ok || facts.targetOnRecordedVolume == .no { return .hold(.wrongDrive) }
        // 2. We can write to it.
        if facts.drive == .mountedReadOnlyOrLocked { return .hold(.readOnlyOrLocked) }
        // 3. The note we left is still ours, and the app that uses the data is closed.
        if !facts.placeholderUnchanged { return .hold(.quickCheckFailed) }
        if facts.targetApp != .notRunning { return .hold(.appRunning) }
        // 4. The checks on return.
        let needsFull = record.needsCheckBeforeReconnect || (facts.removal?.needsCheckBeforeReconnect ?? false)
        guard let check else { return .hold(needsFull ? .uncleanRemoval : .quickCheckFailed) }
        if needsFull {
            guard check.fullCheck else { return .hold(.uncleanRemoval) }
            return check.mismatches == 0 ? .clear : .hold(.sampleMismatch)
        }
        if check.fullCheck { return check.mismatches == 0 ? .clear : .hold(.sampleMismatch) }
        guard check.quickPassed else { return .hold(.quickCheckFailed) }
        return check.mismatches == 0 ? .clear : .hold(.sampleMismatch)
    }

    /// "Reconnect anyway" is offered for recipes that rebuild themselves or are large to download again, never for irreplaceable ones.
    public static func allowsReconnectAnyway(_ record: RelocationRecord) -> Bool {
        record.risk != .irreplaceable
    }
}
