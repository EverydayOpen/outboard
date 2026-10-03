import Foundation

/// The twelve rows of the guard table (guard-tech §5.2, BUILD_PLAN §4.4) as pure functions over what `lstat` and the mount table
/// said. One reconcile = classify, then act on the state; a missed notification costs seconds, not correctness.
///
/// For a `defaults` relocation there is no link at the path. The Mac layer fills `GuardFacts.path` like this: `.link` while the setting
/// reads as the value the move wrote ("redirect in place"), `.placeholder` after a park has put the prior value back, `.other` when the
/// user or the app changed it to something else. Everything below then applies unchanged.
public enum GuardPolicy {
    static let eperm: Int32 = 1
    static let eacces: Int32 = 13

    public static func classify(_ f: GuardFacts) -> GuardState {
        if f.drive == .mountedReadOnlyOrLocked { return .lockedOrReadOnly }
        let blocked = f.targetErrno == eperm || f.targetErrno == eacces
        switch f.path {
        case .link:
            if f.linkIsForeign { return .foreign }
            if f.drive == .absent { return .park }
            if blocked { return .needsPermission }
            if f.sentinel != .ok { return .suspect }
            if f.drive == .mountedElsewhere { return .retarget }
            switch f.targetOnRecordedVolume {
            case .yes: return .healthy
            case .no: return .retarget
            case .unknown: return .suspect
            }
        case .placeholder:
            if f.drive == .absent { return .parked }
            if blocked { return .needsPermission }
            return f.sentinel == .ok ? .restore : .suspect
        case .other, .real:
            if f.linkIsForeign { return .foreign }
            return f.drive == .absent ? .divergedWhileAbsent : .diverged
        case .missing:
            return .recreate
        }
    }

    /// What the state asks the Mac layer to do. Every disk change goes through the single-site verbs, which check their own rules.
    public static func action(for state: GuardState, record: RelocationRecord) -> GuardAction {
        switch state {
        case .healthy, .parked: return .none
        case .retarget: return .retarget
        case .park:
            switch record.onDriveMissing {
            case .parkPlaceholder, .revertSetting: return .park
            case .leaveAlone, .none: return .reportOnly
            }
        case .restore: return .unpark
        case .recreate: return .recreate
        case .needsPermission, .divergedWhileAbsent, .diverged, .foreign, .suspect, .lockedOrReadOnly: return .reportOnly
        }
    }

    /// Derived, never stored (I10). The pill carries the word; colour never carries health alone.
    public static func health(state: GuardState, held: HeldReason?, record: RelocationRecord) -> Health {
        switch state {
        case .healthy, .retarget: return .healthy
        case .park, .parked: return .driveAway
        case .restore: return held == nil ? .driveAway : .held
        case .needsPermission, .lockedOrReadOnly: return .held
        case .divergedWhileAbsent, .diverged, .foreign: return .conflict
        case .recreate, .suspect: return .broken
        }
    }

    /// Records the guard watches: swapped, confirmed or trashed, drive-to-Mac. A return is a Mac-bound copy, not a redirect.
    public static func watched(_ records: [RelocationRecord]) -> [RelocationRecord] {
        records.filter { $0.direction == .toDrive && $0.isWatchedByGuard }
    }

    /// The published guard state. It carries no timestamps, so a timer tick that finds nothing new produces an equal value, and the
    /// app assigns it only when it changed.
    public static func snapshot(records: [RelocationRecord], facts: [String: GuardFacts], held: [String: HeldReason],
                                lastReturn: [String: ReturnReport], parkFailed: Set<String> = []) -> GuardSnapshot {
        var healths: [RelocationHealth] = []
        var used: [RelocationRecord] = []
        for record in watched(records) {
            guard let f = facts[record.id] else { continue }
            let state = classify(f)
            var reason = held[record.id]
            // A setting that could not be put back because its app is running is waiting for the app to quit, not failing: the guard
            // tries again on its next pass. Only a running app counts; an unreadable process list is not "quit it".
            if reason == nil, state == .park, record.onDriveMissing == .revertSetting, parkFailed.contains(record.id), f.targetApp == .running {
                reason = .appRunning
            }
            healths.append(RelocationHealth(moveID: record.id, health: health(state: state, held: reason, record: record), state: state,
                                            held: reason, removal: f.removal, parkFailed: state == .park && parkFailed.contains(record.id)))
            used.append(record)
        }
        return GuardSnapshot(relocations: healths, banners: BannerText.banners(records: used, health: healths, returns: lastReturn))
    }
}
