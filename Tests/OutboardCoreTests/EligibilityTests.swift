import Foundation
import XCTest
@testable import OutboardCore

final class EligibilityTests: XCTestCase {
    private let ollama = T.recipe("ollama-models")           // expensive, symlink
    private let derived = T.recipe("xcode-deriveddata")      // regenerable, defaults
    private let backups = T.recipe("ios-device-backups")     // irreplaceable, sensitive, symlink
    private let photos = T.recipe("photos-library")          // guided media
    private let needs = SourceNeeds(logicalBytes: 30_000_000_000, isCaseSensitive: .no, hasHardLinks: false, hasSymlinks: true)

    private func report(_ d: DriveFacts, _ r: Recipe? = nil, source: SourceNeeds? = nil) -> EligibilityReport {
        Eligibility.evaluate(volume: d, recipe: r, source: source ?? (r == nil ? nil : needs), policy: .release)
    }

    private func rules(_ report: EligibilityReport, _ outcome: EligibilityOutcome) -> [EligibilityRule] {
        report.verdicts.filter { $0.outcome == outcome }.map(\.rule)
    }

    // MARK: the examples of the spec

    func testAGoodDriveIsAllowedForEveryAutomatedRecipe() {
        for r in Catalogue.automated {
            let rep = report(T.drive(), r)
            XCTAssertTrue(rep.isAllowed, "\(r.id): \(rep.verdicts)")
            XCTAssertTrue(rep.acks.isEmpty, r.id)
            XCTAssertEqual(rep.verdicts.map(\.rule), [.e15, .e17], "\(r.id): info only")
        }
    }

    func testTheSpecExamples() {
        let ssd = report(T.drive(), derived)
        XCTAssertEqual(ssd.infos.map(\.message), ["macOS doesn't report this drive's health over this connection.", "Your Outboard drive."])
        // unencrypted: Ack E16 for iOS backups only
        let plain = T.drive { $0.isEncrypted = .no }
        XCTAssertEqual(rules(report(plain, backups), .ack), [.e16])
        XCTAssertTrue(report(plain, derived).acks.isEmpty)
        // exFAT SSD -> E4
        XCTAssertEqual(rules(report(T.drive { $0.fileSystem = .exfat; $0.fileSystemRaw = "exfat" }, derived), .refuse), [.e4])
        // USB hard disk -> E5
        XCTAssertEqual(rules(report(T.drive { $0.isSolidState = .no }, derived), .refuse), [.e5])
        // the Time Machine disk -> E7
        let tm = T.drive { $0.timeMachine = TimeMachineSignals(apfsBackupRole: .yes, listedByTmutil: .no, backupFolderAtRoot: .no) }
        XCTAssertEqual(rules(report(tm, derived), .refuse), [.e7])
        // two drives named Backup -> E8
        XCTAssertEqual(rules(report(T.drive(name: "Backup") { $0.sameNameCount = 2 }, derived), .refuse), [.e8])
        // NAS -> E1
        let nas = T.drive { $0.isLocal = false; $0.fileSystem = .network; $0.bus = .network; $0.isInternal = .no }
        XCTAssertEqual(rules(report(nas, derived), .refuse), [.e1])
        // SD card, exFAT -> E4
        XCTAssertEqual(rules(report(T.drive { $0.bus = .sdCard; $0.fileSystem = .exfat }, derived), .refuse), [.e4])
        // .dmg -> E2
        XCTAssertEqual(rules(report(T.drive { $0.bus = .diskImage }, derived), .refuse), [.e2])
        #if DEBUG
        XCTAssertTrue(Eligibility.evaluate(volume: T.drive { $0.bus = .diskImage }, recipe: derived, source: needs, policy: .testing).isAllowed, "the test policy mounts disk images")
        #endif
    }

    // MARK: one test per rule

    func testE1NetworkLocation() {
        let d = T.drive { $0.isLocal = false }
        XCTAssertEqual(report(d).firstRefusal?.rule, .e1)
        XCTAssertEqual(report(d).firstRefusal?.message, "This is a network location. Outboard only uses drives plugged into this Mac.")
        XCTAssertEqual(rules(report(T.drive { $0.fileSystem = .network }), .refuse), [.e1])
    }

