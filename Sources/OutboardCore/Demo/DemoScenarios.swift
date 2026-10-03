import Foundation

/// Synthetic worlds for demo mode (BUILD_PLAN §4.6, §9). Pure and deterministic: one scenario and one `now` always give the same
/// Mac, the same drives and the same journal, so screenshots do not drift. Home is the example user jane; the apps are the real
/// catalogue apps (the recipes are the product) with fictional sizes. This file only describes a Mac as plain data. It never
/// decides anything: `DemoBackend` feeds the data to the real Core (`Eligibility`, `MovePlanner`, `MoveMachine`, `RelocationFold`,
/// `Recovery`, `GuardPolicy`, `TreeCompare`), so the demo exercises the real rules. No clock is read anywhere in `Demo/`.
public enum DemoScenarios {
    public static let home = "/Users/jane"
    public static let osVersion = "26.1"
    public static let macOS = MinOS(26, 1)
    public static let appVersion = "demo"
    /// 2026-10-03 10:00 UTC. The default `now` of every demo entry point.
    public static let referenceNow = Date(timeIntervalSince1970: 1_791_021_600)
    /// What the journal-blocked scenario says (BUILD_PLAN §8.1 banner table, same words as the outcome).
    public static let journalBlockedMessage = BannerText.journalNotWritable.text

    // MARK: Drives

    public static let outboardVolumeID = "3E1C0B7A-0000-4000-8000-000000000001"
    public static let travelVolumeID = "3E1C0B7A-0000-4000-8000-000000000002"
    public static let archiveVolumeID = "3E1C0B7A-0000-4000-8000-000000000003"
    public static let timeMachineVolumeID = "3E1C0B7A-0000-4000-8000-000000000004"
    public static let backupAVolumeID = "3E1C0B7A-0000-4000-8000-000000000005"
    public static let backupBVolumeID = "3E1C0B7A-0000-4000-8000-000000000006"
    public static let cardVolumeID = "3E1C0B7A-0000-4000-8000-000000000007"
    public static let installerVolumeID = "3E1C0B7A-0000-4000-8000-000000000008"
    public static let internalVolumeID = "3E1C0B7A-0000-4000-8000-000000000009"
    public static let nasVolumeID = "mount:/Volumes/Media Share"

    /// The Mac's own disk. Every scenario lists it (the live `volumes()` does too); eligibility refuses it with E3.
    static let internalDisk = DriveFacts(uuid: internalVolumeID, name: "Macintosh HD", mountPoint: "/", fileSystem: .apfs,
                                         fileSystemRaw: "apfs", bus: .internalBus, busRaw: "Apple Fabric", isInternal: .yes,
                                         isEncrypted: .yes, capacityBytes: 500_000_000_000, availableBytes: 140_000_000_000,
                                         isStandardMount: false)

    /// The one eligible drive: APFS, solid state, encrypted, carries the marker.
    static func outboardDrive(encrypted: Tri = .yes) -> DriveFacts {
        DriveFacts(uuid: outboardVolumeID, name: "Outboard", mountPoint: "/Volumes/Outboard", fileSystem: .apfs, fileSystemRaw: "apfs",
                   bus: .usb, busRaw: "USB", isEncrypted: encrypted, capacityBytes: 1_000_000_000_000, availableBytes: 480_000_000_000,
                   hasOutboardMarker: true, markerToken: "demo-marker-outboard")
    }

