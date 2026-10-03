import XCTest
@testable import OutboardCore

/// The demo scenarios (BUILD_PLAN §4.6, §9). They run through the real Core (`Eligibility`, `MovePlanner`, `MoveMachine`,
/// `RelocationFold`, `Recovery`, `GuardPolicy`, `TreeCompare`, the rules), so these tests also say whether the numbers in the
/// sample data still add up after a rule changes.
final class DemoTests: XCTestCase {
    static let now = DemoScenarios.referenceNow
    static let home = DemoScenarios.home
    static let outboard = DemoScenarios.outboardVolumeID

    func make(_ s: DemoScenario, failure: DemoFailure? = nil) -> (backend: Backend, state: DemoState) {
        DemoBackend.makeWithState(s, seconds: 0, now: Self.now, failure: failure)
    }

    func backend(_ s: DemoScenario) -> Backend { make(s).backend }

    func scans(_ b: Backend) async -> [SizeScan] { await b.measure(Catalogue.all.map(\.id)) }

    func plan(_ s: DemoScenario) async -> StoragePlan {
        let b = backend(s)
        return StoragePlanBuilder.build(recipes: Catalogue.all, scans: await scans(b), prefs: DemoScenarios.preferences(for: s), policy: .release,
                                        macOS: DemoScenarios.macOS, now: Self.now)
    }

    func card(_ s: DemoScenario) async -> StoragePlanCard {
        let b = backend(s)
        let p = StoragePlanBuilder.build(recipes: Catalogue.all, scans: await scans(b), prefs: DemoScenarios.preferences(for: s), policy: .release,
                                         macOS: DemoScenarios.macOS, now: Self.now)
        return StoragePlanText.card(from: p, relocations: b.relocations(), prefs: DemoScenarios.preferences(for: s), isSample: true)
    }

    func clean(_ text: String, _ what: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(BannedPhrases.hits(in: text), [], "banned phrase in \(what): \(text)", file: file, line: line)
    }

    /// A move of `recipeID` onto the Outboard drive with every box ticked, run to its end.
    func run(_ s: DemoScenario, _ recipeID: RecipeID, failure: DemoFailure? = nil) async throws
        -> (backend: Backend, state: DemoState, plan: MovePlan, outcome: MoveOutcome, progress: [MoveProgress]) {
        let (b, state) = make(s, failure: failure)
        _ = await scans(b)
        let recipe = try XCTUnwrap(Catalogue.recipe(recipeID))
        let report = await b.eligibility(Self.outboard, recipeID)
        let result = await b.plan(recipeID, Self.outboard, DemoScenarios.tickedConsent(recipe: recipe, report: report))
        let plan = try XCTUnwrap(result.plan, "no plan: \(result.refusal ?? "-")")
        let box = ProgressBox()
        let outcome = await b.move(plan) { box.add($0) }
        return (b, state, plan, outcome, box.items)
    }

    func moveIDs(_ log: [JournalEntry]) -> [String] {
        var seen: [String] = []
        for e in log where e.id != "app" && !seen.contains(e.id) { seen.append(e.id) }
        return seen
    }

    // MARK: the worlds

    func testEveryScenarioIsWellFormed() async {
        for s in DemoScenario.allCases {
            let (b, state) = make(s)
            let volumes = await b.volumes()
            XCTAssertTrue(volumes.contains { $0.isInternal == .yes }, "\(s): the Mac's own disk is listed")
            XCTAssertEqual(Set(volumes.map(\.id)).count, volumes.count, "\(s): duplicate volume id")
            XCTAssertTrue(b.isDemo, "\(s)")
            let log = b.loadLog()
            XCTAssertTrue(zip(log, log.dropFirst()).allSatisfy { $0.ts <= $1.ts }, "\(s): timestamps go forward")
            XCTAssertTrue(log.allSatisfy { $0.ts <= Self.now }, "\(s): history ends before now")
            // Every line is a line the real journal encoding can write and read back.
            let text = log.map(ActivityLog.encode).joined(separator: "\n")
            let back = ActivityLog.decodeAll(text)
            XCTAssertEqual(back.skippedLines, 0, "\(s)")
            XCTAssertEqual(back.entries, log, "\(s): the journal round-trips")
            // Paths in the world are the example user's.
            for p in state.tree.nodes.keys {
                XCTAssertTrue(p.hasPrefix(Self.home + "/") || p.hasPrefix("/Volumes/"), "\(s): stray path \(p)")
            }
        }
    }

    func testScenariosAreDeterministic() async {
        for s in DemoScenario.allCases {
            let a = backend(s), b = backend(s)
            let sa = await scans(a), sb = await scans(b)
            XCTAssertEqual(sa, sb, "\(s)")
            let va = await a.volumes(), vb = await b.volumes()
            XCTAssertEqual(va, vb, "\(s)")
            XCTAssertEqual(a.loadLog(), b.loadLog(), "\(s)")
            XCTAssertEqual(a.relocations(), b.relocations(), "\(s)")
            let ra = await a.reconcile(.launch), rb = await b.reconcile(.launch)
            XCTAssertEqual(ra, rb, "\(s)")
            XCTAssertEqual(DemoScenarios.focus(for: s), DemoScenarios.focus(for: s))
        }
    }

