import Foundation
import XCTest
@testable import OutboardCore

final class PlanTextTests: XCTestCase {
    private let release = Policy.release
    private var on: Preferences { var p = Preferences(); p.showUnverifiedMoves = true; return p }
    private let mac = MinOS(15, 1)

    private func plan(_ scans: [SizeScan], prefs: Preferences? = nil) -> StoragePlan {
        StoragePlanBuilder.build(recipes: Catalogue.all, scans: scans, prefs: prefs ?? on, policy: release, macOS: mac, now: T.t0)
    }

    private func gb(_ n: Double) -> UInt64 { UInt64(n * 1_000_000_000) }

    private var spec87: [SizeScan] {
        [T.scan("xcode-deriveddata", bytes: gb(41.2)), T.scan("ollama-models", bytes: gb(30.4)), T.scan("ios-device-backups", bytes: gb(15.7))]
    }

    // MARK: Format

    func testBytesAreFinderStyleDecimal() {
        XCTAssertEqual(Format.bytes(0), "0 bytes")
        XCTAssertEqual(Format.bytes(1), "1 byte")
        XCTAssertEqual(Format.bytes(999), "999 bytes")
        XCTAssertEqual(Format.bytes(1_000), "1 KB")
        XCTAssertEqual(Format.bytes(412_000), "412 KB")
        XCTAssertEqual(Format.bytes(1_300_000_000), "1.3 GB")
        XCTAssertEqual(Format.bytes(41_000_000_000), "41 GB")
        XCTAssertEqual(Format.bytes(41_230_000_000), "41.2 GB")
        XCTAssertEqual(Format.bytes(340_000_000_000), "340 GB")
        XCTAssertEqual(Format.bytes(999_950_000), "1 GB")
        XCTAssertEqual(Format.bytes(1_000_000_000_000), "1 TB")
        XCTAssertEqual(Format.atLeast(3_000_000_000), "at least 3 GB")
        XCTAssertEqual(Format.count(1, "file"), "1 file")
        XCTAssertEqual(Format.count(48_211, "file"), "48,211 files")
        XCTAssertEqual(Format.number(1_234_567), "1,234,567")
        XCTAssertEqual(Format.number(999), "999")
        XCTAssertEqual(Format.number(-1_000), "-1,000")
        XCTAssertEqual(Format.date(T.t0), "2027-01-15")
        XCTAssertEqual(Format.dateTime(T.t0), "2027-01-15 08:00 UTC")
        XCTAssertEqual(Format.shortDate(T.t0), "15 Jan")
        XCTAssertEqual(PathText.tilde("/Users/jane/Library/x", home: "/Users/jane"), "~/Library/x")
        XCTAssertEqual(PathText.tilde("/Users/janet/x", home: "/Users/jane"), "/Users/janet/x", "whole components only")
        XCTAssertEqual(PathText.tilde("/Users/jane", home: "/Users/jane/"), "~")
        XCTAssertEqual(PathText.expandTilde("~/Library/x", home: "/Users/jane/"), "/Users/jane/Library/x")
        XCTAssertEqual(PathText.expandTilde("/abs", home: "/Users/jane"), "/abs")
    }

    func testRowsAddUpToTheHeadlineForRandomInputs() {
        var rng = SplitMix64(seed: 2026_10_03)
        for _ in 0..<2_000 {
            let n = Int(rng.next() % 9) + 1
            let rows = (0..<n).map { _ in 1_000_000_000 + rng.next() % 200_000_000_000 }
            let rounded = Format.gigabytesRounded(rows)
            let total = rows.reduce(0, +)
            XCTAssertEqual(rounded.reduce(0, +), Int((total + 500_000_000) / 1_000_000_000), "\(rows)")
            for (r, g) in zip(rows, rounded) { XCTAssertTrue(abs(Double(g) - Double(r) / 1e9) < 1, "a row moves less than 1 GB") }
        }
        XCTAssertEqual(Format.gigabytesRounded([]), [])
        XCTAssertEqual(Format.gigabytesRounded([1_500_000_000, 1_500_000_000]), [2, 1], "ties go to the earlier row; 3 GB in all")
        XCTAssertEqual(Format.gigabytesRounded([40_900_000_000, 30_400_000_000, 15_700_000_000]).reduce(0, +), 87)
    }

    // MARK: the builder

