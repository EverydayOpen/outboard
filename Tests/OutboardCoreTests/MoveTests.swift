import Foundation
import XCTest
@testable import OutboardCore

final class MoveTests: XCTestCase {
    let home = T.home

    // MARK: the journal of a whole move

    /// Every line a move writes, in order, with the states the Mac layer sets.
    func happyPath(_ plan: MovePlan, upTo last: MoveStep? = nil) -> [JournalEntry] {
        let id = plan.id
        let rid = "\(plan.recipeID)@\(plan.recipeVersion)"
        var seq = 0
        var lines: [JournalEntry] = [T.begin(plan, seq: 1)]
        seq = 1
        func add(_ phase: JournalPhase, _ step: MoveStep, status: StepStatus? = nil, state: MoveState? = nil, _ mutate: (inout JournalEntry) -> Void = { _ in }) {
            seq += 1
            var e = JournalEntry(id: id, seq: seq, ts: T.t0.addingTimeInterval(Double(seq) * 60), phase: phase, step: step, recipe: rid, state: state, status: status)
            mutate(&e)
            lines.append(e)
        }
        let mac = "~/.ollama/models"
        add(.intent, .preflight, state: .preflight)
        add(.result, .preflight, status: .ok) { $0.counts = JournalCounts(checksPassed: 14, checksTotal: 14, freeBytes: 480_000_000_000); $0.volName = "Outboard"; $0.fsName = "APFS" }
        add(.intent, .copy, state: .copying) { $0.counts = JournalCounts(files: 100, bytes: plan.logicalBytes); $0.volName = "Outboard" }
        add(.result, .copy, status: .ok)
        add(.intent, .verify, state: .verifying)
        add(.result, .verify, status: .ok) { $0.verification = VerificationSummary(filesCompared: 100, bytesCompared: plan.logicalBytes, differences: 0, manifestDigest: "d", completedAt: T.t0) }
        add(.intent, .publish)
        add(.result, .publish, status: .ok)
        add(.intent, .setAside) { $0.src = mac; $0.to = mac + ".before-move" }
        add(.result, .setAside, status: .ok) { $0.src = mac; $0.to = mac + ".before-move" }
        add(.intent, .redirect) { $0.note = "link" }
        add(.result, .redirect, status: .ok) { $0.note = "link"; $0.src = mac }
        add(.result, .swapped, status: .ok, state: .swapped)
        add(.intent, .confirm)
        add(.result, .confirm, status: .ok, state: .confirmed)
        add(.intent, .trash) { $0.src = mac + ".before-move" }
        add(.result, .trash, status: .ok, state: .originalTrashed) { $0.trashedPath = "~/.Trash/models.before-move" }
        if let last, let idx = lines.lastIndex(where: { $0.moveStep == last }) { return Array(lines[0...idx]) }
        return lines
    }

    // MARK: state machine

    func testTransitionsMatchTheLegalSuccessors() {
        for a in MoveState.allCases {
            for b in MoveState.allCases { XCTAssertEqual(MoveMachine.canTransition(a, to: b), a.legalSuccessors.contains(b), "\(a) -> \(b)") }
        }
        XCTAssertTrue(MoveMachine.canTransition(.verifying, to: .swapped))
        XCTAssertFalse(MoveMachine.canTransition(.copying, to: .swapped), "no skipping the comparison")
        XCTAssertFalse(MoveMachine.canTransition(.swapped, to: .aborted), "once the original was renamed it is a rollback, not an abort")
        XCTAssertFalse(MoveMachine.canTransition(.confirmed, to: .rolledBack), "confirming ends the roll back")
        XCTAssertFalse(MoveMachine.canTransition(.aborted, to: .planned))
    }

    func testTheJournalLineDecidesAndAnIllegalLineChangesNothing() {
        let swapped = T.line("m", 1, .result, .swapped, status: .ok, state: .swapped)
        XCTAssertEqual(MoveMachine.state(after: swapped, current: .verifying), .swapped)
        XCTAssertEqual(MoveMachine.state(after: swapped, current: .copying), .copying, "copying cannot jump to swapped")
        XCTAssertNotNil(MoveMachine.apply(swapped, current: .copying).problem)
        XCTAssertNil(MoveMachine.apply(swapped, current: .swapped).problem)
        XCTAssertEqual(MoveMachine.state(after: T.line("m", 1, .intent, .setAside), current: .verifying), .verifying, "a line without a state keeps it")
        // implied states
        XCTAssertEqual(MoveMachine.impliedState(for: T.line("m", 1, .intent, .copy)), .copying)
        XCTAssertEqual(MoveMachine.impliedState(for: T.line("m", 1, .result, .confirm, status: .ok)), .confirmed)
        XCTAssertNil(MoveMachine.impliedState(for: T.line("m", 1, .result, .confirm, status: .failed)))
        XCTAssertEqual(MoveMachine.impliedState(for: T.line("m", 1, .result, .abort, status: .ok)), .aborted)
        XCTAssertNil(MoveMachine.impliedState(for: T.line("m", 1, .intent, .setAside)))
        var unknown = T.line("m", 1, .result, .swapped)
        unknown.step = "someFutureStep"
        XCTAssertEqual(MoveMachine.state(after: unknown, current: .copying), .copying)
    }