    /// The refusals table (safety-ux §3.1): exFAT SSD, USB hard disk, the Time Machine disk, two drives named Backup, a NAS,
    /// an SD card and a disk image. Each is refused by the real `Eligibility.evaluate`, first by the rule named here.
    static let refusedDrives: [(drive: DriveFacts, firstRefusal: EligibilityRule)] = [
        (DriveFacts(uuid: travelVolumeID, name: "Travel SSD", mountPoint: "/Volumes/Travel SSD", fileSystem: .exfat, fileSystemRaw: "exfat",
                    isEncrypted: .no, capacityBytes: 500_000_000_000, availableBytes: 310_000_000_000), .e4),
        (DriveFacts(uuid: archiveVolumeID, name: "Archive HDD", mountPoint: "/Volumes/Archive HDD", isSolidState: .no, isEncrypted: .no,
                    capacityBytes: 2_000_000_000_000, availableBytes: 1_400_000_000_000), .e5),
        (DriveFacts(uuid: timeMachineVolumeID, name: "Time Machine", mountPoint: "/Volumes/Time Machine",
                    timeMachine: TimeMachineSignals(apfsBackupRole: .yes, listedByTmutil: .yes, backupFolderAtRoot: .yes),
                    capacityBytes: 4_000_000_000_000, availableBytes: 900_000_000_000), .e7),
        (DriveFacts(uuid: backupAVolumeID, name: "Backup", mountPoint: "/Volumes/Backup", capacityBytes: 250_000_000_000,
                    availableBytes: 120_000_000_000, sameNameCount: 2), .e8),
        (DriveFacts(uuid: backupBVolumeID, name: "Backup", mountPoint: "/Volumes/Backup 1", capacityBytes: 1_000_000_000_000,
                    availableBytes: 700_000_000_000, isStandardMount: false, sameNameCount: 2), .e8),
        (DriveFacts(uuid: nil, name: "Media Share", mountPoint: "/Volumes/Media Share", fileSystem: .network, fileSystemRaw: "smbfs",
                    bus: .network, busRaw: "Network", isLocal: false, capacityBytes: 8_000_000_000_000, availableBytes: 3_100_000_000_000), .e1),
        (DriveFacts(uuid: cardVolumeID, name: "CARD", mountPoint: "/Volumes/CARD", fileSystem: .exfat, fileSystemRaw: "exfat", bus: .sdCard,
                    busRaw: "SD Card", capacityBytes: 128_000_000_000, availableBytes: 90_000_000_000), .e4),
        (DriveFacts(uuid: installerVolumeID, name: "Installer", mountPoint: "/Volumes/Installer", bus: .diskImage, busRaw: "Disk Image",
                    capacityBytes: 5_000_000_000, availableBytes: 200_000_000), .e2),
    ]

    // MARK: What a scenario hands the app

    /// Every volume the scenario can mount (the ones attached at launch and the ones that come back). The backend's `volumes()`
    /// returns the attached ones.
    public static func volumes(for scenario: DemoScenario) -> [DriveFacts] { world(scenario).volumes }

    /// The preferences the demo app should start with: the moves are not yet tried on a real Mac, so the demo shows them with the
    /// "Show moves not yet tried on a real Mac" preference on (the consent sheets then carry the note, as they should).
    public static func preferences(for scenario: DemoScenario) -> Preferences {
        let attached = world(scenario).volumes.contains { $0.id == outboardVolumeID }
        return Preferences(showUnverifiedMoves: true, hasSeenFirstRun: scenario != .firstRun, preferredVolumeUUID: attached ? outboardVolumeID : nil)
    }