    func testE2DiskImage() {
        XCTAssertEqual(report(T.drive { $0.bus = .diskImage }).firstRefusal?.message, "This is a disk image, not a drive.")
    }

    func testE3ExternalOnly_internalAndUnknownBothRefuse() {
        XCTAssertEqual(report(T.drive { $0.isInternal = .yes }, ollama).firstRefusal?.message, "This volume is part of your Mac's own storage.")
        let unknown = report(T.drive { $0.isInternal = .unknown }, ollama)
        XCTAssertEqual(unknown.firstRefusal?.rule, .e3)
        XCTAssertEqual(unknown.firstRefusal?.unknownSignal, "internal or external")
        XCTAssertEqual(report(T.drive { $0.isInternal = .unknown }, backups).firstRefusal?.rule, .e3)
    }

    func testE4Format() {
        let hfs = T.drive { $0.fileSystem = .hfsPlus }
        XCTAssertEqual(rules(report(hfs), .warn), [.e4], "the general verdict warns")
        XCTAssertEqual(rules(report(hfs, photos, source: needs), .warn), [.e4], "a media card allows Mac OS Extended")
        XCTAssertEqual(rules(report(hfs, ollama), .refuse), [.e4], "an automated recipe needs APFS")
        XCTAssertEqual(rules(report(hfs, T.recipe("steam-library"), source: needs), .refuse), [.e4], "APFS only for Steam")
        for fs in [FileSystemKind.exfat, .fat, .ntfs] {
            let rep = report(T.drive { $0.fileSystem = fs })
            XCTAssertEqual(rep.firstRefusal?.message, "This drive is formatted as \(fs.displayName). Apps need APFS or Mac OS Extended. Outboard can't change a drive's format.")
        }
        XCTAssertEqual(rules(report(T.drive { $0.fileSystem = .other; $0.fileSystemRaw = "ext4" }), .refuse), [.e4])
    }

    func testE5SolidStateAndSlowLinks() {
        XCTAssertEqual(report(T.drive { $0.isSolidState = .no }, ollama).firstRefusal?.message, "This looks like a spinning hard disk. It's too slow for app data. Outboard will only use SSDs.")
        XCTAssertEqual(rules(report(T.drive { $0.isSolidState = .no }, photos, source: needs), .warn), [.e5], "a media card only warns")
        XCTAssertEqual(report(T.drive { $0.linkMegabitsPerSecond = 480 }, ollama).firstRefusal?.message, "This drive is connected at USB 2 speed. Outboard needs a newer connection (USB 3 or Thunderbolt).")
        XCTAssertTrue(report(T.drive { $0.linkMegabitsPerSecond = 5000 }, ollama).isAllowed)
        XCTAssertTrue(report(T.drive { $0.linkMegabitsPerSecond = nil }, ollama).isAllowed, "an unknown speed claims nothing")
        XCTAssertEqual(rules(report(T.drive { $0.linkMegabitsPerSecond = 480 }, photos, source: needs), .warn), [.e5])
    }

    func testE6Writable() {
        XCTAssertEqual(report(T.drive { $0.isWritable = .no }).firstRefusal?.message, "This drive is read-only.")
        XCTAssertEqual(report(T.drive { $0.isWritable = .unknown }, derived).firstRefusal?.unknownSignal, "writable")
        XCTAssertEqual(report(T.drive { $0.isLocked = true }).firstRefusal?.rule, .e6)
    }