    // MARK: fold

    func testFoldOfAWholeMove() throws {
        let plan = T.plan()
        let records = RelocationFold.records(from: happyPath(plan))
        XCTAssertEqual(records.count, 1)
        let r = try XCTUnwrap(records.first)
        XCTAssertEqual(r.id, plan.id)
        XCTAssertEqual(r.state, .originalTrashed)
        XCTAssertEqual(r.safetyCopy, .inTrash)
        XCTAssertEqual(r.recipeID, "ollama-models")
        XCTAssertEqual(r.macPath, "~/.ollama/models")
        XCTAssertEqual(r.relativePath, "Outboard/ollama-models/models")
        XCTAssertEqual(r.volume, T.volumeRef())
        XCTAssertEqual(r.onDriveMissing, .parkPlaceholder)
        XCTAssertEqual(r.logicalBytes, 30_000_000_000)
        XCTAssertEqual(r.verification?.filesCompared, 100)
        XCTAssertNotNil(r.swappedAt)
        XCTAssertNotNil(r.confirmedAt)
        XCTAssertNotNil(r.trashedAt)
        XCTAssertEqual(r.last, JournalMark(step: .trash, phase: .result, status: .ok))
        XCTAssertEqual(r.problems, [])
        XCTAssertTrue(r.state.isActive)
        XCTAssertTrue(r.canReturn)
        XCTAssertFalse(r.canRollBack)
        XCTAssertFalse(r.isParked)
    }

    func testFoldStopsAtEveryPrefixWithTheStateTheMachineGives() throws {
        let plan = T.plan()
        let full = happyPath(plan)
        var seen: [MoveState] = []
        for n in 1...full.count {
            let r = try XCTUnwrap(RelocationFold.records(from: Array(full[0..<n])).first)
            seen.append(r.state)
            if n < full.count { XCTAssertEqual(r.last.step.rawValue, full[n - 1].step) }
        }
        // monotone along the machine, ending in originalTrashed
        XCTAssertEqual(seen.first, .planned)
        XCTAssertEqual(seen.last, .originalTrashed)
        for (a, b) in zip(seen, seen.dropFirst()) { XCTAssertTrue(a == b || MoveMachine.canTransition(a, to: b), "\(a) -> \(b)") }
        let atSwap = try XCTUnwrap(RelocationFold.records(from: happyPath(plan, upTo: .swapped)).first)
        XCTAssertEqual(atSwap.state, .swapped)
        XCTAssertEqual(atSwap.safetyCopy, .kept)
        XCTAssertTrue(atSwap.canRollBack)
        XCTAssertTrue(atSwap.canConfirm)
        let atSetAside = try XCTUnwrap(RelocationFold.records(from: happyPath(plan, upTo: .setAside)).first)
        XCTAssertEqual(atSetAside.state, .verifying)
        XCTAssertEqual(atSetAside.safetyCopy, .kept)
    }

    func testFoldIsTolerantOfATornLastLineAndUnknownSteps() throws {
        let plan = T.plan()
        let lines = happyPath(plan, upTo: .swapped)
        let text = lines.map(ActivityLog.encode).joined(separator: "\n") + "\n{\"v\":1,\"id\":\"" + plan.id + "\",\"seq\":99,\"ts\":\"2027-01-15T08:"
        let decoded = ActivityLog.decodeAll(text)
        XCTAssertEqual(decoded.skippedLines, 1, "the torn line is dropped")
        XCTAssertEqual(decoded.entries, lines)
        var withFuture = decoded.entries
        var future = T.line(plan.id, 50, .result, .swapped, status: .ok)
        future.step = "futureStep"
        withFuture.append(future)
        let r = try XCTUnwrap(RelocationFold.records(from: withFuture).first)
        XCTAssertEqual(r.state, .swapped)
        XCTAssertTrue(r.problems.contains { $0.contains("futureStep") }, "an unknown step is shown, not dropped")
        // lines of a move with no begin line are skipped, not guessed at
        XCTAssertEqual(RelocationFold.records(from: [T.line("orphan", 1, .result, .swapped, status: .ok)]), [])
        // app-level lines belong to no move
        XCTAssertEqual(RelocationFold.records(from: [T.line("app", 1, .result, .useDrive, status: .ok)]), [])
    }