    /// What the scenario is about, so a screen can open on it: the recipe, the drive and the move.
    public static func focus(for scenario: DemoScenario, now: Date = referenceNow) -> DemoFocus {
        let w = world(scenario)
        func history(_ recipeID: RecipeID) -> String? {
            guard let spec = w.history.first(where: { $0.recipeID == recipeID }) else { return nil }
            return spec.moveID(now: now)
        }
        switch scenario {
        case .consentXcodeDerivedData, .consentXcodeArchives, .consentHuggingFace, .consentOllama, .consentLlamaCpp, .consentNpm, .consentIOSBackups:
            return DemoFocus(recipeID: scenario.consentRecipeID, volumeID: outboardVolumeID)
        case .guided:
            return DemoFocus(recipeID: "photos-library", volumeID: outboardVolumeID)
        case .copying, .verifying:
            return DemoFocus(recipeID: "xcode-deriveddata", volumeID: outboardVolumeID, moveID: userMoveID(now: now, index: 0))
        case .swapped, .confirmed, .rolledBack:
            return DemoFocus(recipeID: "xcode-deriveddata", volumeID: outboardVolumeID, moveID: history("xcode-deriveddata"))
        case .recovered:
            return DemoFocus(recipeID: "xcode-deriveddata", volumeID: outboardVolumeID, moveID: history("xcode-deriveddata"))
        case .needsAttention:
            return DemoFocus(recipeID: "ollama-models", volumeID: outboardVolumeID, moveID: history("ollama-models"))
        case .afterMoves:
            return DemoFocus(recipeID: "ios-device-backups", volumeID: outboardVolumeID, moveID: history("ios-device-backups"))
        case .driveAway, .driveBack, .held, .conflict, .forget:
            return DemoFocus(recipeID: "ios-device-backups", volumeID: outboardVolumeID, moveID: history("ios-device-backups"))
        case .drives:
            return DemoFocus(volumeID: outboardVolumeID)
        case .plan, .planGuided, .partlyMeasured, .journalBlocked:
            return DemoFocus(recipeID: "xcode-deriveddata", volumeID: outboardVolumeID)
        case .fresh, .small, .nothingFound, .report, .firstRun:
            return DemoFocus()
        }
    }

    /// The progress a frozen scenario stops at (`copying` at 41%, `verifying` at 62%); nil for the others. The numbers are those of
    /// the Xcode build data move: 41.23 GB, 48,211 files.
    public static func frozenProgress(for scenario: DemoScenario, now: Date = referenceNow) -> MoveProgress? {
        guard let freeze = world(scenario).frozen, let seed = DemoSeed.base["xcode-deriveddata"] else { return nil }
        let id = userMoveID(now: now, index: 0)
        switch freeze.phase {
        case .copying:
            return MoveProgress(moveID: id, phase: .copying, bytesDone: UInt64(Double(seed.bytes) * freeze.fraction), bytesTotal: seed.bytes,
                                filesDone: Int(Double(seed.files) * freeze.fraction), filesTotal: seed.files,
                                elapsedSeconds: (Double(seed.copySeconds) * freeze.fraction).rounded())
        default:
            return MoveProgress(moveID: id, phase: .verifying, bytesDone: seed.bytes, bytesTotal: seed.bytes,
                                filesDone: Int(Double(seed.files) * freeze.fraction), filesTotal: seed.files,
                                elapsedSeconds: (Double(seed.verifySeconds) * freeze.fraction).rounded())
        }
    }

    /// The consent a person gives by ticking every box the sheet asks for (the recipe's boxes and the drive's acknowledgements).
    public static func tickedConsent(recipe: Recipe, report: EligibilityReport, sawUnverifiedNote: Bool = true) -> ConsentRecord {
        let ids = MovePlanner.requiredCheckboxIDs(recipe: recipe, report: report)
        return ConsentRecord(recipeVersion: recipe.version, tickedIDs: ids.filter { !$0.hasPrefix("ack-") },
                             ackIDs: ids.filter { $0.hasPrefix("ack-") }, sawUnverifiedNote: sawUnverifiedNote && !recipe.verifiedOnRealMac)
    }

    /// The id of the n-th move started in a demo backend (`plan` hands them out in order).
    static func userMoveID(now: Date, index: Int) -> String {
        MovePlanner.newMoveID(now: now, random: 0x0d3c10 + UInt32(index))
    }
}

/// What a scenario is about (see `DemoScenarios.focus`).
public struct DemoFocus: Hashable, Sendable {
    public var recipeID: RecipeID?
    public var volumeID: String?
    public var moveID: String?

    public init(recipeID: RecipeID? = nil, volumeID: String? = nil, moveID: String? = nil) {
        self.recipeID = recipeID
        self.volumeID = volumeID
        self.moveID = moveID
    }
}

// MARK: - Worlds (plain data)

/// A folder on the Mac and what the size scan finds in it. Sizes are fictional; allocated equals logical.
struct DemoSeed: Hashable {
    var recipeID: RecipeID
    var bytes: UInt64
    var files: Int
    var directories: Int
    var symlinks: Int

