import Foundation

/// The twelve states of the guard's reconcile (APP6 §4.5, guard-tech §5.2). `park` and `restore` are decisions as well as
/// states: they name what reconcile finds and what it will do about it.
public enum GuardState: String, Codable, CaseIterable, Sendable {
    /// The link resolves into the recorded volume and the sentinel matches. Nothing to do.
    case healthy
    /// The same volume is mounted at another path than the link's target (a rename or a `... 1` suffix): rebuild the link.
    case retarget
    /// The volume is gone: park (after the debounce).
    case park
    /// `EPERM` / `EACCES` while the volume is mounted: "macOS blocked access to the drive". Never park, never "drive missing".
    case needsPermission
    /// The placeholder is at the path and the drive is back with a matching sentinel: unpark when the preconditions hold.
    case restore
    /// The placeholder is at the path and the drive is away. Idle.
    case parked
    /// A real directory without our marker appeared while the drive was away. Never touched.
    case divergedWhileAbsent
    /// A real directory without our marker, drive present. Never merged.
    case diverged
    /// Nothing at the path: rebuild from the journal if the drive is present, else the placeholder.
    case recreate
    /// A symbolic link we did not write. Stop managing it; say so.
    case foreign
    /// The volume UUID matches but the sentinel is missing or wrong (reformatted or restored clone). Never restore.
    case suspect
    /// The drive is present but read-only or locked: treated as absent for writes, labelled "locked".
    case lockedOrReadOnly
}

public enum SentinelFact: String, Codable, Sendable {
    /// The sentinel exists with our token and this relocation's id.
    case ok
    case missing
    /// Present but the token or the id differs.
    case wrong
    case unreadable
}

public enum DrivePresence: String, Codable, Sendable {
    case absent
    /// Mounted at the path the link's target uses.
    case mountedAtRecordedPath
    /// Mounted with the recorded UUID but at another path.
    case mountedElsewhere
    /// Mounted, but read-only or locked.
    case mountedReadOnlyOrLocked
}

/// How the drive left, as far as the app could tell. `unknown` is treated as unclean (the app can only be sure of an eject it saw).
public enum RemovalKind: String, Codable, Sendable {
    /// `willUnmount` was seen: a Finder eject or a polite unmount.
    case ejected
    /// A pulled cable or a sleep-time disconnect: only `didUnmount`, or nothing until the next volume event.
    case unclean
    case unknown

    public var needsCheckBeforeReconnect: Bool { self != .ejected }

    /// The kind a park line's note names: `park:ejected`, `park:unclean` or `park:unknown` (older lines carry only the word).
    /// A note that names neither is `unknown`, so only an eject Outboard saw is ever called an eject.
    public static func fromParkNote(_ note: String?) -> RemovalKind {
        let text = note ?? ""
        if text.contains("ejected") { return .ejected }
        if text.contains("unclean") { return .unclean }
        return .unknown
    }
}

/// Everything reconcile reads about one relocation's live path and drive. `lstat` and mount facts only; no file contents.
public struct GuardFacts: Codable, Hashable, Sendable {
    public var path: PathKind
    public var drive: DrivePresence
    public var sentinel: SentinelFact
    /// The link's target, resolved now, lies on the recorded volume UUID (the stale `/Volumes/<Name>` case fails this).
    public var targetOnRecordedVolume: Tri
    /// The errno of stat-ing the target while the volume is mounted (`EPERM`, `EACCES`), if any.
    public var targetErrno: Int32?
    /// A real directory at the path carries our marker.
    public var hasOurMarker: Bool
    /// The placeholder file's stamp equals the one recorded when it was created.
    public var placeholderUnchanged: Bool
    /// A symbolic link at the path that the journal does not account for.
    public var linkIsForeign: Bool
    public var removal: RemovalKind?
    public var targetApp: RunState
    /// Another mounted volume with the recorded name but another UUID.
    public var sameNameDifferentDrive: Bool

    public init(path: PathKind, drive: DrivePresence, sentinel: SentinelFact = .ok, targetOnRecordedVolume: Tri = .unknown,
                targetErrno: Int32? = nil, hasOurMarker: Bool = false, placeholderUnchanged: Bool = true, linkIsForeign: Bool = false,
                removal: RemovalKind? = nil, targetApp: RunState = .notRunning, sameNameDifferentDrive: Bool = false) {
        self.path = path
        self.drive = drive
        self.sentinel = sentinel
        self.targetOnRecordedVolume = targetOnRecordedVolume
        self.targetErrno = targetErrno
        self.hasOurMarker = hasOurMarker
        self.placeholderUnchanged = placeholderUnchanged
        self.linkIsForeign = linkIsForeign
        self.removal = removal
        self.targetApp = targetApp
        self.sameNameDifferentDrive = sameNameDifferentDrive
    }
}