    func testFoldAbortParkAndNewestFirst() throws {
        let plan = T.plan()
        var aborted = happyPath(plan, upTo: .copy)
        aborted.append(T.line(plan.id, 20, .result, .abort, status: .ok, state: .aborted, at: 900) { $0.abort = .mismatch })
        let a = try XCTUnwrap(RelocationFold.records(from: aborted).first)
        XCTAssertEqual(a.state, .aborted)
        XCTAssertEqual(a.abort, .mismatch)
        XCTAssertEqual(a.safetyCopy, .none)
        XCTAssertTrue(a.problems.contains { $0.contains("a file on the drive differs") })

        var parked = happyPath(plan, upTo: .swapped)
        parked.append(T.line(plan.id, 30, .intent, .park, at: 2000))
        parked.append(T.line(plan.id, 31, .result, .park, status: .ok, at: 2001) { $0.note = "unclean" })
        var p = try XCTUnwrap(RelocationFold.records(from: parked).first)
        XCTAssertTrue(p.isParked)
        XCTAssertTrue(p.needsCheckBeforeReconnect)
        XCTAssertEqual(p.removalKind, .unclean)
        parked[parked.count - 1].note = "park:unknown"
        p = try XCTUnwrap(RelocationFold.records(from: parked).first)
        XCTAssertTrue(p.needsCheckBeforeReconnect, "not seeing how it left is not an eject")
        XCTAssertEqual(p.removalKind, .unknown)
        parked[parked.count - 1].note = nil
        XCTAssertEqual(try XCTUnwrap(RelocationFold.records(from: parked).first).removalKind, .unknown, "no word, no claim")
        parked[parked.count - 1].note = "ejected"
        p = try XCTUnwrap(RelocationFold.records(from: parked).first)
        XCTAssertTrue(p.isParked)
        XCTAssertFalse(p.needsCheckBeforeReconnect, "an eject we saw")
        XCTAssertEqual(p.removalKind, .ejected)
        parked.append(T.line(plan.id, 32, .result, .unpark, status: .ok, at: 3000))
        p = try XCTUnwrap(RelocationFold.records(from: parked).first)
        XCTAssertFalse(p.isParked)
        XCTAssertNil(p.removalKind, "an answered park says nothing about the next removal")

        let second = T.plan("npm-cache", bytes: 2_000_000_000, id: "20270116T080000Z-bbbbbb")
        var both = happyPath(plan, upTo: .swapped)
        both.append(T.begin(second, seq: 1, at: 100_000))
        let records = RelocationFold.records(from: both)
        XCTAssertEqual(records.map(\.id), [second.id, plan.id], "newest first")
        XCTAssertEqual(records.first?.createdAt, T.t0.addingTimeInterval(100_000))
    }

    func testLeftoversAreLabelledAndNeverDeleted() throws {
        let plan = T.plan()
        let rel = "Outboard/ollama-models/models"
        // aborted after the copy started: the staging folder
        var aborted = happyPath(plan, upTo: .copy)
        aborted.append(T.line(plan.id, 20, .result, .abort, status: .ok, state: .aborted, at: 900) { $0.abort = .interrupted })
        var records = RelocationFold.records(from: aborted)
        var leftovers = RelocationFold.leftovers(from: aborted, records: records)
        XCTAssertEqual(leftovers.map(\.kind), [.incompleteCopy])
        XCTAssertEqual(leftovers.first?.path, "Outboard/ollama-models/.staging-\(plan.id)")
        XCTAssertTrue(leftovers.first?.onDrive ?? false)
        XCTAssertEqual(leftovers.first?.volume, T.volumeRef())
        // aborted after the copy was published: the published folder
        var published = happyPath(plan, upTo: .publish)
        published.append(T.line(plan.id, 25, .result, .abort, status: .ok, state: .aborted, at: 900) { $0.abort = .appLaunched })
        records = RelocationFold.records(from: published)
        leftovers = RelocationFold.leftovers(from: published, records: records)
        XCTAssertEqual(leftovers.first?.path, rel)
        // aborted before any copy: nothing to label
        var early = happyPath(plan, upTo: .preflight)
        early.append(T.line(plan.id, 9, .result, .abort, status: .ok, state: .aborted) { $0.abort = .preflightFailed })
        XCTAssertEqual(RelocationFold.leftovers(from: early, records: RelocationFold.records(from: early)), [])
        // moved to the Trash by the user: no longer a leftover
        var trashed = aborted
        trashed.append(T.line(plan.id, 30, .intent, .trash, at: 1000) { $0.src = "Outboard/ollama-models/.staging-\(plan.id)" })
        trashed.append(T.line(plan.id, 31, .result, .trash, status: .ok, at: 1001))
        XCTAssertEqual(RelocationFold.leftovers(from: trashed, records: RelocationFold.records(from: trashed)), [])
        // rolled back: the published copy stays on the drive, labelled
        var rolled = happyPath(plan, upTo: .swapped)
        rolled.append(T.line(plan.id, 40, .result, .rollback, status: .ok, state: .rolledBack, at: 2000))
        records = RelocationFold.records(from: rolled)
        XCTAssertEqual(records.first?.state, .rolledBack)
        XCTAssertEqual(records.first?.safetyCopy, SafetyCopyState.none)
        XCTAssertEqual(RelocationFold.leftovers(from: rolled, records: records).map(\.kind), [.rolledBackCopy])
        // confirmed, original not yet in the Trash: the safety copy is offered; swapped: it is not (roll back is still possible)
        let confirmed = happyPath(plan, upTo: .confirm)
        XCTAssertEqual(RelocationFold.leftovers(from: confirmed, records: RelocationFold.records(from: confirmed)).map(\.kind), [.safetyCopy])
        XCTAssertEqual(RelocationFold.leftovers(from: confirmed, records: RelocationFold.records(from: confirmed)).first?.path, "~/.ollama/models.before-move")
        let swapped = happyPath(plan, upTo: .swapped)
        XCTAssertEqual(RelocationFold.leftovers(from: swapped, records: RelocationFold.records(from: swapped)), [])
        // returned: the drive copy stays
        var returned = happyPath(plan)
        returned.append(T.line(plan.id, 60, .result, .returned, status: .ok, state: .returned, at: 5000))
        XCTAssertEqual(RelocationFold.leftovers(from: returned, records: RelocationFold.records(from: returned)).map(\.kind), [.driveCopyAfterReturn])
        // an item an app created in the gap
        var foreign = happyPath(plan, upTo: .swapped)
        foreign.append(T.line(plan.id, 70, .intent, .setAsideForeign, at: 2000) { $0.to = "~/.ollama/models.created-while-moving" })
        foreign.append(T.line(plan.id, 71, .result, .setAsideForeign, status: .ok, at: 2001))
        XCTAssertEqual(RelocationFold.leftovers(from: foreign, records: RelocationFold.records(from: foreign)).map(\.kind), [.setAsideForeign])
    }