    func testE7TimeMachineAnySignalRefuses() {
        for signals in [TimeMachineSignals(apfsBackupRole: .yes, listedByTmutil: .no, backupFolderAtRoot: .no),
                        TimeMachineSignals(apfsBackupRole: .no, listedByTmutil: .yes, backupFolderAtRoot: .no),
                        TimeMachineSignals(apfsBackupRole: .no, listedByTmutil: .no, backupFolderAtRoot: .yes),
                        TimeMachineSignals(apfsBackupRole: .unknown, listedByTmutil: .unknown, backupFolderAtRoot: .yes)] {
            let rep = report(T.drive { $0.timeMachine = signals }, ollama)
            XCTAssertEqual(rep.firstRefusal?.message, "This is a Time Machine disk. Use a different drive.")
        }
        let sibling = report(T.drive { $0.timeMachineSiblingInContainer = true }, ollama)
        XCTAssertTrue(sibling.isAllowed)
        XCTAssertEqual(sibling.infos.first { $0.rule == .e7 }?.message, "A volume on this drive's container is used by Time Machine.")
    }

    func testE8Identity() {
        XCTAssertEqual(report(T.drive(uuid: nil), ollama).firstRefusal?.rule, .e8)
        XCTAssertEqual(report(T.drive { $0.sameNameCount = 2 }).firstRefusal?.message, "Two drives have the same name. Rename one in Finder, then try again.")
        XCTAssertEqual(report(T.drive { $0.isStandardMount = false }).firstRefusal?.rule, .e8)
    }

    func testE9Ownership() {
        XCTAssertEqual(report(T.drive { $0.ownershipHonoured = .no }, ollama).firstRefusal?.rule, .e9)
        XCTAssertTrue((report(T.drive { $0.ownershipHonoured = .no }).firstRefusal?.message ?? "").hasPrefix("This drive is set to ignore ownership"))
    }

    func testE10CaseSensitivity() {
        let sensitiveSource = SourceNeeds(logicalBytes: 1_000, isCaseSensitive: .yes)
        XCTAssertEqual(report(T.drive { $0.isCaseSensitive = .no }, ollama, source: sensitiveSource).firstRefusal?.message, "This drive isn't case-sensitive but the data is. Two files could collide.")
        XCTAssertTrue(report(T.drive { $0.isCaseSensitive = .yes }, ollama, source: sensitiveSource).isAllowed)
        XCTAssertTrue(report(T.drive { $0.isCaseSensitive = .no }, ollama, source: needs).isAllowed)
        // unknown on either side
        XCTAssertEqual(rules(report(T.drive { $0.isCaseSensitive = .unknown }, ollama, source: sensitiveSource), .ack), [.e10])
        XCTAssertEqual(rules(report(T.drive { $0.isCaseSensitive = .unknown }, backups, source: sensitiveSource), .refuse), [.e10])
        let unknownSource = SourceNeeds(logicalBytes: 1_000, isCaseSensitive: .unknown)
        XCTAssertEqual(rules(report(T.drive { $0.isCaseSensitive = .no }, ollama, source: unknownSource), .ack), [.e10])
        XCTAssertTrue(report(T.drive { $0.isCaseSensitive = .yes }, ollama, source: unknownSource).isAllowed, "a case-sensitive drive can hold anything")
    }

    func testE11Links() {
        XCTAssertEqual(report(T.drive { $0.supportsSymlinks = .no }, ollama).firstRefusal?.message, "This drive can't hold the links this data needs.")
        XCTAssertEqual(rules(report(T.drive { $0.supportsSymlinks = .unknown }, ollama), .ack), [.e11])
        let hard = SourceNeeds(logicalBytes: 1_000, isCaseSensitive: .no, hasHardLinks: true, hasSymlinks: false)
        XCTAssertEqual(report(T.drive { $0.supportsHardLinks = .no }, ollama, source: hard).firstRefusal?.rule, .e11)
        XCTAssertTrue(report(T.drive { $0.supportsHardLinks = .no }, ollama, source: needs).isAllowed, "no hard links needed")
        XCTAssertEqual(rules(report(T.drive { $0.supportsSymlinks = .unknown }, backups), .refuse), [.e11])
    }