    func testTheBuilderGivesEachEntryOneStatusAndRanksThem() {
        let scans = spec87 + [T.scan("photos-library", bytes: gb(212)), T.scan("npm-cache", bytes: gb(0.4)),
                              T.scan("huggingface-hub-cache", bytes: 0, state: .absent), T.scan("llamacpp-cache", bytes: 0, isLink: true, reason: .alreadyRedirected),
                              T.scan("xcode-archives", bytes: 0, state: .notMeasured, reason: .denied)]
        let p = plan(scans)
        XCTAssertEqual(p.items.count, 24, "one row per catalogue entry")
        XCTAssertEqual(Set(p.items.map(\.recipeID)).count, 24)
        func status(_ id: String) -> PlanStatus { p.items.first { $0.recipeID == id }!.status }
        XCTAssertEqual(status("xcode-deriveddata"), .movable)
        XCTAssertEqual(status("npm-cache"), .belowThreshold)
        XCTAssertEqual(status("huggingface-hub-cache"), .absent)
        XCTAssertEqual(status("llamacpp-cache"), .alreadyMoved)
        XCTAssertEqual(status("xcode-archives"), .notMeasured)
        XCTAssertEqual(status("photos-library"), .guided)
        XCTAssertEqual(status("steam-library"), .guided)
        XCTAssertEqual(status("never-homebrew"), .neverMove)
        XCTAssertEqual(p.headlineBytes, gb(41.2) + gb(30.4) + gb(15.7))
        // order: movable by size, then guided, then not measured, then the rest, then never cards
        let order = p.items.map(\.status)
        XCTAssertEqual(p.items.prefix(3).map(\.recipeID), ["xcode-deriveddata", "ollama-models", "ios-device-backups"])
        XCTAssertEqual(p.items[3].recipeID, "photos-library", "the biggest guided card first")
        let firstNever = order.firstIndex(of: .neverMove)!
        XCTAssertTrue(order[firstNever...].allSatisfy { $0 == .neverMove })
        XCTAssertLessThan(order.firstIndex(of: .notMeasured)!, order.firstIndex(of: .belowThreshold)!)
        XCTAssertEqual(p.items.first { $0.recipeID == "xcode-archives" }?.notMeasuredReason, .denied)
        XCTAssertEqual(p.items.first { $0.recipeID == "never-homebrew" }?.neverReason, NeverTexts.homebrew)
        XCTAssertEqual(p.never.count, 9)
        XCTAssertEqual(p.guided.count, 8)
    }

    func testUnverifiedMovesAreHiddenUnlessThePreferenceIsOn() {
        let hidden = plan(spec87, prefs: Preferences())
        XCTAssertEqual(hidden.movable, [], "nothing the build would not offer is counted")
        XCTAssertEqual(hidden.headlineBytes, 0)
        XCTAssertEqual(hidden.items.first { $0.recipeID == "ollama-models" }?.status, .hiddenUntilVerified)
        XCTAssertEqual(hidden.items.first { $0.recipeID == "ollama-models" }?.isUnverified, true)
        XCTAssertEqual(plan(spec87).items.first { $0.recipeID == "ollama-models" }?.isUnverified, true)
        #if DEBUG
        let tested = StoragePlanBuilder.build(recipes: Catalogue.all, scans: spec87, prefs: Preferences(), policy: .testing, macOS: mac, now: T.t0)
        XCTAssertEqual(tested.movable.count, 3)
        XCTAssertEqual(tested.items.first { $0.recipeID == "ollama-models" }?.isUnverified, false)
        #endif
    }