    // MARK: planner

    func testMoveIDsAreUtcTimeAndSixHexDigits() {
        XCTAssertEqual(MovePlanner.newMoveID(now: Date(timeIntervalSince1970: 1_791_022_500), random: 0x3fa9c1), "20261003T101500Z-3fa9c1")
        XCTAssertEqual(MovePlanner.newMoveID(now: T.t0, random: 0xAB), "20270115T080000Z-0000ab")
        XCTAssertEqual(MovePlanner.newMoveID(now: T.t0, random: 0xFFFF_FFFF), "20270115T080000Z-ffffff")
    }

    func testLeafNames() {
        XCTAssertEqual(MovePlanner.leafName(forSource: "~/.npm"), "npm")
        XCTAssertEqual(MovePlanner.leafName(forSource: "~/.cache/huggingface/hub"), "hub")
        XCTAssertEqual(MovePlanner.leafName(forSource: "~/Library/Developer/Xcode/DerivedData"), "DerivedData")
        XCTAssertEqual(MovePlanner.leafName(forSource: "~/Library/Caches/llama.cpp"), "llama.cpp")
        XCTAssertEqual(MovePlanner.leafName(forSource: "~/..."), "data")
    }

    private func attempt(_ recipeID: String = "ollama-models", bytes: UInt64 = 30_000_000_000, drive: DriveFacts? = nil, prior: [PriorValue]? = nil,
                         prefs: Preferences = Preferences(), recipe: Recipe? = nil, report: EligibilityReport? = nil, policy: Policy = .release,
                         mutateScan: (inout SizeScan) -> Void = { _ in }, mutateConsent: (inout ConsentRecord) -> Void = { _ in }) -> MovePlanResult {
        let r = recipe ?? T.recipe(recipeID)
        let d = drive ?? T.drive()
        let rep = report ?? Eligibility.evaluate(volume: d, recipe: r, source: SourceNeeds(logicalBytes: bytes, isCaseSensitive: .no, hasHardLinks: false, hasSymlinks: true), policy: policy)
        var consent = T.consent(for: recipeID, report: rep)
        mutateConsent(&consent)
        return MovePlanner.plan(recipe: r, folder: T.scan(recipeID, bytes: bytes, mutate: mutateScan), drive: d, report: rep, consent: consent,
                                prior: prior ?? T.prior(for: recipeID), home: home, now: T.t0, moveID: "20270115T080000Z-3fa9c1", groupID: nil, policy: policy, prefs: prefs)
    }