    /// Seconds the copy took, for the journal's timestamps and the progress's elapsed time (no clock: derived from the size).
    var copySeconds: Int64 { DemoTiming.copySeconds(bytes) }
    var verifySeconds: Int64 { DemoTiming.verifySeconds(bytes) }

    func sized(_ bytes: UInt64) -> DemoSeed {
        var s = self
        s.bytes = bytes
        return s
    }

    /// The canonical sizes. The `plan` scenario's three rows are 41.23, 30.11 and 15.64 GB: 86.98 GB, "up to 87 GB".
    static let base: [RecipeID: DemoSeed] = {
        let all = [
            DemoSeed(recipeID: "xcode-deriveddata", bytes: 41_230_000_000, files: 48_211, directories: 6_102, symlinks: 12),
            DemoSeed(recipeID: "ollama-models", bytes: 30_110_000_000, files: 23, directories: 9, symlinks: 0),
            DemoSeed(recipeID: "ios-device-backups", bytes: 15_640_000_000, files: 41_203, directories: 262, symlinks: 0),
            DemoSeed(recipeID: "huggingface-hub-cache", bytes: 22_840_000_000, files: 168, directories: 41, symlinks: 84),
            DemoSeed(recipeID: "llamacpp-cache", bytes: 9_600_000_000, files: 6, directories: 1, symlinks: 0),
            DemoSeed(recipeID: "npm-cache", bytes: 3_400_000_000, files: 128_906, directories: 24_117, symlinks: 0),
            DemoSeed(recipeID: "xcode-archives", bytes: 8_200_000_000, files: 3_460, directories: 44, symlinks: 0),
            DemoSeed(recipeID: "photos-library", bytes: 212_000_000_000, files: 318_422, directories: 9_877, symlinks: 0),
        ]
        return Dictionary(uniqueKeysWithValues: all.map { ($0.recipeID, $0) })
    }()
}

/// How a seeded move ends. `crash` stops after the original was set aside and before the result was written (the recovery table's
/// `setAside.i without .r` row); `bothOriginals` also leaves a second original at the path, which recovery must not touch.
enum DemoEnd: Hashable {
    case swapped, trashed, rolledBack, mismatch
    case crash(bothOriginals: Bool)
}

struct DemoSpec: Hashable {
    var recipeID: RecipeID
    /// When the move began, in seconds before `now`.
    var secondsAgo: Int64
    var random: UInt32
    var end: DemoEnd

    func moveID(now: Date) -> String {
        MovePlanner.newMoveID(now: now.addingTimeInterval(-Double(secondsAgo)), random: random)
    }
}

/// Things that happen to the drive after the history, in order. Each is followed by one guard pass.
struct DemoEvent: Hashable {
    enum Action: Hashable {
        case eject(RemovalKind)
        case mount
        /// An app writes a new folder where the note was (bytes of it).
        case foreignFolder(RecipeID, UInt64)
    }

    var secondsAgo: Int64
    var action: Action
}

struct DemoFreeze: Hashable {
    var phase: ProgressPhase
    var fraction: Double
}

struct DemoWorld {
    var seeds: [DemoSeed] = []
    var unmeasured: [RecipeID: NotMeasuredReason] = [:]
    /// Every volume the scenario can mount, the internal disk first.
    var volumes: [DriveFacts] = [DemoScenarios.internalDisk]
    /// The ids attached at launch (before the history and the events).
    var attached: [String] = [DemoScenarios.internalVolumeID]
    var history: [DemoSpec] = []
    var events: [DemoEvent] = []
    /// Recipes whose app is running (the consent sheet's blocker rows).
    var running: Set<RecipeID> = []
    var fullDiskAccess: Tri = .yes
    var journalBlocked = false
    var frozen: DemoFreeze?
    /// Nothing is measured at all (the first-run scenario shows the education cards over an empty plan).
    var measuresNothing = false
}