    func testAHiddenBigFolderIsNeverReportedAsNothingFound() {
        let off = Preferences()
        let p = plan([T.scan("xcode-deriveddata", bytes: gb(60))], prefs: off)
        XCTAssertEqual(p.items.first { $0.recipeID == "xcode-deriveddata" }?.status, .hiddenUntilVerified)
        XCTAssertEqual(p.hiddenPresent.map(\.recipeID), ["xcode-deriveddata"])
        let card = StoragePlanText.card(from: p, relocations: [], prefs: off, isSample: false)
        XCTAssertNotEqual(card.variant, .nothingFound)
        XCTAssertEqual(card.variant, .small)
        XCTAssertEqual(card.headline, "Some moves are hidden for now")
        XCTAssertEqual(card.measuredLine, "60 GB sits in folders whose moves are hidden until they are tried on a real Mac. Turn them on in Preferences to see them.")
        XCTAssertEqual(card.totalBytes, 0, "a hidden folder is not in the figure")
        XCTAssertFalse(card.isShareable)
        let text = StoragePlanText.copyText(card)
        XCTAssertEqual(text, "Some moves on my Mac are hidden until they are tried on a real Mac. Measured with Outboard; nothing moved. everydayopen.github.io/outboard")
        XCTAssertFalse(text.contains("No big folders") || text.contains("Nothing big"))
        XCTAssertEqual(BannedPhrases.hits(in: [card.headline, card.measuredLine, text].joined(separator: "\n")), [])
        // a hidden folder under 1 GB, or one that is not on this Mac, changes nothing
        let small = plan([T.scan("xcode-deriveddata", bytes: gb(0.4)), T.scan("ollama-models", bytes: 0, state: .absent)], prefs: off)
        XCTAssertEqual(small.hiddenPresent, [])
        XCTAssertEqual(StoragePlanText.card(from: small, relocations: [], prefs: off, isSample: false).variant, .nothingFound)
        XCTAssertEqual(StoragePlanText.card(from: plan([], prefs: off), relocations: [], prefs: off, isSample: false).variant, .nothingFound)
        // the same Mac with the preference on offers the move
        XCTAssertEqual(StoragePlanText.card(from: plan([T.scan("xcode-deriveddata", bytes: gb(60))]), relocations: [], prefs: on, isSample: false).variant, .plan)
        // two hidden folders are added up
        let two = plan([T.scan("xcode-deriveddata", bytes: gb(60)), T.scan("npm-cache", bytes: gb(1.2))], prefs: off)
        XCTAssertTrue(StoragePlanText.card(from: two, relocations: [], prefs: off, isSample: false).measuredLine.hasPrefix("61.2 GB sits in folders"))
    }

    func testAFloorIsNeverCountedAndAnOldMacHidesTheAppStoreCard() {
        let floor = T.scan("ollama-models", bytes: gb(9), state: .atLeast)
        let p = plan([floor])
        XCTAssertEqual(p.items.first { $0.recipeID == "ollama-models" }?.status, .notMeasured, "a floor is not a measurement: one status for the plan, the card and the headline")
        XCTAssertEqual(p.items.first { $0.recipeID == "ollama-models" }?.isLowerBound, true)
        XCTAssertEqual(p.headlineBytes, 0)
        XCTAssertEqual(p.movable, [])
        let floorCard = StoragePlanText.card(from: p, relocations: [], prefs: on, isSample: false)
        XCTAssertEqual(floorCard.variant, .partlyMeasured, "the card cannot say there is nothing to move")
        XCTAssertEqual(floorCard.rows.map(\.text), ["at least 9 GB"])
        XCTAssertEqual(floorCard.rows.first?.note, "only partly measured")
        XCTAssertEqual(floorCard.rows.first?.bytes, 0, "never counted in the total")
        XCTAssertTrue(StoragePlanText.copyText(floorCard).hasPrefix("Part of my Mac couldn't be measured"))
        let withFloor = StoragePlanText.card(from: plan(spec87 + [T.scan("huggingface-hub-cache", bytes: gb(9), state: .atLeast)]), relocations: [], prefs: on, isSample: false)
        XCTAssertEqual(withFloor.variant, .partlyMeasured)
        XCTAssertEqual(withFloor.headline, "Your Mac could free up to 87 GB", "the floor is not added to the figure")
        XCTAssertEqual(withFloor.rows.map(\.text), ["41 GB", "30 GB", "16 GB", "at least 9 GB"])
        XCTAssertEqual(StoragePlanBuilder.build(recipes: Catalogue.all, scans: [], prefs: on, policy: release, macOS: MinOS(15, 0), now: T.t0).items.first { $0.recipeID == "mas-large-apps" }?.status, .needsNewerMacOS)
        let tiny = plan([T.scan("ollama-models", bytes: gb(0.2), state: .atLeast)])
        XCTAssertEqual(tiny.items.first { $0.recipeID == "ollama-models" }?.status, .notMeasured)
        // the companion folder counts with its recipe
        let hf = plan([T.scan("huggingface-hub-cache", bytes: gb(0.7)), T.scan("huggingface-hub-cache", path: "~/.cache/huggingface/xet", bytes: gb(0.6))])
        XCTAssertEqual(hf.items.first { $0.recipeID == "huggingface-hub-cache" }?.status, .movable)
        XCTAssertEqual(hf.items.first { $0.recipeID == "huggingface-hub-cache" }?.allocatedBytes, gb(1.3))
        XCTAssertEqual(SizeScan.merged([T.scan("huggingface-hub-cache", bytes: gb(0.7)), T.scan("huggingface-hub-cache", bytes: gb(0.6))])?.allocatedBytes, gb(1.3))
        XCTAssertNil(SizeScan.merged([]))
    }