    func testAGoodPlanForALink() throws {
        var prefs = Preferences()
        prefs.showUnverifiedMoves = true
        let plan = try XCTUnwrap(attempt(prefs: prefs).plan)
        XCTAssertEqual(plan.sourcePath, "/Users/jane/.ollama/models")
        XCTAssertEqual(plan.macPath, plan.sourcePath)
        XCTAssertEqual(plan.destination.relativePath, "Outboard/ollama-models/models")
        XCTAssertEqual(plan.destination.finalPath, "/Volumes/Outboard/Outboard/ollama-models/models")
        XCTAssertEqual(plan.destination.volumeToken, T.token)
        XCTAssertEqual(plan.redirect, .symbolicLink(linkPath: plan.macPath, target: plan.destination.finalPath))
        XCTAssertEqual(plan.method, .symlink)
        XCTAssertEqual(plan.risk, .expensive)
        XCTAssertEqual(plan.sourceStamp.type, .directory)
        XCTAssertEqual(plan.logicalBytes, 30_000_000_000)
        XCTAssertEqual(plan.beforeMovePath, "/Users/jane/.ollama/models.before-move")
        XCTAssertNil(attempt(prefs: prefs).refusal)
    }

    func testAGoodPlanForTheXcodeSettingResolvesWritesAndWhatPutsItBack() throws {
        var prefs = Preferences()
        prefs.showUnverifiedMoves = true
        // the keys do not exist yet: the path key is left alone on a restore, the mode key goes back to its neutral value
        let none = try XCTUnwrap(attempt("xcode-deriveddata", bytes: 5_000_000_000, prefs: prefs).plan)
        guard case .defaults(let domain, let writes, let prior, let revert) = none.redirect else { return XCTFail() }
        XCTAssertEqual(domain, "com.apple.dt.Xcode")
        XCTAssertEqual(writes, [DefaultsWrite(key: "IDECustomDerivedDataLocation", type: .string, value: "/Volumes/Outboard/Outboard/xcode-deriveddata/DerivedData"),
                                DefaultsWrite(key: "IDEDerivedDataPathMode", type: .int, value: "2")])
        XCTAssertEqual(prior.count, 2)
        XCTAssertEqual(revert, [DefaultsWrite(key: "IDEDerivedDataPathMode", type: .int, value: "0")])
        // the keys had values: restore writes them back
        let had = [PriorValue(key: "IDECustomDerivedDataLocation", type: .string, value: "/Users/jane/Builds"), PriorValue(key: "IDEDerivedDataPathMode", type: .int, value: "1")]
        let plan = try XCTUnwrap(attempt("xcode-deriveddata", bytes: 5_000_000_000, prior: had, prefs: prefs).plan)
        guard case .defaults(_, _, _, let revert2) = plan.redirect else { return XCTFail() }
        XCTAssertEqual(revert2, [DefaultsWrite(key: "IDECustomDerivedDataLocation", type: .string, value: "/Users/jane/Builds"),
                                 DefaultsWrite(key: "IDEDerivedDataPathMode", type: .int, value: "1")])
        // archives: no prior value, so the default folder (tilde expanded) is the neutral value
        let arch = try XCTUnwrap(attempt("xcode-archives", bytes: 2_000_000_000, prefs: prefs).plan)
        guard case .defaults(_, let w3, _, let r3) = arch.redirect else { return XCTFail() }
        XCTAssertEqual(w3.map(\.key), ["IDECustomDistributionArchivesLocation"])
        XCTAssertEqual(r3, [DefaultsWrite(key: "IDECustomDistributionArchivesLocation", type: .string, value: "/Users/jane/Library/Developer/Xcode/Archives")])
        // the prior values were never read: nothing is planned
        XCTAssertNotNil(attempt("xcode-deriveddata", bytes: 5_000_000_000, prior: [], prefs: prefs).refusal)
    }