    func testE12FreeSpace() {
        // 30 GB source on a 500 GB drive: needs max(33 GB, 30 + max(10, 25) = 55 GB) free.
        XCTAssertEqual(Eligibility.requiredFree(forBytes: 30_000_000_000, capacity: 500_000_000_000), 55_000_000_000)
        XCTAssertEqual(Eligibility.requiredFree(forBytes: 30_000_000_000, capacity: 100_000_000_000), 40_000_000_000, "10 GB floor")
        XCTAssertEqual(Eligibility.requiredFree(forBytes: 0, capacity: 0), 10_000_000_000)
        let tight = report(T.drive { $0.availableBytes = 38_000_000_000 }, ollama)
        XCTAssertEqual(tight.firstRefusal?.rule, .e12)
        XCTAssertEqual(tight.firstRefusal?.message, "Needs 55 GB free on Outboard drive; it has 38 GB.")
        XCTAssertTrue(report(T.drive { $0.availableBytes = 55_000_000_000 }, ollama).isAllowed)
        XCTAssertFalse(report(T.drive { $0.availableBytes = 54_999_999_999 }, ollama).isAllowed)
        // unknown space refuses for every recipe
        XCTAssertEqual(report(T.drive { $0.availableBytes = nil }, derived).firstRefusal?.unknownSignal, "free space")
        // a quota is honoured
        XCTAssertFalse(report(T.drive { $0.quotaBytes = 40_000_000_000 }, ollama).isAllowed)
        // no source, no verdict (the list of drives)
        XCTAssertTrue(report(T.drive { $0.availableBytes = 1 }).isAllowed)
    }

    func testE13Synced() {
        XCTAssertEqual(report(T.drive { $0.isSyncedLocation = true }, ollama).firstRefusal?.message, "This location is synced by a cloud service.")
        XCTAssertEqual(report(T.drive(name: "Dropbox")).firstRefusal?.rule, .e13)
    }

    func testE14MountedUnderVolumes() {
        XCTAssertEqual(report(T.drive { $0.mountPoint = "/Users/jane/mnt" }).firstRefusal?.message, "This drive is mounted in an unusual place.")
        XCTAssertEqual(report(T.drive { $0.mountPoint = "/Volumes" }).firstRefusal?.rule, .e14)
        XCTAssertEqual(report(T.drive { $0.mountPoint = "/Volumes/a/b" }).firstRefusal?.rule, .e14)
    }

    func testE15Smart() {
        XCTAssertEqual(report(T.drive { $0.smart = .failing }).firstRefusal?.message, "macOS reports this drive as failing.")
        XCTAssertTrue(report(T.drive { $0.smart = .notSupported }).isAllowed)
        XCTAssertTrue(report(T.drive { $0.smart = .unknown }, backups).isAllowed, "unknown health is information")
        XCTAssertEqual(rules(report(T.drive { $0.smart = .unknown }, backups), .info).contains(.e15), true)
    }

    func testE16EncryptionForSensitiveRecipes() {
        let no = report(T.drive { $0.isEncrypted = .no }, backups)
        XCTAssertEqual(no.acks.first?.message, "This drive isn't encrypted. Anyone who finds it can read the backups on it.")
        XCTAssertEqual(no.acks.first?.ackID, "ack-e16")
        let unknown = report(T.drive { $0.isEncrypted = .unknown }, backups)
        XCTAssertEqual(unknown.acks.first?.message, "We couldn't tell whether this drive is encrypted. Tick to confirm you accept that.")
        XCTAssertTrue(report(T.drive { $0.isEncrypted = .yes }, backups).acks.isEmpty)
        XCTAssertTrue(report(T.drive { $0.isEncrypted = .no }, ollama).acks.isEmpty, "only sensitive recipes ask")
    }

    func testE17Marker() {
        XCTAssertEqual(report(T.drive()).infos.first { $0.rule == .e17 }?.message, "Your Outboard drive.")
        XCTAssertNil(report(T.drive { $0.hasOutboardMarker = false }).infos.first { $0.rule == .e17 })
    }