    // MARK: the card

    func testThePlanCardIsTheSpecs() {
        let card = StoragePlanText.card(from: plan(spec87), relocations: [], prefs: on, isSample: false)
        XCTAssertEqual(card.variant, .plan)
        XCTAssertEqual(card.headline, "Your Mac could free up to 87 GB")
        XCTAssertEqual(card.rows.map(\.label), ["Xcode build data", "Ollama models", "iPhone backups"])
        XCTAssertEqual(card.rows.map(\.text), ["41 GB", "30 GB", "16 GB"], "largest remainder: 41.2 + 30.4 + 15.7 = 87.3 rounds to 87")
        XCTAssertEqual(card.rows.map(\.text).map { Int($0.dropLast(3))! }.reduce(0, +), 87, "the rows add up to the headline")
        XCTAssertEqual(card.rows[0].fraction, 1.0)
        XCTAssertEqual(card.rows[1].fraction, 30.4 / 41.2, accuracy: 0.0001, "bars follow the unrounded bytes")
        XCTAssertNil(card.moreLine)
        XCTAssertEqual(card.measuredLine, "Measured on this Mac. Nothing was moved.")
        XCTAssertEqual(card.footnote, "Sizes are what these folders take on disk. Space comes back when the originals are trashed and the Trash is emptied.")
        XCTAssertEqual(card.website, "everydayopen.github.io/outboard")
        XCTAssertEqual(card.totalBytes, gb(41.2) + gb(30.4) + gb(15.7))
        XCTAssertTrue(card.isShareable)
        XCTAssertFalse(card.isSample)
        XCTAssertEqual(StoragePlanText.copyText(card),
                       "My Mac could free up to 87 GB: Xcode 41 GB, Ollama 30 GB, iPhone backups 16 GB. Measured with Outboard; nothing moved. everydayopen.github.io/outboard")
        XCTAssertTrue(StoragePlanText.card(from: plan(spec87), relocations: [], prefs: on, isSample: true).isSample)
    }

    func testMoreThanThreeRowsGetAMoreLine() {
        let scans = [T.scan("xcode-deriveddata", bytes: gb(41)), T.scan("ollama-models", bytes: gb(30)), T.scan("ios-device-backups", bytes: gb(16)),
                     T.scan("huggingface-hub-cache", bytes: gb(2)), T.scan("npm-cache", bytes: gb(1.4))]
        let card = StoragePlanText.card(from: plan(scans), relocations: [], prefs: on, isSample: false)
        XCTAssertEqual(card.headline, "Your Mac could free up to 90 GB")
        XCTAssertEqual(card.rows.count, 3)
        XCTAssertEqual(card.moreLine, "and 2 more (3 GB)")
        XCTAssertEqual(StoragePlanText.copyText(card), "My Mac could free up to 90 GB: Xcode 41 GB, Ollama 30 GB, iPhone backups 16 GB, and 2 more (3 GB). Measured with Outboard; nothing moved. everydayopen.github.io/outboard")
    }