    func testPlanningRefusals() {
        var on = Preferences()
        on.showUnverifiedMoves = true
        func refusal(_ r: MovePlanResult) -> String { r.refusal ?? "" }
        XCTAssertNil(attempt(prefs: on).refusal)
        XCTAssertEqual(refusal(attempt()), "This move isn't turned on in this build.", "unverified and the preference is off")
        XCTAssertNotNil(attempt(prefs: on, mutateConsent: { $0.sawUnverifiedNote = false }).refusal, "the sheet must have carried the line")
        XCTAssertNotNil(attempt(prefs: on, mutateConsent: { $0.recipeVersion = 9 }).refusal)
        XCTAssertNotNil(attempt(prefs: on, mutateConsent: { $0.tickedIDs = [] }).refusal, "boxes not ticked")
        XCTAssertNotNil(attempt(prefs: on, mutateConsent: { $0.tickedIDs.removeLast() }).refusal)
        XCTAssertTrue(refusal(attempt("photos-library", bytes: 5_000_000_000, prefs: on, recipe: T.recipe("photos-library"))).contains("steps on its card"), "a guided card is not moved")
        XCTAssertTrue(refusal(attempt("never-homebrew", bytes: 5, prefs: on, recipe: T.recipe("never-homebrew"))).contains("Outboard doesn't move"))
        // the folder
        XCTAssertNotNil(attempt(prefs: on, mutateScan: { $0.state = .absent }).refusal)
        XCTAssertNotNil(attempt(prefs: on, mutateScan: { $0.state = .atLeast }).refusal)
        XCTAssertTrue(refusal(attempt(prefs: on, mutateScan: { $0.state = .notMeasured; $0.reason = .needsFullDiskAccess })).contains("Full Disk Access"))
        XCTAssertTrue(refusal(attempt(prefs: on, mutateScan: { $0.isLink = true })).contains("already a link"))
        XCTAssertNotNil(attempt(prefs: on, mutateScan: { $0.stamp = nil }).refusal)
        XCTAssertNotNil(attempt(prefs: on, mutateScan: { $0.stamp = FileStamp(device: 1, inode: 1, type: .symlink) }).refusal)
        XCTAssertNotNil(attempt(prefs: on, mutateScan: { $0.path = "~/Documents" }).refusal, "not one of the recipe's folders")
        XCTAssertNotNil(attempt(prefs: on, mutateScan: { $0.fingerprint.specialFiles = 1 }).refusal)
        XCTAssertNotNil(attempt(prefs: on, mutateScan: { $0.fingerprint.datalessFiles = 3 }).refusal)
        XCTAssertNotNil(attempt(prefs: on, mutateScan: { $0.fingerprint.sparseFiles = 1 }).refusal)
        XCTAssertNotNil(attempt(prefs: on, mutateScan: { $0.recipeID = "npm-cache" }).refusal)
        // the drive
        XCTAssertEqual(refusal(attempt(drive: T.drive { $0.isSolidState = .no }, prefs: on)), "This looks like a spinning hard disk. It's too slow for app data. Outboard will only use SSDs.")
        XCTAssertTrue(refusal(attempt(drive: T.drive { $0.hasOutboardMarker = false; $0.markerToken = nil }, prefs: on)).contains("Use this drive"))
        XCTAssertNotNil(attempt(drive: T.drive { $0.availableBytes = nil }, prefs: on).refusal)
        XCTAssertNotNil(attempt(drive: T.drive(uuid: nil), prefs: on).refusal)
        // a report made for another drive or another recipe
        let other = Eligibility.evaluate(volume: T.drive(uuid: "OTHER"), recipe: T.recipe("ollama-models"), source: nil, policy: .release)
        XCTAssertNotNil(attempt(prefs: on, report: other).refusal)
        let another = Eligibility.evaluate(volume: T.drive(), recipe: T.recipe("npm-cache"), source: nil, policy: .release)
        XCTAssertNotNil(attempt(prefs: on, report: another).refusal)
        // not enough space, checked again independently of the report
        let rosy = EligibilityReport(volumeID: T.uuid, recipeID: "ollama-models", verdicts: [])
        XCTAssertEqual(refusal(attempt(drive: T.drive { $0.availableBytes = 40_000_000_000 }, prefs: on, report: rosy)), "Needs 55 GB free on Outboard drive; it has 40 GB.")
        // an acknowledgement that is not ticked
        let plain = T.drive { $0.isEncrypted = .no }
        XCTAssertNil(attempt("ios-device-backups", bytes: 16_000_000_000, drive: plain, prefs: on).refusal)
        XCTAssertNotNil(attempt("ios-device-backups", bytes: 16_000_000_000, drive: plain, prefs: on, mutateConsent: { $0.ackIDs = [] }).refusal)
    }

    func testRequiredCheckboxesAreTheRecipesPlusTheAcknowledgements() {
        let backups = T.recipe("ios-device-backups")
        let plain = Eligibility.evaluate(volume: T.drive { $0.isEncrypted = .no }, recipe: backups, source: SourceNeeds(logicalBytes: 1), policy: .release)
        XCTAssertEqual(MovePlanner.requiredCheckboxIDs(recipe: backups, report: plain), ["device-disconnected", "backups-on-drive-only", "community-method", "ack-e16"])
        let good = Eligibility.evaluate(volume: T.drive(), recipe: backups, source: SourceNeeds(logicalBytes: 1), policy: .release)
        XCTAssertEqual(MovePlanner.requiredCheckboxIDs(recipe: backups, report: good), ["device-disconnected", "backups-on-drive-only", "community-method"])
    }