    func testE18Freshness() {
        let d = T.drive()
        XCTAssertNil(Eligibility.freshness(plannedUUID: T.uuid, plannedMountPoint: "/Volumes/Outboard", now: d))
        XCTAssertNil(Eligibility.freshness(plannedUUID: T.uuid.lowercased(), plannedMountPoint: "/Volumes/Outboard/", now: d))
        XCTAssertEqual(Eligibility.freshness(plannedUUID: T.uuid, plannedMountPoint: "/Volumes/Outboard", now: nil)?.message, "The drive changed while we were getting ready. Nothing was changed.")
        XCTAssertEqual(Eligibility.freshness(plannedUUID: "OTHER", plannedMountPoint: "/Volumes/Outboard", now: d)?.rule, .e18)
        XCTAssertEqual(Eligibility.freshness(plannedUUID: T.uuid, plannedMountPoint: "/Volumes/Outboard 1", now: d)?.outcome, .refuse)
        XCTAssertEqual(Eligibility.freshness(plannedUUID: T.uuid, plannedMountPoint: "/Volumes/Outboard", now: T.drive(uuid: nil))?.rule, .e18)
    }

    func testE19SleepAndHubsOnlyInTheGeneralVerdict() {
        XCTAssertEqual(report(T.drive()).infos.first { $0.rule == .e19 }?.message, "Sleep can disconnect drives, hubs more often. If you can, plug the drive straight in. Outboard doesn't change your power settings.")
        XCTAssertNil(report(T.drive(), ollama).infos.first { $0.rule == .e19 })
    }

    // MARK: the unknown-signal table

    func testUnknownSignalsRefuseForIrreplaceableAndAskOtherwiseAndNeverPassSilently() {
        let sensitiveSource = SourceNeeds(logicalBytes: 1_000, isCaseSensitive: .yes, hasHardLinks: false, hasSymlinks: true)
        let cases: [(String, (inout DriveFacts) -> Void, EligibilityRule, EligibilityOutcome, EligibilityOutcome)] = [
            ("E3", { $0.isInternal = .unknown }, .e3, .refuse, .refuse),
            ("E5", { $0.isSolidState = .unknown }, .e5, .refuse, .ack),
            ("E6", { $0.isWritable = .unknown }, .e6, .refuse, .refuse),
            ("E7", { $0.timeMachine = TimeMachineSignals() }, .e7, .refuse, .ack),
            ("E9", { $0.ownershipHonoured = .unknown }, .e9, .refuse, .ack),
            ("E10", { $0.isCaseSensitive = .unknown }, .e10, .refuse, .ack),
            ("E11", { $0.supportsSymlinks = .unknown }, .e11, .refuse, .ack),
            ("E12", { $0.availableBytes = nil }, .e12, .refuse, .refuse),
            ("E16", { $0.isEncrypted = .unknown }, .e16, .ack, .ack),
        ]
        for (name, change, rule, forIrreplaceable, forOthers) in cases {
            let d = T.drive(mutate: change)
            let strict = report(d, backups, source: sensitiveSource).verdicts.first { $0.rule == rule }
            let loose = report(d, ollama, source: sensitiveSource).verdicts.first { $0.rule == rule && $0.outcome != .info }
            XCTAssertEqual(strict?.outcome, forIrreplaceable, name)
            if name != "E16" { XCTAssertEqual(loose?.outcome, forOthers, name) } else { XCTAssertNil(loose, "E16 only asks for sensitive recipes") }
            XCTAssertNotNil(strict?.unknownSignal ?? (rule == .e16 ? "x" : nil), "\(name): the message names the signal")
            // an unknown signal never becomes a silent yes: either the report refuses, or an ack stands in the way of the plan
            let rep = report(d, ollama, source: sensitiveSource)
            XCTAssertTrue(!rep.isAllowed || rep.acks.contains { $0.rule == rule } || rule == .e16, name)
        }
        // E15 is information in both cases
        XCTAssertEqual(report(T.drive { $0.smart = .unknown }, backups).verdicts.first { $0.rule == .e15 }?.outcome, .info)
    }

