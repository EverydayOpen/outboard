import Foundation
import XCTest
@testable import OutboardCore

// Tests for the frozen Model (architect). The core owner adds the real suites beside this file.
final class ModelTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func roundTrip<T: Codable & Equatable>(_ value: T, file: StaticString = #filePath, line: UInt = #line) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(T.self, from: enc.encode(value))
        XCTAssertEqual(back, value, file: file, line: line)
    }

    private func volume() -> VolumeRef { VolumeRef(uuid: "3E1C0B7A-0000-4000-8000-000000000001", name: "Outboard", token: "tok") }

    private var xcodeRecipe: Recipe {
        Recipe(id: "xcode-deriveddata", name: "Xcode build data", bundleIDs: ["com.apple.dt.Xcode"], processNames: ["xcodebuild"],
               source: "~/Library/Developer/Xcode/DerivedData",
               method: .defaults(domain: "com.apple.dt.Xcode", keys: [
                   DefaultsKeySpec(name: "IDECustomDerivedDataLocation", type: .string, value: .destinationPath),
                   DefaultsKeySpec(name: "IDEDerivedDataPathMode", type: .int, value: .int(1), neutral: .int(0), valueVerified: false),
               ], restore: .writePrior),
               riskClass: .regenerable, onDriveMissing: .revertSetting, confidence: .medium, beta: .b1,
               consent: ConsentText(what: "Xcode's build data", whatChanges: "x", whatToKnow: ["a"], checkboxes: [ConsentCheckbox(id: "quit", text: "I have quit Xcode.")]),
               missingDriveEffect: "Xcode goes back to its normal folder.", sources: ["https://example.com/doc"])
    }

    func testTriNeverBecomesYesFromNil() {
        XCTAssertEqual(Tri(nil), .unknown)
        XCTAssertEqual(Tri(true), .yes)
        XCTAssertEqual(Tri(false), .no)
        XCTAssertFalse(Tri.unknown.isYes)
    }

    func testStateMachineHasNoWayOutOfATerminalAndOnlyAbortsBeforeTheSwap() {
        for s in MoveState.allCases where s.isTerminal { XCTAssertTrue(s.legalSuccessors.isEmpty, "\(s)") }
        for s in MoveState.allCases where s.legalSuccessors.contains(.aborted) { XCTAssertTrue(s == .planned || s.isInFlight, "\(s)") }
        XCTAssertFalse(MoveState.swapped.legalSuccessors.contains(.aborted))
        XCTAssertTrue(MoveState.swapped.keepsOriginalOnMac)
        XCTAssertFalse(MoveState.originalTrashed.keepsOriginalOnMac)
        // every state reaches a terminal state
        for s in MoveState.allCases {
            var seen: Set<MoveState> = [s]
            var frontier: [MoveState] = [s]
            while let n = frontier.popLast() { for m in n.legalSuccessors where seen.insert(m).inserted { frontier.append(m) } }
            XCTAssertTrue(seen.contains { $0.isTerminal } || s.isTerminal, "\(s)")
        }
        XCTAssertEqual(Set(MoveState.allCases.filter(\.isActive)), [.swapped, .confirmed, .originalTrashed])
    }

    func testLabelsAreTheExactWordsOfTheSpec() {
        XCTAssertEqual(RiskClass.allCases.map(\.displayName), ["Rebuilds itself", "Large to download again", "Can't be replaced"])
        XCTAssertEqual(MethodKind.defaults.displayName, "Official setting")
        XCTAssertEqual(MethodKind.symlink.displayName, "Community method")
        XCTAssertEqual(MethodKind.guided.displayName, "Guided")
        XCTAssertEqual(Set(MethodKind.allCases.filter(\.isAutomated)), [.defaults, .symlink])
        XCTAssertEqual(VolumeRef(uuid: "u", name: "Outboard", token: "t").label, "Outboard drive")
        XCTAssertEqual(VolumeRef(uuid: "u", name: "Backup", token: "t").label, "Backup")
        XCTAssertEqual(Health.allCases.map(\.displayName), ["Healthy", "Drive away", "Held", "Conflict", "Needs attention"])
    }

    func testRecipeRoundTripAndPaths() throws {
        let r = xcodeRecipe
        try roundTrip(r)
        XCTAssertEqual(r.kind, .defaults)
        XCTAssertEqual(r.versionedID, "xcode-deriveddata@1")
        XCTAssertEqual(r.absoluteSource(home: "/Users/jane"), "/Users/jane/Library/Developer/Xcode/DerivedData")
        XCTAssertEqual(r.absoluteSource(home: "/Users/jane/"), "/Users/jane/Library/Developer/Xcode/DerivedData")
        XCTAssertEqual(r.drive, .automated)
        let g = Recipe(id: "photos-library", name: "Photos library", source: "~/Pictures/Photos Library.photoslibrary", method: .guided(steps: ["Quit Photos."]),
                       riskClass: .irreplaceable, onDriveMissing: .none, confidence: .high, beta: .b0, missingDriveEffect: "Photos starts a new library.", sources: ["https://example.com"])
        XCTAssertEqual(g.drive, .media)
        XCTAssertFalse(g.isAutomated)
        try roundTrip(g)
    }

    func testPolicyReleaseIsStrict() {
        XCTAssertFalse(Policy.release.allowsDiskImages)
        XCTAssertFalse(Policy.release.treatsAllRecipesAsVerified)
        #if DEBUG
        XCTAssertTrue(Policy.testing.allowsDiskImages)
        #endif
    }

    func testTimeMachineVerdictFailsClosedOnUnknown() {
        XCTAssertEqual(TimeMachineSignals().verdict, .unknown)
        XCTAssertTrue(TimeMachineSignals().allUnknown)
        XCTAssertEqual(TimeMachineSignals(apfsBackupRole: .no, listedByTmutil: .unknown, backupFolderAtRoot: .no).verdict, .no)
        XCTAssertEqual(TimeMachineSignals(apfsBackupRole: .no, listedByTmutil: .yes, backupFolderAtRoot: .no).verdict, .yes)
    }

    func testDriveFactsDefaultsAreNotAutomaticallyEligible() throws {
        let d = DriveFacts(uuid: nil, name: "X", mountPoint: "/Volumes/X")
        XCTAssertEqual(d.id, "mount:/Volumes/X")
        XCTAssertNil(d.uuid)
        try roundTrip(DriveFacts(uuid: "U", name: "Outboard", mountPoint: "/Volumes/Outboard", isEncrypted: .yes, capacityBytes: 500_000_000_000, availableBytes: 480_000_000_000, hasOutboardMarker: true, markerToken: "t"))
    }

    func testEligibilityReportDerivesAnswersFromVerdicts() {
        let ok = EligibilityReport(volumeID: "u", verdicts: [EligibilityVerdict(rule: .e17, outcome: .info, message: "Your Outboard drive.")])
        XCTAssertTrue(ok.isAllowed)
        let bad = EligibilityReport(volumeID: "u", verdicts: [EligibilityVerdict(rule: .e4, outcome: .refuse, message: "x"), EligibilityVerdict(rule: .e16, outcome: .ack, message: "y")])
        XCTAssertFalse(bad.isAllowed)
        XCTAssertEqual(bad.firstRefusal?.rule, .e4)
        XCTAssertEqual(bad.acks.first?.ackID, "ack-e16")
        XCTAssertEqual(EligibilityRule.allCases.count, 19)
    }

    func testPlanItemOnlyCountsMovableFullyMeasuredRows() {
        let scan = SizeScan(recipeID: "a", path: "~/x", state: .measured, fingerprint: TreeFingerprint(files: 3, allocatedBytes: 41_000_000_000), measuredAt: t0)
        var item = PlanItem(recipeID: "a", name: "A", kind: .symlink, risk: .expensive, status: .movable, scans: [scan])
        XCTAssertEqual(item.offeredBytes, 41_000_000_000)
        item.status = .guided
        XCTAssertEqual(item.offeredBytes, 0)
        item.status = .movable
        item.scans[0].state = .atLeast
        XCTAssertEqual(item.offeredBytes, 0, "a floor is never counted in the headline")
        let plan = StoragePlan(items: [PlanItem(recipeID: "a", name: "A", kind: .symlink, risk: .expensive, status: .movable, scans: [scan])], measuredAt: t0)
        XCTAssertEqual(plan.headlineBytes, 41_000_000_000)
    }

    func testJournalEntryRoundTripKeepsUnknownStepsAndDates() throws {
        let plan = JournalPlan(direction: .toDrive, recipeID: "ollama-models", recipeVersion: 1, recipeName: "Ollama models", method: .symlink,
                               risk: .expensive, onDriveMissing: .parkPlaceholder, macPath: "~/.ollama/models", volume: volume(),
                               relativePath: "Outboard/ollama-models/models", logicalBytes: 30_000_000_000, fileCount: 12,
                               consent: ConsentRecord(recipeVersion: 1, tickedIDs: ["quit"]))
        let begin = JournalEntry(id: "20261003T101500Z-3fa9c1", seq: 1, ts: t0, phase: .intent, step: .begin, recipe: "ollama-models@1", state: .planned, plan: plan)
        try roundTrip(begin)
        XCTAssertEqual(begin.moveStep, .begin)
        let future = JournalEntry(id: "m", seq: 2, ts: t0, phase: .result, step: "someFutureStep", status: .failed)
        try roundTrip(future)
        XCTAssertNil(future.moveStep)
        XCTAssertTrue(future.isProblem)
        XCTAssertNotEqual(begin.lineID, future.lineID)
    }

    func testMovePlanDerivedPaths() {
        let dest = PlanDestination(volumeUUID: "u", volumeName: "Outboard", mountPoint: "/Volumes/Outboard", volumeToken: "t", recipeFolder: "Outboard/xcode-deriveddata", leaf: "DerivedData")
        let plan = MovePlan(id: "ID1", recipeID: "xcode-deriveddata", recipeVersion: 1, recipeName: "Xcode build data", method: .defaults, risk: .regenerable,
                            sourcePath: "/Users/jane/Library/Developer/Xcode/DerivedData", macPath: "/Users/jane/Library/Developer/Xcode/DerivedData",
                            sourceStamp: FileStamp(device: 1, inode: 2, type: .directory), sourceFingerprint: TreeFingerprint(files: 10, logicalBytes: 100),
                            destination: dest, redirect: .symbolicLink(linkPath: "/a", target: "/b"), consent: ConsentRecord(recipeVersion: 1, tickedIDs: []), createdAt: t0)
        XCTAssertEqual(dest.relativePath, "Outboard/xcode-deriveddata/DerivedData")
        XCTAssertEqual(dest.finalPath, "/Volumes/Outboard/Outboard/xcode-deriveddata/DerivedData")
        XCTAssertEqual(plan.beforeMovePath, "/Users/jane/Library/Developer/Xcode/DerivedData.before-move")
        XCTAssertEqual(plan.stagingPath, "/Volumes/Outboard/Outboard/xcode-deriveddata/.staging-ID1")
        XCTAssertEqual(plan.sentinelPath, "/Volumes/Outboard/Outboard/xcode-deriveddata/.sentinel-ID1.json")
        XCTAssertFalse(plan.sentinelPath.hasPrefix(dest.finalPath + "/"), "the sentinel sits beside the data folder, never inside it")
    }

    func testFileStampIdentityIgnoresDirectoryMtime() {
        let a = FileStamp(device: 1, inode: 7, type: .directory, mtimeSeconds: 1)
        var b = a
        b.mtimeSeconds = 99
        XCTAssertTrue(a.isSameObject(as: b))
        let f = FileStamp(device: 1, inode: 7, type: .file, size: 5, mtimeSeconds: 1)
        var g = f
        g.size = 6
        XCTAssertFalse(f.isSameObject(as: g))
    }

    func testPreferencesDecodeFromAnEmptyBlobAndKeepDefaults() throws {
        let p = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        XCTAssertEqual(p, Preferences.default)
        XCTAssertFalse(p.showUnverifiedMoves)
        XCTAssertTrue(p.showAppNamesOnCard)
        let partial = try JSONDecoder().decode(Preferences.self, from: Data(#"{"showUnverifiedMoves":true}"#.utf8))
        XCTAssertTrue(partial.showUnverifiedMoves)
        XCTAssertTrue(partial.startAtLogin)
    }

    func testRecoveryActionsAndGuardSnapshotRoundTrip() throws {
        try roundTrip(RecoveryAction.abort(.interrupted, labelLeftovers: true))
        try roundTrip(RecoveryAction.needsAttention(.twoOriginals))
        try roundTrip(RecoveryAction.rollbackOriginal)
        try roundTrip(GuardSnapshot(relocations: [RelocationHealth(moveID: "m", health: .held, state: .restore, held: .uncleanRemoval, removal: .unclean)],
                                    banners: [Banner(id: "b", kind: .removedUnclean, text: "t", actions: [.checkAndReconnect], moveIDs: ["m"])]))
        XCTAssertEqual(GuardState.allCases.count, 12)
        XCTAssertTrue(GuardSnapshot.empty.isAllHealthy)
        XCTAssertFalse(GuardSnapshot.empty.showsAttentionDot)
        XCTAssertTrue(RemovalKind.unknown.needsCheckBeforeReconnect)
        XCTAssertFalse(RemovalKind.ejected.needsCheckBeforeReconnect)
    }

    func testRelocationRecordRoundTripAndReminder() throws {
        var rec = RelocationRecord(id: "m", recipeID: "ollama-models", recipeVersion: 1, recipeName: "Ollama models", method: .symlink, risk: .expensive,
                                   onDriveMissing: .parkPlaceholder, state: .swapped, macPath: "~/.ollama/models", volume: volume(),
                                   relativePath: "Outboard/ollama-models/models", logicalBytes: 30_000_000_000, fileCount: 10, safetyCopy: .kept,
                                   last: JournalMark(step: .swapped, phase: .result, status: .ok), createdAt: t0, updatedAt: t0, swappedAt: t0)
        try roundTrip(rec)
        XCTAssertTrue(rec.canRollBack)
        XCTAssertTrue(rec.isWatchedByGuard)
        XCTAssertFalse(rec.safetyCopyReminderDue(now: t0.addingTimeInterval(13 * 86_400)))
        XCTAssertTrue(rec.safetyCopyReminderDue(now: t0.addingTimeInterval(14 * 86_400)))
        rec.state = .confirmed
        XCTAssertFalse(rec.canRollBack)
        XCTAssertTrue(rec.canReturn)
    }

    func testDemoScenarioNamesAreUniqueAndConsentScenariosNameARecipe() {
        let raws = DemoScenario.allCases.map(\.rawValue)
        XCTAssertEqual(Set(raws).count, raws.count)
        XCTAssertEqual(DemoScenario(rawValue: "drive-away"), .driveAway)
        XCTAssertEqual(DemoScenario.consentOllama.consentRecipeID, "ollama-models")
        XCTAssertEqual(DemoScenario.allCases.filter { $0.consentRecipeID != nil }.count, 7)
    }

    func testNamesAndLimits() {
        XCTAssertEqual(Names.bundleID, "io.github.everydayopen.outboard")
        XCTAssertEqual(Names.website, "https://everydayopen.github.io/outboard")
        XCTAssertEqual(Names.beforeMoveSuffix, ".before-move")
        XCTAssertEqual(Limits.minOfferBytes, 1_000_000_000)
        XCTAssertEqual(Limits.returnSampleFiles, 200)
        XCTAssertEqual(Limits.firstDifferencesListed, 20)
    }
}