    func testCompanionFoldersGetTheirOwnPlansWithTheSameGroup() throws {
        var on = Preferences()
        on.showUnverifiedMoves = true
        let r = T.recipe("huggingface-hub-cache")
        let d = T.drive()
        let rep = Eligibility.evaluate(volume: d, recipe: r, source: SourceNeeds(logicalBytes: 1_000_000_000), policy: .release)
        let hub = MovePlanner.plan(recipe: r, folder: T.scan("huggingface-hub-cache", bytes: 9_000_000_000), drive: d, report: rep, consent: T.consent(for: r.id, report: rep),
                                   prior: [], home: home, now: T.t0, moveID: "20270115T080000Z-111111", groupID: "g1", prefs: on)
        let xet = MovePlanner.plan(recipe: r, folder: T.scan("huggingface-hub-cache", path: "~/.cache/huggingface/xet", bytes: 2_000_000_000), drive: d, report: rep,
                                   consent: T.consent(for: r.id, report: rep), prior: [], home: home, now: T.t0, moveID: "20270115T080000Z-222222", groupID: "g1", prefs: on)
        XCTAssertEqual(try XCTUnwrap(hub.plan).destination.leaf, "hub")
        XCTAssertEqual(try XCTUnwrap(xet.plan).destination.leaf, "xet")
        XCTAssertEqual(try XCTUnwrap(xet.plan).groupID, "g1")
        XCTAssertEqual(try XCTUnwrap(xet.plan).destination.recipeFolder, "Outboard/huggingface-hub-cache")
    }

    func testTheJournalPlanUsesTildePaths() throws {
        let plan = T.plan()
        let jp = MovePlanner.journalPlan(plan, onDriveMissing: .parkPlaceholder, volume: T.volumeRef(), fileCount: 1200, home: home)
        XCTAssertEqual(jp.macPath, "~/.ollama/models")
        XCTAssertEqual(jp.relativePath, "Outboard/ollama-models/models")
        XCTAssertEqual(jp.fileCount, 1200)
        XCTAssertEqual(jp.consent, plan.consent)
        XCTAssertEqual(MovePlanner.journalPlan(plan, onDriveMissing: .parkPlaceholder, volume: T.volumeRef(), fileCount: 1).macPath, "~/.ollama/models", "home is recognised under /Users")
        let derived = T.plan("xcode-deriveddata", bytes: 5_000_000_000)
        let jd = MovePlanner.journalPlan(derived, onDriveMissing: .revertSetting, volume: T.volumeRef(), fileCount: 1, home: home)
        XCTAssertEqual(jd.defaultsDomain, "com.apple.dt.Xcode")
        XCTAssertEqual(jd.defaultsWrites.count, 2)
        XCTAssertEqual(jd.defaultsRevert.map(\.key), ["IDEDerivedDataPathMode"])
    }

    /// The journal keeps `~` for the home folder in a setting's saved values too; reading it back with the home folder gives the real paths.
    func testASettingsValuesAreJournaledWithTildeAndExpandedAgainOnRead() throws {
        let archives = T.plan("xcode-archives", bytes: 5_000_000_000)
        // a value the user had set under their home folder, and one elsewhere
        let prior = [PriorValue(key: "IDECustomDistributionArchivesLocation", type: .string, value: "/Users/jane/Dev/Archives")]
        var withPrior = archives
        if case .defaults(let d, let w, _, _) = archives.redirect {
            withPrior.redirect = .defaults(domain: d, writes: w, prior: prior,
                                           revert: [DefaultsWrite(key: "IDECustomDistributionArchivesLocation", type: .string, value: "/Users/jane/Dev/Archives"),
                                                    DefaultsWrite(key: "IDEDerivedDataPathMode", type: .int, value: "0"),
                                                    DefaultsWrite(key: "Other", type: .string, value: "/Volumes/Other/Archives")])
        } else {
            return XCTFail("xcode-archives is a setting recipe")
        }
        let jp = MovePlanner.journalPlan(withPrior, onDriveMissing: .leaveAlone, volume: T.volumeRef(), fileCount: 1, home: home)
        XCTAssertEqual(jp.defaultsPrior.first?.value, "~/Dev/Archives")
        XCTAssertEqual(jp.defaultsRevert.map(\.value), ["~/Dev/Archives", "0", "/Volumes/Other/Archives"], "only a value under the home folder changes")
        for text in jp.defaultsWrites.map(\.value) + jp.defaultsRevert.map(\.value) + jp.defaultsPrior.compactMap(\.value) {
            XCTAssertFalse(text.contains("/Users/jane"), "no home path in the journal: \(text)")
        }
        // folded without the home folder the values stay as journaled; with it they are real paths again
        let begin = T.line(withPrior.id, 1, .intent, .begin) { $0.plan = jp }
        let bare = try XCTUnwrap(RelocationFold.records(from: [begin]).first)
        XCTAssertEqual(bare.defaultsRevert.first?.value, "~/Dev/Archives")
        let full = try XCTUnwrap(RelocationFold.records(from: [begin], home: home).first)
        XCTAssertEqual(full.defaultsRevert.map(\.value), ["/Users/jane/Dev/Archives", "0", "/Volumes/Other/Archives"])
        XCTAssertEqual(PathText.tildeValue("2", home: home), "2")
        XCTAssertEqual(PathText.tildeValue("/Users/janet/x", home: home), "/Users/janet/x", "only whole path components match")
        XCTAssertEqual(PathText.tildeValue("/Users/jane", home: home), "~")
    }