/// What a state asks the Mac layer to do. Every case that changes the disk goes through `Renamer`, `Linker`, `Placeholder`
/// or `DefaultsRedirect` and writes its own journal lines.
public enum GuardAction: String, Codable, CaseIterable, Sendable {
    case none
    /// Rebuild the link to the volume's current mount point (park, then unpark to the new place).
    case retarget
    /// Move the link into `Parked/<id>/` and put the note file at the path (or write the prior setting, or only tell).
    case park
    /// Put the link back (or write the setting again).
    case unpark
    /// Rebuild the right object from the journal.
    case recreate
    /// Do nothing; show the banner for the state.
    case reportOnly
}

/// Why an unpark is paused. Shown on the Held pill and in the banner.
public enum HeldReason: String, Codable, CaseIterable, Sendable {
    /// The drive was removed without an eject: the user presses "Check and reconnect".
    case uncleanRemoval
    /// The target app is running; quit it and the guard reconnects.
    case appRunning
    /// The bounded hash sample found a difference.
    case sampleMismatch
    /// A different drive with the same name is connected.
    case wrongDrive
    /// The quick check (listing count and sizes against the manifest) failed.
    case quickCheckFailed
    /// macOS blocked access to the drive.
    case needsPermission
    /// Read-only or locked.
    case readOnlyOrLocked
}

/// Derived, never stored (invariant I10): the one word on the pill. The pill carries the word; colour never carries health alone.
public enum Health: String, Codable, CaseIterable, Sendable {
    case healthy, driveAway, held, conflict, broken

    public var displayName: String {
        switch self {
        case .healthy: return "Healthy"
        case .driveAway: return "Drive away"
        case .held: return "Held"
        case .conflict: return "Conflict"
        case .broken: return "Needs attention"
        }
    }
}

/// The health of one relocation as the UI reads it.
public struct RelocationHealth: Codable, Hashable, Sendable, Identifiable {
    public var moveID: String
    public var health: Health
    public var state: GuardState
    public var held: HeldReason?
    public var removal: RemovalKind?
    /// The guard tried to park this relocation (put the note or the setting back) and could not. Short-lived: it lasts only while the
    /// state is still `park`, so the banner never says a note was put where none stands.
    public var parkFailed: Bool

    public init(moveID: String, health: Health, state: GuardState, held: HeldReason? = nil, removal: RemovalKind? = nil, parkFailed: Bool = false) {
        self.moveID = moveID
        self.health = health
        self.state = state
        self.held = held
        self.removal = removal
        self.parkFailed = parkFailed
    }

    public var id: String { moveID }
}

public enum BannerKind: String, Codable, CaseIterable, Sendable {
    case ejected, removedUnclean, backClean, backChecked, appRunning, sampleMismatch, differentDriveSameName
    case driveRenamed, conflict, needsPermission, revertPending, journalNotWritable, driveChanged, locked, foreignLink, suspect
}

public enum BannerAction: String, Codable, CaseIterable, Sendable {
    case checkAndReconnect, showFiles, reconnectAnyway, leaveDisconnected, showInFinder, setAsideAndReconnect, leaveAsIs
    case openPrivacySettings, forget, dismiss
}

/// One banner at the top of every tab while any relocation is not Healthy. `text` is exact copy from Core `BannerText`.
public struct Banner: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: BannerKind
    public var text: String
    public var actions: [BannerAction]
    public var moveIDs: [String]

    public init(id: String, kind: BannerKind, text: String, actions: [BannerAction] = [], moveIDs: [String] = []) {
        self.id = id
        self.kind = kind
        self.text = text
        self.actions = actions
        self.moveIDs = moveIDs
    }
}

/// The published guard state. `Equatable` and **assigned only when it changed** (the Aftertaste re-render lesson); it carries
/// no timestamps, so a timer tick that finds nothing new produces an equal value. The `MenuBarExtra` reads derived state and
/// never writes back.
public struct GuardSnapshot: Codable, Hashable, Sendable {
    public var relocations: [RelocationHealth]
    public var banners: [Banner]

    public init(relocations: [RelocationHealth] = [], banners: [Banner] = []) {
        self.relocations = relocations
        self.banners = banners
    }

    public static let empty = GuardSnapshot()
    public var isAllHealthy: Bool { relocations.allSatisfy { $0.health == .healthy } }
    /// The menu bar glyph carries a dot while any relocation is DriveAway or Held (no number; an accessibility label says why).
    public var showsAttentionDot: Bool { relocations.contains { $0.health != .healthy } }
}

/// What caused a reconcile. A missed notification costs seconds, not correctness: reconcile is one idempotent function over the
/// recorded volume UUIDs and the `lstat` state of each live path.
public enum ReconcileTrigger: String, Codable, CaseIterable, Sendable {
    case launch, mount, unmount, willUnmount, rename, wake, timer, manual
    /// The user pressed "Check and reconnect": hash every unchanged file before unparking.
    case checkAndReconnect
}

/// The answer of `Held.evaluate`: whether an unpark may go ahead.
public enum HeldDecision: Codable, Hashable, Sendable {
    case clear
    case hold(HeldReason)
}
