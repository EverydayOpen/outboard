import Foundation

/// Every fixed name Outboard puts on disk or says about itself, in one place so Core, Mac and App cannot disagree
/// (BUILD_PLAN §1, §4). Nothing here is read from the system.
public enum Names {
    public static let appName = "Outboard"
    public static let bundleID = "io.github.everydayopen.outboard"
    public static let website = "https://everydayopen.github.io/outboard"
    /// Shown on the Storage Plan card (no scheme, as a person would type it).
    public static let websiteShort = "everydayopen.github.io/outboard"
    public static let repo = "https://github.com/EverydayOpen/outboard"
    /// "Outboard is not affiliated with or endorsed by any app it lists." (README, About, site footer)
    public static let affiliation = "Outboard is not affiliated with or endorsed by any app it lists."   // no-claim-ok: the sentence says we make no such claim
    /// The sentence that stays on the README, the site and in About while any automated recipe is `verifiedOnRealMac: false`.
    public static let notTriedMarker = "Not yet tried on a real Mac."

    // The app's own folder, under `~/Library/Application Support/Outboard/` (never inside iCloud, 0700).
    public static let supportFolder = "Outboard"
    public static let journalPrefix = "journal-"
    public static let journalSuffix = ".jsonl"
    /// `Parked/<moveID>/link` holds the link that was moved out of the way when a drive went missing.
    public static let parkedFolder = "Parked"
    public static let manifestFolder = "Manifests"

    // On the drive: `/Volumes/<name>/Outboard/<recipe-id>/<leaf>`, the marker at `Outboard/.outboard/volume.json`,
    // the sentinel beside (never inside) the data folder at `Outboard/<recipe-id>/.sentinel-<moveID>.json`.
    public static let driveFolder = "Outboard"
    public static let markerFolder = ".outboard"
    public static let markerFile = "volume.json"
    public static let sentinelPrefix = ".sentinel-"
    public static let sentinelSuffix = ".json"
    public static let stagingPrefix = ".staging-"
    public static let manifestFileSuffix = ".manifest.json"

    // Names a move gives to things beside the original (all in the same folder as the original, same volume).
    /// The renamed original, kept until the user confirms: `<name>.before-move`.
    public static let beforeMoveSuffix = ".before-move"
    /// A folder an app created in the gap between the rename and the redirect, set aside, never merged.
    public static let createdWhileMovingSuffix = ".created-while-moving"
    public static let createdWhileRollingBackSuffix = ".created-while-rolling-back"
    /// A copy coming back to the Mac (Return to Mac): `<name>.returning-<moveID>`.
    public static let returningInfix = ".returning-"
    /// The user's "Set it aside and reconnect" for a Conflict: `<name>.while-away-<date>`.
    public static let whileAwayInfix = ".while-away-"
}

/// Numbers the rules and the UI share. Decimal units everywhere (Finder shows 1 GB = 1,000,000,000 bytes).
public enum Limits {
    /// A recipe is offered (and counted in the Storage Plan headline) at 1 GB or more.
    public static let minOfferBytes: UInt64 = 1_000_000_000
    /// E12: free space on the drive must be at least `freeSpaceNumerator / freeSpaceDenominator` times the source's logical bytes ...
    public static let freeSpaceNumerator: UInt64 = 11
    public static let freeSpaceDenominator: UInt64 = 10
    /// ... and at least `max(minFreeAfterBytes, capacity * minFreeAfterPercent / 100)` must remain free afterwards.
    public static let minFreeAfterBytes: UInt64 = 10_000_000_000
    public static let minFreeAfterPercent: UInt64 = 5
    /// The Storage Plan card says "Nothing big to move" below this total (APP6 §3.3 "Small").
    public static let smallPlanBytes: UInt64 = 5_000_000_000
    /// "Check and reconnect" on a clean return samples this many unchanged files; an unclean return hashes every unchanged file.
    public static let returnSampleFiles = 200
    /// The first differences listed when a verification fails.
    public static let firstDifferencesListed = 20
    /// The in-app (never a notification) reminder that a safety copy is still on the Mac.
    public static let safetyCopyReminderDays = 14
    /// Guard timings. A missed notification costs seconds, not correctness (reconcile is idempotent).
    public static let parkDebounceSeconds = 5.0
    public static let wakeGraceSeconds = 15.0
    public static let launchGraceSeconds = 20.0
    public static let reconcileIntervalSeconds = 10.0
    /// Copy progress is polled this often (bytes done), not estimated.
    public static let progressPollMilliseconds = 500
    /// Hash chunk size for the verifier (Whydunit's `fileSHA256` uses 1 MB).
    public static let hashChunkBytes = 1 << 20
    /// The sentinel and marker JSON schema version, and the journal schema version.
    public static let journalSchema = 1
    public static let markerSchema = 1
    public static let manifestSchema = 1
    /// The one limit for a manifest file: `ManifestStore` writes up to this many bytes and `Parsers.manifest` reads up to the same number, so
    /// a manifest that was written can always be read back.
    public static let maxManifestBytes = 256 * 1_048_576
    /// A deliberately high guess at the bytes one manifest entry takes (a sorted-key JSON object with its 64-character SHA-256 and a long
    /// path). Preflight refuses a folder whose entries times this would not fit under `maxManifestBytes`, before any byte is copied.
    public static let manifestBytesPerEntryEstimate = 512
    /// True when a folder with this many entries (files, folders and links) is expected to fit in one manifest.
    public static func manifestFits(entryCount: Int) -> Bool {
        entryCount >= 0 && entryCount <= maxManifestBytes / manifestBytesPerEntryEstimate
    }
    /// Size of a placeholder file's text is small; the Mac layer refuses to treat a "placeholder" bigger than this as ours.
    public static let placeholderMaxBytes = 4096
}

/// A fact that may be unknown. Tri-state on purpose: **a missing signal never becomes "yes"** (BUILD_PLAN §3 rule 4, APP6 §4.3).
public enum Tri: String, Codable, CaseIterable, Sendable {
    case yes, no, unknown

    public init(_ value: Bool?) {
        switch value {
        case .some(true): self = .yes
        case .some(false): self = .no
        case .none: self = .unknown
        }
    }

    public var isYes: Bool { self == .yes }
    public var isNo: Bool { self == .no }
    public var isUnknown: Bool { self == .unknown }
}