    func testReturnPlan() throws {
        let record = T.record(state: .confirmed)
        let ok = MovePlanner.returnPlan(for: record, drive: T.drive(), home: home, now: T.t0, moveID: "r1")
        let plan = try XCTUnwrap(ok.plan)
        XCTAssertEqual(plan.direction, .returnToMac)
        XCTAssertEqual(plan.sourcePath, "/Volumes/Outboard/Outboard/ollama-models/models")
        XCTAssertEqual(plan.macPath, "/Users/jane/.ollama/models")
        XCTAssertEqual(plan.destination.volumeToken, T.token)
        XCTAssertNotNil(MovePlanner.returnPlan(for: T.record(state: .swapped), drive: T.drive(), home: home, now: T.t0, moveID: "r").refusal, "only a confirmed move returns")
        XCTAssertNotNil(MovePlanner.returnPlan(for: record, drive: T.drive(uuid: "OTHER"), home: home, now: T.t0, moveID: "r").refusal)
        XCTAssertNotNil(MovePlanner.returnPlan(for: record, drive: T.drive { $0.markerToken = "another" }, home: home, now: T.t0, moveID: "r").refusal)
        XCTAssertNotNil(MovePlanner.returnPlan(for: record, drive: T.drive { $0.isLocked = true }, home: home, now: T.t0, moveID: "r").refusal)
        var back = T.record(state: .confirmed)
        back.direction = .returnToMac
        XCTAssertNotNil(MovePlanner.returnPlan(for: back, drive: T.drive(), home: home, now: T.t0, moveID: "r").refusal)
    }

    // MARK: running check

    func testRunningCheck() {
        let ollama = T.recipe("ollama-models")
        XCTAssertEqual(RunningCheck.state(recipe: ollama, snapshot: RunningSnapshot(readable: true)), .notRunning)
        XCTAssertEqual(RunningCheck.state(recipe: ollama, snapshot: RunningSnapshot(readable: true, bundleIDs: ["com.electron.ollama"])), .running)
        XCTAssertEqual(RunningCheck.state(recipe: ollama, snapshot: RunningSnapshot(readable: true, processNames: ["OLLAMA"])), .running, "a name match, any case")
        XCTAssertEqual(RunningCheck.state(recipe: ollama, snapshot: RunningSnapshot(readable: true, openHandleHolders: ["jupyter"])), .running)
        XCTAssertEqual(RunningCheck.state(recipe: ollama, snapshot: RunningSnapshot(readable: true, openHandleHolders: [])), .notRunning)
        XCTAssertEqual(RunningCheck.state(recipe: ollama, snapshot: RunningSnapshot(readable: false)), .unknown, "unreadable blocks")
        XCTAssertEqual(RunningCheck.state(recipe: ollama, snapshot: RunningSnapshot(readable: false, bundleIDs: ["com.electron.ollama"])), .running, "a positive match wins")
        XCTAssertEqual(RunningCheck.state(recipe: ollama, snapshot: RunningSnapshot(readable: true, bundleIDs: ["com.apple.Safari"], processNames: ["Safari"])), .notRunning)
        // libproc cuts names at 16 characters
        var long = ollama
        long.processNames = ["AMPDeviceDiscoveryAgent"]
        XCTAssertEqual(RunningCheck.state(recipe: long, snapshot: RunningSnapshot(readable: true, processNames: ["AMPDeviceDiscove"])), .running)
        XCTAssertEqual(RunningCheck.state(recipe: long, snapshot: RunningSnapshot(readable: true, processNames: ["AMPDevice"])), .notRunning)
    }

    func testBlockerRows() {
        let xcode = T.recipe("xcode-deriveddata")
        let rows = RunningCheck.blockers(recipe: xcode, snapshot: RunningSnapshot(readable: true, bundleIDs: ["com.apple.dt.Xcode"], openHandleHolders: ["Spotlight"]))
        XCTAssertEqual(rows.map(\.name), ["Xcode", "Simulator", "Instruments", "xcodebuild", "Spotlight (has files open)"])
        XCTAssertEqual(rows.map(\.state), [.running, .notRunning, .notRunning, .notRunning, .running])
        XCTAssertFalse(rows[0].isClear)
        XCTAssertTrue(rows[1].isClear)
        let unreadable = RunningCheck.blockers(recipe: xcode, snapshot: RunningSnapshot(readable: false))
        XCTAssertTrue(unreadable.allSatisfy { $0.state == .unknown })
        let backups = RunningCheck.blockers(recipe: T.recipe("ios-device-backups"), snapshot: RunningSnapshot(readable: true))
        XCTAssertEqual(backups.count, 1, "a recipe with nothing to watch still shows one row")
        XCTAssertEqual(backups[0].state, .notRunning)
        XCTAssertEqual(RunningCheck.blockers(recipe: T.recipe("ios-device-backups"), snapshot: RunningSnapshot(readable: false))[0].state, .unknown)
    }
}