    func testGuidedAppsAreAMutedLineAndNotInTheTotal() {
        let card = StoragePlanText.card(from: plan(spec87 + [T.scan("photos-library", bytes: gb(212))]), relocations: [], prefs: on, isSample: false)
        XCTAssertEqual(card.variant, .planWithGuided)
        XCTAssertEqual(card.headline, "Your Mac could free up to 87 GB")
        XCTAssertEqual(card.guidedLines, ["Also on this Mac: Photos library 212 GB. Photos moves it itself; Outboard shows the steps."])
        XCTAssertEqual(card.totalBytes, gb(41.2) + gb(30.4) + gb(15.7))
        let anonymous = StoragePlanText.card(from: plan(spec87 + [T.scan("photos-library", bytes: gb(212))]), relocations: [], prefs: { var p = on; p.showAppNamesOnCard = false; return p }(), isSample: false)
        XCTAssertEqual(anonymous.rows.map(\.label), ["Folder 1", "Folder 2", "Folder 3"])
        XCTAssertEqual(anonymous.guidedLines, ["Also on this Mac: a library of 212 GB. Its app moves it itself; Outboard shows the steps."])
        XCTAssertEqual(StoragePlanText.copyText(anonymous), "My Mac could free up to 87 GB from 3 folders. Measured with Outboard; nothing moved. everydayopen.github.io/outboard")
        for text in anonymous.rows.map(\.label) + anonymous.guidedLines + [anonymous.headline] { XCTAssertFalse(text.contains("Xcode") || text.contains("Ollama") || text.contains("Photos")) }
    }

    func testPartlyMeasuredNamesTheFolderAndWhyWithoutBlockingTheRest() {
        let scans = [T.scan("xcode-deriveddata", bytes: gb(41)), T.scan("ollama-models", bytes: gb(30)),
                     T.scan("ios-device-backups", bytes: 0, state: .notMeasured, reason: .needsFullDiskAccess)]
        let card = StoragePlanText.card(from: plan(scans), relocations: [], prefs: on, isSample: false)
        XCTAssertEqual(card.variant, .partlyMeasured)
        XCTAssertEqual(card.headline, "Your Mac could free up to 71 GB")
        let unmeasured = card.rows.last
        XCTAssertEqual(unmeasured?.label, "iPhone backups")
        XCTAssertEqual(unmeasured?.text, "not measured")
        XCTAssertEqual(unmeasured?.note, "needs Full Disk Access")
        XCTAssertEqual(unmeasured?.fraction, 0)
        XCTAssertEqual(StoragePlanText.copyText(card), "My Mac could free up to 71 GB: Xcode 41 GB, Ollama 30 GB. Measured with Outboard; nothing moved. everydayopen.github.io/outboard")
        let onlyUnmeasured = StoragePlanText.card(from: plan([scans[2]]), relocations: [], prefs: on, isSample: false)
        XCTAssertEqual(onlyUnmeasured.variant, .partlyMeasured)
        XCTAssertEqual(onlyUnmeasured.headline, "Not everything could be measured")
        XCTAssertTrue(StoragePlanText.copyText(onlyUnmeasured).hasPrefix("Part of my Mac couldn't be measured"))
    }

    func testSmallAndNothingFound() {
        let small = StoragePlanText.card(from: plan([T.scan("xcode-deriveddata", bytes: gb(3.1)), T.scan("npm-cache", bytes: gb(1.2))]), relocations: [], prefs: on, isSample: false)
        XCTAssertEqual(small.variant, .small)
        XCTAssertEqual(small.headline, "Nothing big to move")
        XCTAssertEqual(small.measuredLine, "The largest is Xcode build data at 3.1 GB.")
        XCTAssertFalse(small.isShareable, "no share button")
        XCTAssertEqual(small.rows, [])
        let none = StoragePlanText.card(from: plan([]), relocations: [], prefs: on, isSample: false)
        XCTAssertEqual(none.variant, .nothingFound)
        XCTAssertEqual(none.headline, "No big folders from the apps Outboard knows")
        XCTAssertEqual(none.measuredLine, "Outboard knows 15 apps. More are added in updates.")
        XCTAssertFalse(none.isShareable)
        let guidedOnly = StoragePlanText.card(from: plan([T.scan("photos-library", bytes: gb(212))]), relocations: [], prefs: on, isSample: false)
        XCTAssertEqual(guidedOnly.variant, .small, "something big is there, but Outboard does not move it")
        XCTAssertEqual(guidedOnly.measuredLine, "Nothing here is a folder Outboard moves itself.")
        XCTAssertEqual(guidedOnly.guidedLines.count, 1)
    }