extension DemoScenarios {
    static func seed(_ id: RecipeID, bytes: UInt64? = nil) -> DemoSeed {
        let s = DemoSeed.base[id] ?? DemoSeed(recipeID: id, bytes: bytes ?? 0, files: 1, directories: 1, symlinks: 0)
        return bytes.map { s.sized($0) } ?? s
    }

    /// The three rows of the 87 GB plan, plus a small npm cache that stays under the 1 GB threshold.
    static var planSeeds: [DemoSeed] {
        [seed("xcode-deriveddata"), seed("ollama-models"), seed("ios-device-backups"), seed("npm-cache", bytes: 820_000_000)]
    }

    static func attachedWorld(_ seeds: [DemoSeed], encrypted: Tri = .yes) -> DemoWorld {
        var w = DemoWorld()
        w.seeds = seeds
        w.volumes = [internalDisk, outboardDrive(encrypted: encrypted)]
        w.attached = [internalVolumeID, outboardVolumeID]
        return w
    }

    /// A seeded move that began `hours` before now and ended the way `end` says.
    static func spec(_ id: RecipeID, hours: Double, random: UInt32, _ end: DemoEnd) -> DemoSpec {
        DemoSpec(recipeID: id, secondsAgo: Int64(hours * 3_600), random: random, end: end)
    }