    func testEveryMessageIsFreeOfBannedPhrases() {
        var all: [DriveFacts] = []
        for fs in FileSystemKind.allCases { all.append(T.drive { $0.fileSystem = fs; $0.fileSystemRaw = "ext4" }) }
        all.append(T.drive { $0.isLocal = false; $0.isInternal = .unknown; $0.isWritable = .unknown; $0.isSolidState = .unknown; $0.isEncrypted = .unknown
            $0.ownershipHonoured = .unknown; $0.supportsSymlinks = .unknown; $0.availableBytes = nil; $0.smart = .failing
            $0.timeMachine = TimeMachineSignals(); $0.linkMegabitsPerSecond = 480; $0.isLocked = true; $0.mountPoint = "/x"
            $0.isCaseSensitive = .unknown; $0.timeMachineSiblingInContainer = true })
        all.append(T.drive { $0.isSolidState = .no; $0.isEncrypted = .no; $0.availableBytes = 1; $0.smart = .unknown; $0.ownershipHonoured = .no; $0.isSyncedLocation = true })
        for d in all {
            for r in [nil, ollama, backups, photos, derived] as [Recipe?] {
                for v in report(d, r, source: needs).verdicts {
                    XCTAssertEqual(BannedPhrases.hits(in: v.message), [], v.message)
                    XCTAssertEqual(BannedPhrases.hits(in: v.plateText), [], v.plateText)
                    XCTAssertFalse(v.plateText.contains("Tick"), "the chooser has nothing to tick: \(v.plateText)")
                    if v.outcome != .ack { XCTAssertEqual(v.plateText, v.message, "only an acknowledgement is reworded") }
                }
            }
            XCTAssertEqual(BannedPhrases.hits(in: Eligibility.summary(d)), [])
        }
    }

    func testThePlateTextTurnsTheTickIntoWhatWillBeAsked() {
        func ack(_ rule: EligibilityRule, _ change: (inout DriveFacts) -> Void, _ recipe: Recipe) -> EligibilityVerdict? {
            report(T.drive(mutate: change), recipe, source: needs).acks.first { $0.rule == rule }
        }
        let ssd = ack(.e5, { $0.isSolidState = .unknown }, ollama)
        XCTAssertEqual(ssd?.message, "We couldn't tell whether this is a solid-state drive. Tick to confirm it is.", "the box keeps the pinned wording")
        XCTAssertEqual(ssd?.plateText, "We couldn't tell whether this is a solid-state drive. You'll be asked to confirm it is in the next step.")
        XCTAssertEqual(ack(.e7, { $0.timeMachine = TimeMachineSignals() }, ollama)?.plateText,
                       "We couldn't tell whether this is your Time Machine disk. You'll be asked to confirm it isn't in the next step.")
        XCTAssertEqual(ack(.e16, { $0.isEncrypted = .unknown }, backups)?.plateText,
                       "We couldn't tell whether this drive is encrypted. You'll be asked to confirm you accept that in the next step.")
        // an acknowledgement that never said "Tick" reads as it is
        let plain = ack(.e16, { $0.isEncrypted = .no }, backups)
        XCTAssertEqual(plain?.plateText, plain?.message)
    }

    func testSummaryUsesPlainLabels() {
        XCTAssertEqual(Eligibility.summary(T.drive { $0.isEncrypted = .unknown; $0.availableBytes = 38_000_000_000 }),
                       "USB \u{00B7} APFS \u{00B7} encrypted: unknown \u{00B7} Time Machine: no \u{00B7} 38 GB free")
        XCTAssertTrue(Eligibility.summary(T.drive { $0.availableBytes = nil }).hasSuffix("free space unknown"))
    }

    func testReportsAreOrderedByRuleAndCarryTheRecipe() {
        let d = T.drive { $0.fileSystem = .exfat; $0.isWritable = .no; $0.smart = .failing; $0.isSolidState = .no }
        let rep = report(d, ollama)
        XCTAssertEqual(rep.verdicts.map(\.rule), rep.verdicts.map(\.rule).sorted { EligibilityRule.allCases.firstIndex(of: $0)! < EligibilityRule.allCases.firstIndex(of: $1)! })
        XCTAssertEqual(rep.recipeID, "ollama-models")
        XCTAssertEqual(rep.volumeID, T.uuid)
        XCTAssertEqual(rep.firstRefusal?.rule, .e4)
    }
}