    func testTheCardAfterMoves() {
        let a = T.record(id: "a", recipeID: "xcode-deriveddata", state: .swapped, method: .defaults) { $0.logicalBytes = gb(41.2); $0.recipeName = "Xcode build data" }
        let b = T.record(id: "b", recipeID: "ollama-models", state: .confirmed, safety: .inTrash) { $0.logicalBytes = gb(30.4) }
        let card = StoragePlanText.card(from: plan(spec87), relocations: [a, b], prefs: on, isSample: false)
        XCTAssertEqual(card.variant, .afterMoves)
        XCTAssertEqual(card.headline, "Moved 72 GB to your Outboard drive")
        XCTAssertEqual(card.rows.map(\.label), ["Xcode build data", "Ollama models"])
        XCTAssertEqual(card.measuredLine, "Safety copies still on this Mac: 41.2 GB until you confirm.")
        XCTAssertEqual(StoragePlanText.copyText(card), "Moved 72 GB to your Outboard drive: Xcode 41 GB, Ollama 31 GB. Moved with Outboard; every step is in its log. everydayopen.github.io/outboard")
        // a rolled-back or aborted relocation is not "moved"
        let rolled = T.record(id: "c", state: .rolledBack)
        XCTAssertNotEqual(StoragePlanText.card(from: plan(spec87), relocations: [rolled], prefs: on, isSample: false).variant, .afterMoves)
        let allConfirmed = StoragePlanText.card(from: plan([]), relocations: [b], prefs: on, isSample: false)
        XCTAssertEqual(allConfirmed.measuredLine, "Originals are in the Trash: 30.4 GB until you empty it.")
        // two drives
        var other = b
        other.id = "d"
        other.volume = VolumeRef(uuid: "OTHER", name: "Backup", token: "t")
        XCTAssertEqual(StoragePlanText.card(from: plan([]), relocations: [a, other], prefs: on, isSample: false).headline, "Moved 72 GB to 2 drives")
    }

    func testTheCardAfterMovesNeverShowsTheDrivesName() {
        let secret = "Zorblax Vault"
        let a = T.record(id: "a", recipeID: "ollama-models", state: .swapped) { $0.volume = VolumeRef(uuid: T.uuid, name: secret, token: "t"); $0.logicalBytes = gb(31) }
        for names in [true, false] {
            var prefs = on
            prefs.showAppNamesOnCard = names
            let card = StoragePlanText.card(from: plan(spec87), relocations: [a], prefs: prefs, isSample: false)
            XCTAssertEqual(card.variant, .afterMoves)
            let all = ([card.headline, card.measuredLine, card.footnote, card.moreLine ?? ""] + card.rows.flatMap { [$0.label, $0.text, $0.note ?? ""] } + card.guidedLines
                       + [StoragePlanText.copyText(card)]).joined(separator: "\n")
            XCTAssertFalse(all.contains("Zorblax"), "the card says 'your Outboard drive', never the drive's own name: \(all)")
            XCTAssertFalse(all.contains(secret))
        }
    }

    func testTheCardNeverShowsPathsNamesOrIDs() {
        let variants = [
            plan(spec87 + [T.scan("photos-library", bytes: gb(212))]), plan(spec87), plan([]), plan([T.scan("xcode-deriveddata", bytes: gb(2))]),
            plan([T.scan("ios-device-backups", bytes: 0, state: .notMeasured, reason: .needsFullDiskAccess)]),
            plan([T.scan("xcode-deriveddata", bytes: gb(60))], prefs: Preferences()), plan([T.scan("ollama-models", bytes: gb(9), state: .atLeast)]),
        ]
        let record = T.record(recipeID: "xcode-deriveddata", state: .swapped, method: .defaults)
        for names in [true, false] {
            var prefs = on
            prefs.showAppNamesOnCard = names
            for p in variants + [plan(spec87)] {
                for rel in [[RelocationRecord](), [record]] {
                    let card = StoragePlanText.card(from: p, relocations: rel, prefs: prefs, isSample: false)
                    let all = ([card.headline, card.measuredLine, card.footnote, card.moreLine ?? ""] + card.rows.flatMap { [$0.label, $0.text, $0.note ?? ""] } + card.guidedLines
                               + [StoragePlanText.copyText(card)]).joined(separator: "\n").replacingOccurrences(of: card.website, with: "")
                    XCTAssertFalse(all.contains("/"), "no paths: \(all)")
                    XCTAssertFalse(all.contains("jane"), "no user name")
                    XCTAssertFalse(all.contains(T.uuid), "no volume ID")
                    XCTAssertFalse(all.contains("Library"), "no folder names")
                    XCTAssertEqual(BannedPhrases.hits(in: all), [], all)
                }
            }
        }
    }
}