    func testTheDemoReadsNoClockAndMakesNoSecrets() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OutboardCore/Demo")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
        XCTAssertGreaterThanOrEqual(files.count, 6)
        // Built from pieces so this file carries no key-shaped literal either.
        let forbidden = ["Date" + "()", "Date" + ".now", "Date" + ".init(", "CFAbsolute" + "Time", "DispatchTime" + ".now", "ProcessInfo",
                         "arc4" + "random", ".random(", "UUID" + "()", "SystemRandom", "getenv", "clock" + "(", "gettimeofday", "time(nil)"]
        let secretShapes = ["gh" + "p_", "gh" + "o_", "sk-" + "ant", "sk" + "_live", "AK" + "IA", "-----" + "BEGIN", "xox" + "b-", "AIza" + "Sy"]
        for f in files {
            let text = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
            for token in forbidden { XCTAssertFalse(text.contains(token), "\(f) uses \(token)") }
            for token in secretShapes { XCTAssertFalse(text.contains(token), "\(f) has something shaped like a secret: \(token)") }
            // No long unbroken alphanumeric run in a string literal (a token would be one).
            for line in text.split(separator: "\n") where line.contains("\"") && !line.contains("//") {
                var run = 0
                for ch in line {
                    run = (ch.isLetter || ch.isNumber) && ch.isASCII ? run + 1 : 0
                    XCTAssertLessThan(run, 40, "\(f): a long run in: \(line)")
                }
            }
        }
    }

    // MARK: the plan and the card

    func testThePlanScenarioAddsUpTo87() async throws {
        let p = await plan(.plan)
        XCTAssertEqual(p.movable.map(\.recipeID), ["xcode-deriveddata", "ollama-models", "ios-device-backups"])
        XCTAssertEqual(p.headlineBytes, 41_230_000_000 + 30_110_000_000 + 15_640_000_000)
        let npm = try XCTUnwrap(p.items.first { $0.recipeID == "npm-cache" })
        XCTAssertEqual(npm.status, .belowThreshold)
        let c = await card(.plan)
        XCTAssertEqual(c.variant, .plan)
        XCTAssertEqual(c.rows.map(\.text), ["41 GB", "30 GB", "16 GB"])
        XCTAssertTrue(c.headline.contains("87 GB"), c.headline)
        XCTAssertTrue(c.isShareable)
        XCTAssertTrue(c.isSample)
        XCTAssertEqual(c.rows.map(\.fraction).first, 1.0)
        clean(c.headline, "card headline")
        clean(StoragePlanText.copyText(c), "card text")
    }

    func testTheGuidedLineIsMutedAndNotInTheTotal() async throws {
        let plain = await card(.plan), guided = await card(.planGuided)
        XCTAssertEqual(guided.variant, .planWithGuided)
        XCTAssertEqual(guided.totalBytes, plain.totalBytes)
        XCTAssertEqual(guided.headline, plain.headline)
        XCTAssertEqual(guided.guidedLines.count, 1)
        XCTAssertTrue(guided.guidedLines[0].contains("Photos library"), guided.guidedLines[0])
        XCTAssertTrue(guided.guidedLines[0].contains("212 GB"), guided.guidedLines[0])
        let p = await plan(.planGuided)
        XCTAssertEqual(p.guided.first?.recipeID, "photos-library")
        XCTAssertEqual(p.guided.first?.allocatedBytes, 212_000_000_000)
    }

    func testThePartlyMeasuredScenarioSaysWhy() async throws {
        let b = backend(.partlyMeasured)
        XCTAssertEqual(b.fullDiskAccess(), .no)
        let measured = await scans(b)
        let ios = try XCTUnwrap(measured.first { $0.recipeID == "ios-device-backups" })
        XCTAssertEqual(ios.state, .notMeasured)
        XCTAssertEqual(ios.reason, .needsFullDiskAccess)
        XCTAssertEqual(ios.errnoCode, 1)
        XCTAssertEqual(ios.fingerprint.logicalBytes, 0)
        let c = await card(.partlyMeasured)
        XCTAssertEqual(c.variant, .partlyMeasured)
        XCTAssertTrue(c.rows.contains { $0.text == "not measured" })
        XCTAssertEqual(c.rows.filter { $0.note != nil }.count, 1)
    }

    func testTheSmallAndEmptyScenarios() async throws {
        let small = await card(.small)
        let smallPlan = await plan(.small)
        XCTAssertEqual(small.variant, .small)
        XCTAssertFalse(small.isShareable)
        XCTAssertLessThan(smallPlan.headlineBytes, Limits.smallPlanBytes)
        XCTAssertTrue(small.headline.contains("Nothing big to move"), small.headline)
        XCTAssertEqual(smallPlan.movable.first?.name, "Xcode build data")
        let none = await card(.nothingFound)
        let nonePlan = await plan(.nothingFound)
        XCTAssertEqual(none.variant, .nothingFound)
        XCTAssertFalse(none.isShareable)
        XCTAssertEqual(nonePlan.movable.count, 0)
        // No folder over the threshold anywhere.
        let noneScans = await scans(backend(.nothingFound))
        XCTAssertTrue(noneScans.allSatisfy { $0.allocatedBytes < Limits.minOfferBytes })
        // First run: nothing measured, the education cards come first.
        let firstRunScans = await scans(backend(.firstRun))
        XCTAssertEqual(firstRunScans, [])
        XCTAssertFalse(DemoScenarios.preferences(for: .firstRun).hasSeenFirstRun)
        XCTAssertTrue(DemoScenarios.preferences(for: .plan).hasSeenFirstRun)
        XCTAssertTrue(DemoScenarios.preferences(for: .plan).showUnverifiedMoves)
    }

    func testFreshHasNoDriveButTheSamePlan() async {
        let fresh = backend(.fresh)
        let external = await fresh.volumes().filter { $0.isInternal != .yes }
        XCTAssertEqual(external, [])
        let freshPlan = await plan(.fresh), plainPlan = await plan(.plan)
        XCTAssertEqual(freshPlan.headlineBytes, plainPlan.headlineBytes)
        XCTAssertNil(DemoScenarios.preferences(for: .fresh).preferredVolumeUUID)
    }

    // MARK: the drives

    func testTheDrivesScenarioHasOneEligibleDriveAndEightRefusals() async throws {
        let b = backend(.drives)
        let volumes = await b.volumes()
        XCTAssertEqual(volumes.count, 2 + DemoScenarios.refusedDrives.count)
        let mine = try XCTUnwrap(volumes.first { $0.id == Self.outboard })
        let report = await b.eligibility(Self.outboard, nil)
        XCTAssertTrue(report.isAllowed, report.refusals.map(\.message).joined())
        XCTAssertTrue(report.acks.isEmpty)
        XCTAssertTrue(report.verdicts.contains { $0.rule == .e17 && $0.outcome == .info })
        XCTAssertTrue(mine.hasOutboardMarker)
        let ios = await b.eligibility(Self.outboard, "ios-device-backups")
        XCTAssertTrue(ios.isAllowed)
        XCTAssertEqual(ios.acks, [], "an encrypted drive needs no acknowledgement")
        for (drive, rule) in DemoScenarios.refusedDrives {
            for recipe in ["xcode-deriveddata", "ios-device-backups", nil] as [RecipeID?] {
                let r = await b.eligibility(drive.id, recipe)
                XCTAssertFalse(r.isAllowed, "\(drive.name) for \(recipe ?? "any")")
                XCTAssertEqual(r.firstRefusal?.rule, rule, "\(drive.name) for \(recipe ?? "any")")
                if let m = r.firstRefusal?.message { clean(m, "\(drive.name) refusal") }
            }
        }
        let own = await b.eligibility(DemoScenarios.internalVolumeID, nil)
        XCTAssertEqual(own.firstRefusal?.rule, .e3)
        // A drive that is not there is a freshness refusal, not a crash.
        let gone = await b.eligibility("not-a-volume", "xcode-deriveddata")
        XCTAssertFalse(gone.isAllowed)
        XCTAssertEqual(gone.refusals.first?.rule, .e18)
    }

    func testAnUnencryptedDriveAsksForTheEncryptionTickOnlyForBackups() async throws {
        let b = backend(.consentIOSBackups)
        let ios = await b.eligibility(Self.outboard, "ios-device-backups")
        XCTAssertEqual(ios.acks.map(\.rule), [.e16])
        XCTAssertEqual(ios.acks.first?.ackID, "ack-e16")
        let xcode = await b.eligibility(Self.outboard, "xcode-deriveddata")
        XCTAssertEqual(xcode.acks, [])
        // Without the tick there is no plan; with it there is, and the plan records it.
        let recipe = try XCTUnwrap(Catalogue.recipe("ios-device-backups"))
        _ = await scans(b)
        let consent = DemoScenarios.tickedConsent(recipe: recipe, report: ios)
        XCTAssertEqual(consent.ackIDs, ["ack-e16"])
        let withoutAck = await b.plan("ios-device-backups", Self.outboard, ConsentRecord(recipeVersion: recipe.version, tickedIDs: consent.tickedIDs))
        XCTAssertNil(withoutAck.plan)
        XCTAssertNotNil(withoutAck.refusal)
        let planned = await b.plan("ios-device-backups", Self.outboard, consent)
        XCTAssertEqual(planned.plan?.consent.ackIDs, ["ack-e16"])
    }

    func testUseThisDriveWritesOnlyTheMarkerAndRefusesTheOthers() async {
        let (b, state) = make(.drives)
        let before = state.tree.nodes.count
        let ok = await b.useDrive(Self.outboard)
        XCTAssertTrue(ok.ok)
        XCTAssertEqual(ok.facts?.hasOutboardMarker, true)
        clean(ok.message, "use drive")
        let refused = await b.useDrive(DemoScenarios.travelVolumeID)
        XCTAssertFalse(refused.ok)
        XCTAssertTrue(refused.message.contains("exFAT"), refused.message)
        let missing = await b.useDrive("not-a-volume")
        XCTAssertFalse(missing.ok)
        XCTAssertEqual(state.tree.nodes.count, before, "nothing on the Mac is touched")
        XCTAssertEqual(b.loadLog().filter { $0.step == MoveStep.useDrive.rawValue }.count, 2, "one intent and one result")
        XCTAssertTrue(b.loadLog().allSatisfy { $0.id == "app" })
    }

    // MARK: the consent sheets

    func testEveryConsentScenarioPlansItsRecipe() async throws {
        let scenarios = DemoScenario.allCases.filter { $0.consentRecipeID != nil }
        XCTAssertEqual(scenarios.count, 7)
        XCTAssertEqual(Set(scenarios.compactMap(\.consentRecipeID)), Set(Catalogue.automated.map(\.id)))
        for s in scenarios {
            let id = try XCTUnwrap(s.consentRecipeID)
            let b = backend(s)
            let focus = DemoScenarios.focus(for: s)
            XCTAssertEqual(focus.recipeID, id)
            XCTAssertEqual(focus.volumeID, Self.outboard)
            let measured = await scans(b)
            let scan = try XCTUnwrap(measured.first { $0.recipeID == id })
            XCTAssertEqual(scan.state, .measured, "\(s)")
            XCTAssertGreaterThanOrEqual(scan.allocatedBytes, Limits.minOfferBytes, "\(s)")
            let recipe = try XCTUnwrap(Catalogue.recipe(id))
            let report = await b.eligibility(Self.outboard, id)
            XCTAssertTrue(report.isAllowed, "\(s): \(report.refusals.map(\.message))")
            let result = await b.plan(id, Self.outboard, DemoScenarios.tickedConsent(recipe: recipe, report: report))
            let plan = try XCTUnwrap(result.plan, "\(s): \(result.refusal ?? "")")
            XCTAssertEqual(plan.recipeID, id)
            XCTAssertEqual(plan.logicalBytes, scan.fingerprint.logicalBytes)
            XCTAssertEqual(plan.destination.volumeUUID, Self.outboard)
            XCTAssertEqual(plan.destination.relativePath.hasPrefix("Outboard/\(id)/"), true)
            // Unticked, there is no plan and the reason is in plain words.
            let bare = await b.plan(id, Self.outboard, ConsentRecord(recipeVersion: recipe.version, tickedIDs: []))
            XCTAssertNil(bare.plan, "\(s)")
            clean(bare.refusal ?? "", "\(s) refusal")
        }
    }

    func testTheBlockerRowsComeFromTheRealRunningCheck() {
        let xcode = backend(.consentXcodeDerivedData).blockers("xcode-deriveddata")
        XCTAssertFalse(xcode.isEmpty)
        XCTAssertTrue(xcode.contains { $0.state == .running }, "Xcode is running in its consent scenario")
        XCTAssertFalse(xcode.allSatisfy(\.isClear))
        for s in DemoScenario.allCases.filter({ $0.consentRecipeID != nil && $0 != .consentXcodeDerivedData }) {
            let rows = backend(s).blockers(s.consentRecipeID ?? "")
            XCTAssertTrue(rows.allSatisfy(\.isClear), "\(s): nothing is running")
        }
        XCTAssertEqual(backend(.plan).blockers("not-a-recipe"), [])
    }

    func testTheGuidedScenarioMeasuresButMovesNothing() async throws {
        let b = backend(.guided)
        XCTAssertEqual(DemoScenarios.focus(for: .guided).recipeID, "photos-library")
        let measured = await scans(b)
        let scan = try XCTUnwrap(measured.first { $0.recipeID == "photos-library" })
        XCTAssertEqual(scan.allocatedBytes, 212_000_000_000)
        let recipe = try XCTUnwrap(Catalogue.recipe("photos-library"))
        let report = await b.eligibility(Self.outboard, "photos-library")
        XCTAssertTrue(report.isAllowed)
        let result = await b.plan("photos-library", Self.outboard, DemoScenarios.tickedConsent(recipe: recipe, report: report))
        XCTAssertNil(result.plan, "a guided card is never planned as a move")
        b.recordGuideViewed("photos-library")
        let lines = b.loadLog()
        XCTAssertEqual(lines.map(\.step), [MoveStep.guideViewed.rawValue, MoveStep.guideViewed.rawValue])
        XCTAssertEqual(lines.map(\.phase), [.intent, .result])
        XCTAssertTrue(b.relocations().isEmpty)
    }

    // MARK: a move

    func testAMoveForEveryAutomatedRecipeEndsSwappedWithTheOriginalKept() async throws {
        for s in DemoScenario.allCases where s.consentRecipeID != nil {
            let id = try XCTUnwrap(s.consentRecipeID)
            // Xcode is "running" in its own consent scenario: that is the blocker test; here the same world with the app closed.
            let world = s == .consentXcodeDerivedData ? DemoScenario.consentXcodeArchives : s
            let target: RecipeID = s == .consentXcodeDerivedData ? "xcode-deriveddata" : id
            let r = try await run(world, target)
            XCTAssertTrue(r.outcome.ok, "\(s): \(r.outcome.message)")
            XCTAssertEqual(r.outcome.state, .swapped, "\(s)")
            XCTAssertEqual(r.outcome.preflight?.passedCount, 14)
            XCTAssertEqual(r.outcome.verification?.filesCompared, r.plan.sourceFingerprint.files)
            XCTAssertEqual(r.outcome.verification?.differences, 0)
            clean(r.outcome.message, "\(s) outcome")
            // The Mac: the original is kept under its new name; the app is pointed at the copy.
            XCTAssertTrue(r.state.tree.has(r.plan.beforeMovePath), "\(s): the original is kept")
            XCTAssertTrue(r.state.tree.node(r.plan.beforeMovePath)?.stamp.isSameObject(as: r.plan.sourceStamp) == true, "\(s): it is the same folder")
            XCTAssertEqual(r.state.tree.node(r.plan.destination.finalPath)?.fingerprint, r.plan.sourceFingerprint, "\(s): the copy is complete")
            XCTAssertTrue(r.state.tree.has(r.plan.sentinelPath), "\(s): the sentinel is beside the copy")
            switch r.plan.redirect {
            case .symbolicLink(let link, let target):
                XCTAssertEqual(r.state.tree.node(link)?.kind, .link, "\(s)")
                XCTAssertEqual(r.state.tree.node(link)?.target, target, "\(s)")
            case .defaults(let domain, let writes, _, _):
                for w in writes { XCTAssertEqual(r.state.defaultsStore[domain]?[w.key], w.value, "\(s)") }
                XCTAssertFalse(r.state.tree.has(r.plan.macPath), "\(s): the old folder is renamed, not recreated")
            }
            // The record, folded by the real code.
            let record = try XCTUnwrap(r.backend.relocations().first { $0.id == r.plan.id })
            XCTAssertEqual(record.state, .swapped, "\(s)")
            XCTAssertEqual(record.safetyCopy, .kept, "\(s)")
            XCTAssertTrue(record.canConfirm && record.canRollBack, "\(s)")
            XCTAssertEqual(record.logicalBytes, r.plan.logicalBytes, "\(s)")
            XCTAssertEqual(record.fileCount, r.plan.sourceFingerprint.files, "\(s)")
            XCTAssertEqual(record.volume.uuid, Self.outboard)
            // The scan now says the folder was redirected, and the plan stops counting it.
            let rescan = await r.backend.measure([target])
            let after = try XCTUnwrap(rescan.first)
            XCTAssertEqual(after.reason, .alreadyRedirected, "\(s)")
        }
    }

    func testProgressHasNoEstimateAndNeverGoesBackwards() async throws {
        let r = try await run(.consentXcodeArchives, "xcode-deriveddata")
        XCTAssertGreaterThanOrEqual(r.progress.count, 12)
        XCTAssertEqual(r.progress.first?.phase, .preflight)
        XCTAssertEqual(r.progress.last?.phase, .finishing)
        let order: [ProgressPhase] = [.preflight, .copying, .verifying, .swapping, .finishing]
        var lastIndex = 0, lastFraction = 0.0, lastBytes: UInt64 = 0
        for p in r.progress {
            XCTAssertEqual(p.moveID, r.plan.id)
            let i = try XCTUnwrap(order.firstIndex(of: p.phase))
            XCTAssertGreaterThanOrEqual(i, lastIndex)
            if i > lastIndex { lastFraction = 0 }
            lastIndex = i
            XCTAssertGreaterThanOrEqual(p.fraction, lastFraction)
            lastFraction = p.fraction
            if p.phase == .copying {
                XCTAssertGreaterThanOrEqual(p.bytesDone, lastBytes)
                lastBytes = p.bytesDone
                XCTAssertLessThanOrEqual(p.bytesDone, p.bytesTotal)
            }
            XCTAssertEqual(p.bytesTotal, r.plan.logicalBytes)
        }
        XCTAssertEqual(r.progress.filter { $0.phase == .copying }.map(\.fraction).max(), 1)
        XCTAssertEqual(r.progress.filter { $0.phase == .verifying }.map(\.fraction).max(), 1)
    }

    func testTheJournalOfAMoveIsInOrderAndEveryTransitionIsLegal() async throws {
        let r = try await run(.consentXcodeArchives, "xcode-deriveddata")
        _ = await r.backend.confirm(r.plan.id)
        assertJournalInvariants(r.backend.loadLog(), "move and confirm")
        let steps = r.backend.loadLog().filter { $0.phase == .intent }.map(\.step)
        XCTAssertEqual(steps, ["begin", "preflight", "copy", "verify", "publish", "setAside", "redirect", "confirm", "trash"])
    }

    func testEveryScenariosJournalKeepsTheRules() {
        for s in DemoScenario.allCases { assertJournalInvariants(backend(s).loadLog(), "\(s)") }
    }

    func assertJournalInvariants(_ log: [JournalEntry], _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        for id in moveIDs(log) {
            let lines = log.filter { $0.id == id }
            XCTAssertEqual(lines.map(\.seq), Array(1...lines.count), "\(what) \(id): seq", file: file, line: line)
            var current: MoveState?
            for e in lines {
                guard let next = e.state else { continue }
                if let c = current, c != next {
                    XCTAssertTrue(MoveMachine.canTransition(c, to: next), "\(what) \(id): \(c) -> \(next) at \(e.step)", file: file, line: line)
                }
                current = next
            }
            // A result is preceded by its intent, except the lines that are only a result.
            let resultOnly: Set<String> = [MoveStep.swapped.rawValue, MoveStep.abort.rawValue, MoveStep.begin.rawValue]
            for (i, e) in lines.enumerated() where e.phase == .result && !resultOnly.contains(e.step) {
                XCTAssertTrue(lines[..<i].contains { $0.phase == .intent && $0.step == e.step }, "\(what) \(id): \(e.step) result without intent", file: file, line: line)
            }
            // The original is set aside only after the compare passed; it goes to the Trash only after the person confirmed.
            if let aside = lines.firstIndex(where: { $0.step == MoveStep.setAside.rawValue && $0.phase == .intent }) {
                let verified = lines.firstIndex { $0.step == MoveStep.verify.rawValue && $0.phase == .result && $0.status == .ok }
                XCTAssertNotNil(verified, "\(what) \(id): set aside without a compare", file: file, line: line)
                if let verified { XCTAssertLessThan(verified, aside, "\(what) \(id)", file: file, line: line) }
            }
            if let trash = lines.firstIndex(where: { $0.step == MoveStep.trash.rawValue && $0.phase == .intent }), lines.contains(where: { $0.state == .originalTrashed }) {
                let confirmed = lines.firstIndex { $0.step == MoveStep.confirm.rawValue && $0.phase == .result && $0.status == .ok }
                XCTAssertNotNil(confirmed, "\(what) \(id): trash without a confirm", file: file, line: line)
                if let confirmed { XCTAssertLessThan(confirmed, trash, "\(what) \(id)", file: file, line: line) }
            }
        }
        // Journal text is what the screen shows: no file contents, and it passes the honest-copy check.
        for e in log { clean(e.note ?? "", "journal note") }
    }

    // MARK: confirm, roll back, return, forget, cancel

    func testConfirmMovesTheOriginalToTheTrashAfterTheConfirm() async throws {
        let r = try await run(.consentXcodeArchives, "ollama-models")
        let out = await r.backend.confirm(r.plan.id)
        XCTAssertTrue(out.ok, out.message)
        XCTAssertEqual(out.state, .originalTrashed)
        clean(out.message, "confirm")
        XCTAssertFalse(r.state.tree.has(r.plan.beforeMovePath))
        let trashed = Self.home + "/.Trash/" + "models" + Names.beforeMoveSuffix
        XCTAssertEqual(r.state.tree.node(trashed)?.fingerprint, r.plan.sourceFingerprint, "the original is in the Trash, whole")
        let record = try XCTUnwrap(r.backend.relocations().first { $0.id == r.plan.id })
        XCTAssertEqual(record.state, .originalTrashed)
        XCTAssertEqual(record.safetyCopy, .inTrash)
        XCTAssertFalse(record.canRollBack)
        XCTAssertTrue(record.canReturn)
        // Once confirmed, rolling back and confirming again are refused with a reason.
        let again = await r.backend.confirm(r.plan.id)
        XCTAssertFalse(again.ok)
        let back = await r.backend.rollback(r.plan.id)
        XCTAssertFalse(back.ok)
        clean(back.message, "refused rollback")
        let unknown = await r.backend.confirm("no-such-move")
        XCTAssertFalse(unknown.ok)
    }

    func testRollBackPutsTheOriginalBackAndKeepsTheCopyOnTheDrive() async throws {
        for (s, id) in [(DemoScenario.consentOllama, "ollama-models"), (.consentXcodeArchives, "xcode-deriveddata")] as [(DemoScenario, RecipeID)] {
            let r = try await run(s, id)
            let out = await r.backend.rollback(r.plan.id)
            XCTAssertTrue(out.ok, "\(id): \(out.message)")
            XCTAssertEqual(out.state, .rolledBack)
            clean(out.message, "rollback")
            XCTAssertTrue(r.state.tree.node(r.plan.macPath)?.stamp.isSameObject(as: r.plan.sourceStamp) == true, "\(id): the original is back, the same folder")
            XCTAssertFalse(r.state.tree.has(r.plan.beforeMovePath))
            XCTAssertTrue(r.state.tree.has(r.plan.destination.finalPath), "\(id): the copy stays on the drive")
            if case .symbolicLink = r.plan.redirect {
                XCTAssertEqual(r.state.tree.node(r.state.parkedLink(r.plan.id))?.kind, .link, "\(id): the link is kept in Parked/")
            }
            if case .defaults(let domain, _, _, let revert) = r.plan.redirect {
                for w in revert { XCTAssertEqual(r.state.defaultsStore[domain]?[w.key], w.value) }
            }
            let record = try XCTUnwrap(r.backend.relocations().first { $0.id == r.plan.id })
            XCTAssertEqual(record.state, .rolledBack)
            XCTAssertTrue(r.backend.leftovers().contains { $0.moveID == r.plan.id && $0.kind == .rolledBackCopy }, "\(id): the copy is labelled")
            assertJournalInvariants(r.backend.loadLog(), "rollback \(id)")
            // The folder is measurable again, and the plan counts it again.
            let rescan = await r.backend.measure([id])
            let again = try XCTUnwrap(rescan.first)
            XCTAssertEqual(again.state, .measured)
        }
    }

    func testRollBackIsRefusedWhileTheAppRuns() async throws {
        let r = try await run(.consentXcodeArchives, "xcode-deriveddata")
        r.state.locked { _ = r.state.running.insert("xcode-deriveddata") }
        let out = await r.backend.rollback(r.plan.id)
        XCTAssertFalse(out.ok)
        XCTAssertEqual(out.state, .swapped)
        XCTAssertTrue(r.state.tree.has(r.plan.beforeMovePath), "nothing moved")
        clean(out.message, "refused rollback")
    }

    func testReturnToMacBringsAVerifiedCopyBackAndKeepsTheDriveCopy() async throws {
        for (s, id) in [(DemoScenario.consentOllama, "ollama-models"), (.consentXcodeArchives, "xcode-deriveddata")] as [(DemoScenario, RecipeID)] {
            let r = try await run(s, id)
            _ = await r.backend.confirm(r.plan.id)
            let box = ProgressBox()
            let out = await r.backend.returnToMac(r.plan.id) { box.add($0) }
            XCTAssertTrue(out.ok, "\(id): \(out.message)")
            XCTAssertEqual(out.state, .returned)
            clean(out.message, "return")
            XCTAssertFalse(box.items.isEmpty)
            XCTAssertEqual(r.state.tree.node(r.plan.macPath)?.fingerprint, r.plan.sourceFingerprint, "\(id): back on the Mac, whole")
            XCTAssertEqual(r.state.tree.node(r.plan.macPath)?.kind, .directory)
            XCTAssertTrue(r.state.tree.has(r.plan.destination.finalPath), "\(id): the drive copy stays until it is trashed")
            let records = r.backend.relocations()
            XCTAssertEqual(records.first { $0.id == r.plan.id }?.state, .returned)
            XCTAssertTrue(records.contains { $0.direction == .returnToMac }, "the way back is a record of its own")
            XCTAssertTrue(records.filter { $0.direction == .toDrive }.allSatisfy { !$0.state.isActive })
            assertJournalInvariants(r.backend.loadLog(), "return \(id)")
            let snap = await r.backend.reconcile(.manual)
            XCTAssertTrue(snap.relocations.isEmpty, "nothing is watched any more")
        }
    }

    func testReturnToMacIsRefusedBeforeConfirmAndWithoutTheDrive() async throws {
        let r = try await run(.consentXcodeArchives, "xcode-deriveddata")
        let early = await r.backend.returnToMac(r.plan.id) { _ in }
        XCTAssertFalse(early.ok)
        clean(early.message, "early return")
        _ = await r.backend.confirm(r.plan.id)
        _ = await r.backend.reconcile(.willUnmount)
        let away = await r.backend.returnToMac(r.plan.id) { _ in }
        XCTAssertFalse(away.ok)
        XCTAssertTrue(away.message.contains("isn't connected"), away.message)
    }

    func testForgetSetsTheNoteAsideAndNeverDeletes() async throws {
        let (b, state) = make(.forget)
        let record = try XCTUnwrap(b.relocations().first)
        let macPath = state.absolute(record.macPath)
        XCTAssertEqual(state.tree.node(macPath)?.kind, .note)
        let before = state.tree.nodes.count
        let out = await b.forget(record.id)
        XCTAssertTrue(out.ok, out.message)
        XCTAssertEqual(out.state, .forgotten)
        XCTAssertTrue(out.message.contains("can't get this data back without the drive"), out.message)
        XCTAssertFalse(state.tree.has(macPath), "the app can make its own default")
        XCTAssertEqual(state.tree.nodes.count, before, "set aside, not deleted")
        XCTAssertTrue(state.tree.nodes.keys.contains { $0.contains("/Parked/") })
        XCTAssertEqual(b.relocations().first?.state, .forgotten)
        let snap = await b.reconcile(.manual)
        XCTAssertTrue(snap.relocations.isEmpty)
        // A move whose original is still on the Mac is rolled back, not forgotten.
        let r = try await run(.consentXcodeArchives, "ollama-models")
        let refused = await r.backend.forget(r.plan.id)
        XCTAssertFalse(refused.ok)
        XCTAssertTrue(refused.message.contains("Roll back"), refused.message)
    }

    func testCancellingAFrozenMoveStopsItAndChangesNothingOnTheMac() async throws {
        for (s, phase, fraction) in [(DemoScenario.copying, ProgressPhase.copying, 0.41), (.verifying, .verifying, 0.62)] {
            let (b, state) = make(s)
            _ = await scans(b)
            let recipe = try XCTUnwrap(Catalogue.recipe("xcode-deriveddata"))
            let report = await b.eligibility(Self.outboard, recipe.id)
            let planned = await b.plan(recipe.id, Self.outboard, DemoScenarios.tickedConsent(recipe: recipe, report: report))
            let plan = try XCTUnwrap(planned.plan)
            XCTAssertEqual(plan.id, DemoScenarios.focus(for: s).moveID, "\(s): the screens can name the move")
            let box = ProgressBox()
            let task = Task { await b.move(plan) { box.add($0) } }
            for _ in 0..<500 where !(box.items.last.map { $0.phase == phase && $0.fraction >= fraction } ?? false) {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            let frozen = try XCTUnwrap(box.items.last)
            XCTAssertEqual(frozen.phase, phase)
            XCTAssertEqual(frozen.fraction, fraction, accuracy: 0.001, "\(s)")
            let count = box.items.count
            try? await Task.sleep(nanoseconds: 120_000_000)
            XCTAssertEqual(box.items.count, count, "\(s): frozen means no more progress")
            let expected = try XCTUnwrap(DemoScenarios.frozenProgress(for: s))
            XCTAssertEqual(expected.phase, phase)
            XCTAssertEqual(expected.fraction, fraction, accuracy: 0.001)
            XCTAssertEqual(expected.moveID, plan.id)
            task.cancel()
            let outcome = await task.value
            XCTAssertFalse(outcome.ok)
            XCTAssertEqual(outcome.abort, .userCancelled)
            XCTAssertEqual(outcome.state, .aborted)
            clean(outcome.message, "cancel")
            XCTAssertTrue(state.tree.node(plan.macPath)?.stamp.isSameObject(as: plan.sourceStamp) == true, "\(s): the original was never touched")
            XCTAssertFalse(state.tree.has(plan.beforeMovePath))
            XCTAssertEqual(b.relocations().first?.state, .aborted)
            XCTAssertTrue(b.leftovers().contains { $0.kind == .incompleteCopy }, "\(s): the half copy is labelled")
        }
        XCTAssertNil(DemoScenarios.frozenProgress(for: .plan))
    }

    // MARK: moves that stop

    func testEveryInjectedFailureStopsBeforeTheMacChanges() async throws {
        let cases: [(DemoFailure, AbortReason)] = [(.mismatch, .mismatch), (.sourceChanged, .sourceChanged), (.appLaunched, .appLaunched),
                                                    (.driveChanged, .driveChanged)]
        for (failure, reason) in cases {
            let r = try await run(.consentXcodeArchives, "ollama-models", failure: failure)
            XCTAssertFalse(r.outcome.ok, "\(failure)")
            XCTAssertEqual(r.outcome.abort, reason, "\(failure): \(r.outcome.message)")
            XCTAssertEqual(r.outcome.state, .aborted)
            clean(r.outcome.message, "\(failure)")
            XCTAssertTrue(r.state.tree.node(r.plan.macPath)?.stamp.isSameObject(as: r.plan.sourceStamp) == true, "\(failure): the original is untouched")
            XCTAssertFalse(r.state.tree.has(r.plan.beforeMovePath), "\(failure)")
            XCTAssertNotEqual(r.state.tree.node(r.plan.macPath)?.kind, .link, "\(failure): no link was made")
            let record = try XCTUnwrap(r.backend.relocations().first { $0.id == r.plan.id })
            XCTAssertEqual(record.state, .aborted, "\(failure)")
            XCTAssertEqual(record.abort, reason, "\(failure)")
            XCTAssertEqual(record.safetyCopy, .none)
            XCTAssertTrue(r.backend.leftovers().contains { $0.moveID == r.plan.id && $0.onDrive }, "\(failure): what reached the drive is labelled")
            assertJournalInvariants(r.backend.loadLog(), "\(failure)")
        }
    }

    func testAMismatchListsTheFirstDifferences() async throws {
        let r = try await run(.consentXcodeArchives, "xcode-deriveddata", failure: .mismatch)
        XCTAssertFalse(r.outcome.differences.isEmpty)
        XCTAssertLessThanOrEqual(r.outcome.differences.count, Limits.firstDifferencesListed)
        XCTAssertEqual(r.outcome.differences.first?.kind, .hashDiffers)
        XCTAssertFalse(r.outcome.differences.first?.path.contains(Self.home) ?? true, "paths are relative to the folder")
        XCTAssertNil(r.outcome.verification)
        let line = try XCTUnwrap(r.backend.loadLog().first { $0.step == "verify" && $0.phase == .result })
        XCTAssertEqual(line.status, .mismatch)
        XCTAssertTrue(line.isProblem)
        // A half copy on the drive can be moved to the Trash by the person, matched against the journal.
        let left = try XCTUnwrap(r.backend.leftovers().first { $0.kind == .incompleteCopy })
        let before = r.state.tree.nodes.count
        let out = await r.backend.trashLeftover(left.id)
        XCTAssertTrue(out.ok, out.message)
        clean(out.message, "trash leftover")
        XCTAssertTrue(out.message.contains("space comes back when that Trash is emptied"), out.message)
        XCTAssertEqual(r.state.tree.nodes.count, before, "moved, not deleted")
        XCTAssertFalse(r.backend.leftovers().contains { $0.id == left.id })
        let again = await r.backend.trashLeftover(left.id)
        XCTAssertFalse(again.ok)
    }

    func testAnAppThatMakesTheFolderInTheGapIsSetAsideAndNeverMerged() async throws {
        let r = try await run(.consentOllama, "ollama-models", failure: .foreignFolder)
        XCTAssertEqual(r.outcome.abort, .foreignFolderAppeared)
        XCTAssertTrue(r.outcome.message.contains(Names.createdWhileMovingSuffix), r.outcome.message)
        let aside = r.plan.macPath + Names.createdWhileMovingSuffix
        XCTAssertEqual(r.state.tree.node(aside)?.ours, false, "the new folder is kept, whole, under its new name")
        XCTAssertTrue(r.state.tree.node(r.plan.macPath)?.stamp.isSameObject(as: r.plan.sourceStamp) == true, "the original is back")
        XCTAssertFalse(r.state.tree.has(r.plan.beforeMovePath))
        XCTAssertEqual(r.backend.relocations().first?.state, .aborted)
        assertJournalInvariants(r.backend.loadLog(), "foreign folder")
    }

    func testAMoveWithTheAppRunningStopsAtPreflight() async throws {
        let (b, state) = make(.consentXcodeDerivedData)
        _ = await scans(b)
        let recipe = try XCTUnwrap(Catalogue.recipe("xcode-deriveddata"))
        let report = await b.eligibility(Self.outboard, recipe.id)
        let planned = await b.plan(recipe.id, Self.outboard, DemoScenarios.tickedConsent(recipe: recipe, report: report))
        let plan = try XCTUnwrap(planned.plan)
        let out = await b.move(plan) { _ in }
        XCTAssertFalse(out.ok)
        XCTAssertEqual(out.abort, .preflightFailed)
        XCTAssertEqual(out.preflight?.firstFailure?.check, .p8)
        XCTAssertTrue(out.message.contains("is running"), out.message)
        clean(out.message, "preflight")
        XCTAssertFalse(state.tree.has(plan.stagingPath), "nothing was copied")
        XCTAssertTrue(state.tree.node(plan.macPath)?.stamp.isSameObject(as: plan.sourceStamp) == true)
        XCTAssertEqual(b.relocations().first?.state, .aborted)
    }

    func testWhenTheJournalCannotBeWrittenNothingMoves() async throws {
        let (b, state) = make(.journalBlocked)
        _ = await scans(b)
        let recipe = try XCTUnwrap(Catalogue.recipe("xcode-deriveddata"))
        let report = await b.eligibility(Self.outboard, recipe.id)
        let planned = await b.plan(recipe.id, Self.outboard, DemoScenarios.tickedConsent(recipe: recipe, report: report))
        let plan = try XCTUnwrap(planned.plan)
        let box = ProgressBox()
        let out = await b.move(plan) { box.add($0) }
        XCTAssertFalse(out.ok)
        XCTAssertEqual(out.abort, .journalUnwritable)
        XCTAssertEqual(out.message, "I can't write the activity log, so nothing was changed.")
        XCTAssertEqual(out.preflight?.firstFailure?.check, .p9)
        XCTAssertTrue(box.items.isEmpty, "no progress for a move that did not start")
        XCTAssertEqual(b.loadLog(), [])
        XCTAssertTrue(state.tree.node(plan.macPath)?.stamp.isSameObject(as: plan.sourceStamp) == true)
        XCTAssertFalse(state.tree.has(plan.stagingPath))
        XCTAssertFalse(state.tree.has(plan.beforeMovePath))
        let snap = await b.reconcile(.launch)
        XCTAssertTrue(snap.banners.contains { $0.kind == .journalNotWritable && $0.text == DemoScenarios.journalBlockedMessage })
        let used = await b.useDrive(Self.outboard)
        XCTAssertFalse(used.ok)
    }

    func testOnlyOneMoveRunsAtATime() async throws {
        let (b, state) = make(.plan)
        _ = await scans(b)
        let recipe = try XCTUnwrap(Catalogue.recipe("ollama-models"))
        let report = await b.eligibility(Self.outboard, recipe.id)
        let planned = await b.plan(recipe.id, Self.outboard, DemoScenarios.tickedConsent(recipe: recipe, report: report))
        let plan = try XCTUnwrap(planned.plan)
        state.locked { state.flights = 1 }   // another move is in flight
        let out = await b.move(plan) { _ in }
        XCTAssertEqual(out.abort, .preflightFailed)
        XCTAssertEqual(out.preflight?.firstFailure?.check, .p14)
        state.locked { state.flights = 0 }
    }

    // MARK: the guard

    func healthWords(_ s: GuardSnapshot) -> [Health] { s.relocations.map(\.health) }

    func testEveryHealthyScenarioIsHealthy() async {
        for s in [DemoScenario.swapped, .confirmed, .afterMoves, .rolledBack, .recovered, .report] {
            let snap = await backend(s).reconcile(.launch)
            XCTAssertTrue(snap.isAllHealthy, "\(s): \(healthWords(snap))")
            XCTAssertEqual(snap.banners.filter { $0.kind != .backClean }, [], "\(s)")
        }
        let snap = await backend(.afterMoves).reconcile(.launch)
        XCTAssertEqual(snap.relocations.count, 3)
        XCTAssertFalse(snap.showsAttentionDot)
    }

    func testAnEjectedDriveParksANoteAndNeverLeavesALinkToNothing() async throws {
        let (b, state) = make(.driveAway)
        let volumes = await b.volumes()
        XCTAssertFalse(volumes.contains { $0.id == Self.outboard })
        let snap = await b.reconcile(.launch)
        XCTAssertEqual(snap.relocations.count, 2)
        XCTAssertEqual(Set(healthWords(snap)), [.driveAway])
        let banner = try XCTUnwrap(snap.banners.first { $0.kind == .ejected })
        XCTAssertTrue(banner.text.contains("was ejected"), banner.text)
        XCTAssertTrue(banner.text.contains("iPhone backups") && banner.text.contains("Ollama models"), banner.text)
        clean(banner.text, "ejected banner")
        XCTAssertTrue(snap.showsAttentionDot)
        for r in b.relocations() {
            let path = state.absolute(r.macPath)
            let note = try XCTUnwrap(state.tree.node(path), "something is where the folder was")
            XCTAssertEqual(note.kind, .note, "\(r.recipeName): a note, not a link to nothing")
            XCTAssertLessThanOrEqual(note.stamp.size, UInt64(Limits.placeholderMaxBytes))
            XCTAssertEqual(note.stamp.size, UInt64(PlaceholderText.body(driveName: "Outboard").utf8.count))
            XCTAssertEqual(state.tree.node(state.parkedLink(r.id))?.kind, .link, "the link is kept in Parked/ as evidence")
            XCTAssertTrue(r.isParked, "\(r.recipeName)")
            XCTAssertEqual(r.state, .originalTrashed, "the move itself is untouched")
        }
    }

    func testPluggingTheDriveBackReconnectsAfterTheQuickCheckAndTheSample() async throws {
        let (b, state) = make(.driveAway)
        let snap = await b.reconcile(.mount)
        XCTAssertTrue(snap.isAllHealthy, "\(healthWords(snap))")
        let attached = await b.volumes()
        XCTAssertEqual(attached.filter { $0.id == Self.outboard }.count, 1)
        for r in b.relocations() {
            let link = try XCTUnwrap(state.tree.node(state.absolute(r.macPath)))
            XCTAssertEqual(link.kind, .link)
            XCTAssertEqual(link.target, "/Volumes/Outboard/" + r.relativePath, "the target is recomputed from the mount point")
            XCTAssertTrue(state.tree.has(state.parkedNote(r.id)), "the note is set aside, not deleted")
            XCTAssertTrue(state.tree.has(state.parkedLink(r.id)), "the parked link stays as evidence")
        }
        let back = try XCTUnwrap(snap.banners.first { $0.kind == .backClean })
        XCTAssertEqual(back.text, "Outboard drive is back. iPhone backups and Ollama models are connected again. Checked 200 of 41,203 files: all matched.")
        assertJournalInvariants(b.loadLog(), "driveAway then mount")
        // Taking the drive away again is a second cycle: reconcile does not crash and the state stays honest.
        let again = await b.reconcile(.willUnmount)
        XCTAssertFalse(again.isAllHealthy || again.relocations.isEmpty)
    }

    func testTheDriveBackScenarioStartsReconnected() async throws {
        let (b, state) = make(.driveBack)
        let snap = await b.reconcile(.launch)
        XCTAssertTrue(snap.isAllHealthy)
        XCTAssertEqual(snap.banners.map(\.kind), [.backClean])
        XCTAssertEqual(snap.banners.first?.text, "Outboard drive is back. iPhone backups and Ollama models are connected again. Checked 200 of 41,203 files: all matched.")
        let log = b.loadLog()
        XCTAssertEqual(log.filter { $0.step == "park" && $0.phase == .result }.count, 2)
        XCTAssertEqual(log.filter { $0.step == "unpark" && $0.phase == .result }.count, 2)
        let samples = log.filter { $0.step == "unpark" && $0.phase == .result }.compactMap { $0.counts?.sampled }
        XCTAssertEqual(samples.max(), 200)
        XCTAssertEqual(samples.min(), 23, "a small folder is sampled whole")
        XCTAssertTrue(b.relocations().allSatisfy { state.tree.node(state.absolute($0.macPath))?.kind == .link })
        assertJournalInvariants(log, "driveBack")
    }

    func testRemovedWithoutEjectingIsHeldUntilCheckAndReconnect() async throws {
        let (b, state) = make(.held)
        var snap = await b.reconcile(.launch)
        XCTAssertEqual(Set(healthWords(snap)), [.held])
        XCTAssertTrue(snap.banners.contains { $0.kind == .removedUnclean })
        let text = try XCTUnwrap(snap.banners.first { $0.kind == .removedUnclean }?.text)
        XCTAssertTrue(text.contains("without ejecting"), text)
        clean(text, "unclean banner")
        let attached = await b.volumes()
        XCTAssertEqual(attached.filter { $0.id == Self.outboard }.count, 1, "the drive is back, and still nothing is connected")
        for r in b.relocations() { XCTAssertEqual(state.tree.node(state.absolute(r.macPath))?.kind, .note, "\(r.recipeName) stays disconnected") }
        // Reconcile alone changes nothing.
        let same = await b.reconcile(.mount)
        XCTAssertEqual(same, snap)
        // Check and reconnect: the first move, then the second.
        let ids = b.relocations().map(\.id)
        XCTAssertEqual(ids.count, 2)
        let box = ProgressBox()
        let first = await b.checkAndReconnect(ids[0]) { box.add($0) }
        XCTAssertTrue(first.ok, first.message)
        XCTAssertFalse(box.items.isEmpty)
        XCTAssertTrue(box.items.allSatisfy { $0.phase == .verifying && $0.moveID == ids[0] })
        XCTAssertEqual(box.items.map(\.filesDone), box.items.map(\.filesDone).sorted())
        XCTAssertEqual(first.message, "Checked 38,911 files that haven't changed since they were copied: all matched. 2,292 files have changed since and weren't compared.")
        clean(first.message, "check and reconnect")
        snap = await b.reconcile(.manual)
        XCTAssertEqual(snap.relocations.filter { $0.health == .healthy }.map(\.moveID), [ids[0]])
        XCTAssertEqual(snap.relocations.filter { $0.health == .held }.map(\.moveID), [ids[1]])
        let second = await b.checkAndReconnect(ids[1]) { _ in }
        XCTAssertTrue(second.ok, second.message)
        snap = await b.reconcile(.manual)
        XCTAssertTrue(snap.isAllHealthy)
        for r in b.relocations() { XCTAssertEqual(state.tree.node(state.absolute(r.macPath))?.target, "/Volumes/Outboard/" + r.relativePath) }
        XCTAssertEqual(b.loadLog().filter { $0.step == "checkAndReconnect" }.count, 4, "an intent and a result for each")
        assertJournalInvariants(b.loadLog(), "held")
        // Nothing is waiting any more.
        let nothing = await b.checkAndReconnect(ids[0]) { _ in }
        XCTAssertFalse(nothing.ok)
    }

    func testSomethingNewWhereTheFolderWasIsNeverTouchedUntilThePersonChooses() async throws {
        let (b, state) = make(.conflict)
        var snap = await b.reconcile(.launch)
        XCTAssertEqual(healthWords(snap), [.conflict])
        XCTAssertTrue(snap.banners.contains { $0.kind == .conflict })
        let r = try XCTUnwrap(b.relocations().first)
        let path = state.absolute(r.macPath)
        let foreign = try XCTUnwrap(state.tree.node(path))
        XCTAssertEqual(foreign.kind, .directory)
        XCTAssertFalse(foreign.ours)
        XCTAssertEqual(foreign.fingerprint.logicalBytes, 1_200_000_000)
        // A pass of the guard, however many, leaves it exactly as it is.
        for trigger in [ReconcileTrigger.mount, .timer, .wake, .manual] { snap = await b.reconcile(trigger) }
        XCTAssertEqual(state.tree.node(path), foreign)
        XCTAssertEqual(healthWords(snap), [.conflict])
        let out = await b.setAsideAndReconnect(r.id)
        XCTAssertTrue(out.ok, out.message)
        clean(out.message, "set aside")
        let aside = path + Names.whileAwayInfix + "2026-10-03"
        XCTAssertEqual(state.tree.node(aside), foreign, "kept whole under its new name, never merged or deleted")
        XCTAssertEqual(state.tree.node(path)?.kind, .link)
        snap = await b.reconcile(.manual)
        XCTAssertTrue(snap.isAllHealthy, "\(healthWords(snap))")
        assertJournalInvariants(b.loadLog(), "conflict")
        let none = await b.setAsideAndReconnect(r.id)
        XCTAssertFalse(none.ok)
    }

    // MARK: recovery

    func testARecoveredMoveHasItsOriginalBack() async throws {
        let (b, state) = make(.recovered)
        let record = try XCTUnwrap(b.relocations().first)
        XCTAssertEqual(record.state, .aborted)
        XCTAssertEqual(record.abort, .interrupted)
        XCTAssertEqual(record.safetyCopy, .none)
        let plan = try XCTUnwrap(state.plans[record.id])
        XCTAssertTrue(state.tree.node(plan.macPath)?.stamp.isSameObject(as: plan.sourceStamp) == true, "the original is back where it was")
        XCTAssertFalse(state.tree.has(plan.beforeMovePath))
        let note = try XCTUnwrap(b.loadLog().last { $0.step == "recover" && $0.phase == .result }?.note)
        XCTAssertTrue(note.contains("Restored your original"), note)
        XCTAssertTrue(note.contains("after an interruption"), note)
        clean(note, "recovery message")
        XCTAssertEqual(DemoScenarios.focus(for: .recovered).moveID, record.id)
        // What the copy left on the drive is labelled, never deleted.
        XCTAssertTrue(b.leftovers().contains { $0.moveID == record.id })
        assertJournalInvariants(b.loadLog(), "recovered")
    }

    func testTwoOriginalsStopRecoveryWhichShowsTheFactsAndTouchesNothing() async throws {
        let (b, state) = make(.needsAttention)
        let record = try XCTUnwrap(b.relocations().first)
        let plan = try XCTUnwrap(state.plans[record.id])
        XCTAssertTrue(state.tree.has(plan.macPath) && state.tree.has(plan.beforeMovePath), "both folders are still there")
        XCTAssertEqual(state.tree.node(plan.macPath)?.stamp, state.tree.node(plan.beforeMovePath)?.stamp)
        XCTAssertFalse(record.state.isTerminal, "the move is not closed: the person decides")
        let line = try XCTUnwrap(b.loadLog().last { $0.step == "recover" && $0.phase == .result })
        XCTAssertEqual(line.status, .refused)
        XCTAssertTrue(line.isProblem)
        clean(line.note ?? "", "needs attention")
        XCTAssertEqual(DemoScenarios.focus(for: .needsAttention).moveID, record.id)
    }

    // MARK: the numbers

    func testTheAfterMovesCardAddsUp() async throws {
        let (b, state) = make(.afterMoves)
        let records = b.relocations()
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records.map(\.state), [.swapped, .originalTrashed, .originalTrashed], "newest first")
        XCTAssertEqual(records.map(\.logicalBytes), [15_640_000_000, 30_110_000_000, 41_230_000_000])
        let c = await card(.afterMoves)
        XCTAssertEqual(c.variant, .afterMoves)
        XCTAssertTrue(c.headline.hasPrefix("Moved "), c.headline)
        XCTAssertTrue(c.headline.contains("Outboard drive"), c.headline)
        XCTAssertTrue(c.measuredLine.contains("Safety copies still on this Mac"), c.measuredLine)
        clean(c.headline + c.measuredLine, "after moves")
        // One folder still has its original on the Mac; the two confirmed ones are in the Trash.
        XCTAssertEqual(records.filter { $0.safetyCopy == .kept }.count, 1)
        XCTAssertEqual(records.filter { $0.safetyCopy == .inTrash }.count, 2)
        let kept = state.tree.nodes.keys.filter { $0.hasSuffix(Names.beforeMoveSuffix) && !$0.contains("/.Trash/") }
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(state.tree.nodes.keys.filter { $0.contains("/.Trash/") }.count, 2)
        XCTAssertEqual(DemoScenarios.focus(for: .afterMoves).moveID, records.first?.id)
    }

    func testEveryJournalLineRendersAndTheReportIsWhatTheJournalSays() async throws {
        for s in DemoScenario.allCases {
            let b = backend(s)
            let log = b.loadLog()
            let names = Dictionary(uniqueKeysWithValues: Catalogue.all.map { ($0.versionedID, $0.name) })
            for e in log {
                let row = ActivityText.entry(for: e, recipeNames: names)
                XCTAssertFalse(row.text.isEmpty, "\(s): \(e.step)")
                clean(row.text, "\(s) activity")
                if e.isProblem { XCTAssertEqual(row.tone, .problem, "\(s): \(e.step)") }
            }
        }
        let (b, _) = make(.report)
        let records = b.relocations()
        XCTAssertEqual(records.map(\.state), [.aborted, .swapped, .rolledBack, .originalTrashed])
        XCTAssertEqual(records.first { $0.state == .aborted }?.abort, .mismatch)
        let doc = ReportText.document(records: records, log: b.loadLog(), drives: await b.volumes(), options: ReportOptions(appVersion: DemoScenarios.appVersion,
                                      macOSVersion: DemoScenarios.osVersion, now: Self.now, isSample: true))
        XCTAssertEqual(doc.relocations.count, 4)
        XCTAssertFalse(doc.problems.isEmpty, "the abort and the rollback are in the report")
        XCTAssertTrue(doc.isSample)
        XCTAssertEqual(doc.footer, ReportText.footer)
        clean(ReportText.markdown(doc), "report")
    }

    func testDiagnosticsAndLoginItemAndTheWatcherAreHarmless() async {
        let b = backend(.plan)
        let text = await b.diagnostics()
        XCTAssertFalse(text.isEmpty)
        XCTAssertEqual(b.loginItemState(), .notRegistered)
        XCTAssertEqual(b.setLoginItem(true), .enabled)
        XCTAssertEqual(b.loginItemState(), .enabled)
        XCTAssertEqual(b.setLoginItem(false), .notRegistered)
        let cancel = b.watch { _ in }
        cancel()
        let snap = await b.reconcile(.launch)
        XCTAssertEqual(snap, .empty)
    }

    func testTheSameBackendGivesTheSameSnapshotWhenNothingChanged() async {
        let b = backend(.driveAway)
        let a = await b.reconcile(.timer)
        let c = await b.reconcile(.timer)
        XCTAssertEqual(a, c, "a timer tick that finds nothing new produces an equal value")
    }
}

/// Collects progress from a `@Sendable` callback.
final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [MoveProgress] = []

    func add(_ p: MoveProgress) {
        lock.lock()
        defer { lock.unlock() }
        all.append(p)
    }

    var items: [MoveProgress] {
        lock.lock()
        defer { lock.unlock() }
        return all
    }
}