    static func world(_ s: DemoScenario) -> DemoWorld {
        let day = 24.0
        switch s {
        case .fresh:
            var w = DemoWorld()
            w.seeds = planSeeds
            return w
        case .plan:
            return attachedWorld(planSeeds)
        case .planGuided:
            return attachedWorld(planSeeds + [seed("photos-library")])
        case .partlyMeasured:
            var w = attachedWorld([seed("xcode-deriveddata"), seed("ollama-models")])
            w.unmeasured["ios-device-backups"] = .needsFullDiskAccess
            w.fullDiskAccess = .no
            return w
        case .small:
            return attachedWorld([seed("xcode-deriveddata", bytes: 3_100_000_000), seed("npm-cache", bytes: 1_400_000_000)])
        case .nothingFound:
            return attachedWorld([seed("xcode-deriveddata", bytes: 400_000_000), seed("npm-cache", bytes: 210_000_000)])
        case .drives:
            var w = attachedWorld(planSeeds)
            w.volumes += refusedDrives.map { $0.drive }
            w.attached += refusedDrives.map { $0.drive.id }
            return w
        case .consentXcodeDerivedData:
            var w = attachedWorld(planSeeds + [seed("xcode-archives")])
            w.running = ["xcode-deriveddata"]
            return w
        case .consentXcodeArchives:
            return attachedWorld(planSeeds + [seed("xcode-archives")])
        case .consentHuggingFace:
            return attachedWorld(planSeeds + [seed("huggingface-hub-cache")])
        case .consentOllama:
            return attachedWorld(planSeeds)
        case .consentLlamaCpp:
            return attachedWorld(planSeeds + [seed("llamacpp-cache")])
        case .consentNpm:
            return attachedWorld(Array(planSeeds.dropLast()) + [seed("npm-cache")])
        case .consentIOSBackups:
            // An unencrypted drive, so the sheet shows the encryption acknowledgement (E16).
            return attachedWorld(planSeeds, encrypted: .no)
        case .guided:
            return attachedWorld(planSeeds + [seed("photos-library")])
        case .copying:
            var w = attachedWorld(planSeeds)
            w.frozen = DemoFreeze(phase: .copying, fraction: 0.41)
            return w
        case .verifying:
            var w = attachedWorld(planSeeds)
            w.frozen = DemoFreeze(phase: .verifying, fraction: 0.62)
            return w
        case .swapped:
            var w = attachedWorld(planSeeds)
            w.history = [spec("xcode-deriveddata", hours: 2, random: 0x3fa9c1, .swapped)]
            return w
        case .confirmed:
            var w = attachedWorld(planSeeds)
            w.history = [spec("xcode-deriveddata", hours: day, random: 0x3fa9c1, .trashed)]
            return w
        case .afterMoves:
            var w = attachedWorld(planSeeds)
            w.history = [spec("xcode-deriveddata", hours: 3 * day, random: 0x3fa9c1, .trashed),
                         spec("ollama-models", hours: 2 * day, random: 0x71be02, .trashed),
                         spec("ios-device-backups", hours: 1, random: 0xa04d57, .swapped)]
            return w
        case .driveAway:
            var w = attachedWorld(planSeeds)
            w.history = [spec("ollama-models", hours: 6 * day, random: 0x71be02, .trashed),
                         spec("ios-device-backups", hours: 4 * day, random: 0xa04d57, .trashed)]
            w.events = [DemoEvent(secondsAgo: 1_800, action: .eject(.ejected))]
            return w
        case .driveBack:
            var w = attachedWorld(planSeeds)
            w.history = [spec("ollama-models", hours: 6 * day, random: 0x71be02, .trashed),
                         spec("ios-device-backups", hours: 4 * day, random: 0xa04d57, .trashed)]
            w.events = [DemoEvent(secondsAgo: 5_400, action: .eject(.ejected)), DemoEvent(secondsAgo: 600, action: .mount)]
            return w
        case .held:
            var w = attachedWorld(planSeeds)
            w.history = [spec("ollama-models", hours: 6 * day, random: 0x71be02, .trashed),
                         spec("ios-device-backups", hours: 4 * day, random: 0xa04d57, .trashed)]
            w.events = [DemoEvent(secondsAgo: 5_400, action: .eject(.unclean)), DemoEvent(secondsAgo: 600, action: .mount)]
            return w
        case .conflict:
            var w = attachedWorld(planSeeds)
            w.history = [spec("ios-device-backups", hours: 4 * day, random: 0xa04d57, .trashed)]
            w.events = [DemoEvent(secondsAgo: 5_400, action: .eject(.ejected)),
                        DemoEvent(secondsAgo: 3_000, action: .foreignFolder("ios-device-backups", 1_200_000_000)),
                        DemoEvent(secondsAgo: 600, action: .mount)]
            return w
        case .rolledBack:
            var w = attachedWorld(planSeeds)
            w.history = [spec("xcode-deriveddata", hours: 3, random: 0x3fa9c1, .rolledBack)]
            return w
        case .recovered:
            var w = attachedWorld(planSeeds)
            w.history = [spec("xcode-deriveddata", hours: 1, random: 0x3fa9c1, .crash(bothOriginals: false))]
            return w
        case .needsAttention:
            var w = attachedWorld(planSeeds)
            w.history = [spec("ollama-models", hours: 1, random: 0x71be02, .crash(bothOriginals: true))]
            return w
        case .journalBlocked:
            var w = attachedWorld(planSeeds)
            w.journalBlocked = true
            return w
        case .forget:
            var w = attachedWorld(planSeeds)
            w.history = [spec("ios-device-backups", hours: 20 * day, random: 0xa04d57, .trashed)]
            w.events = [DemoEvent(secondsAgo: 2 * 86_400, action: .eject(.unclean))]
            return w
        case .report:
            var w = attachedWorld(Array(planSeeds.dropLast()) + [seed("npm-cache")])
            w.history = [spec("xcode-deriveddata", hours: 9 * day, random: 0x3fa9c1, .trashed),
                         spec("npm-cache", hours: 5 * day, random: 0x5b21e8, .rolledBack),
                         spec("ollama-models", hours: 3 * day, random: 0x71be02, .swapped),
                         spec("ios-device-backups", hours: 2 * day, random: 0xa04d57, .mismatch)]
            return w
        case .firstRun:
            var w = DemoWorld()
            w.measuresNothing = true
            return w
        }
    }
}

/// How long a copy and a compare "took" in the sample data: a fixed rate, so the journal and the progress agree without a clock.
enum DemoTiming {
    static func copySeconds(_ bytes: UInt64) -> Int64 { max(8, Int64(bytes / 150_000_000)) }
    static func verifySeconds(_ bytes: UInt64) -> Int64 { copySeconds(bytes) * 6 / 5 }
}
