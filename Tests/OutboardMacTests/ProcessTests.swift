import Darwin
import Foundation
import XCTest
import OutboardCore
@testable import OutboardMac

/// An in-memory `defaults`: answers the runner's commands without touching the real preferences of whoever runs the tests.
final class FakeDefaults {
    var store: [String: String] = [:]
    var commands: [ProcessRunner.Command] = []
    /// What a read returns instead of the stored value (to test the read-back).
    var lie: String?

    func install() {
        ProcessRunner.interceptor = { [self] command in
            commands.append(command)
            switch command {
            case .defaultsWrite(_, let key, _, let value):
                store[key] = value
                return ProcessRunner.Output(status: 0, stdout: Data(), timedOut: false)
            case .defaultsRead(_, let key):
                if let value = lie ?? store[key] { return ProcessRunner.Output(status: 0, stdout: Data((value + "\n").utf8), timedOut: false) }
                return ProcessRunner.Output(status: 1, stdout: Data(), timedOut: false)
            default:
                return nil
            }
        }
    }

    func uninstall() { ProcessRunner.interceptor = nil }
}

final class ProcessRunnerTests: MacTestCase {
    override func tearDown() {
        ProcessRunner.interceptor = nil
        ProcessRunner.timeoutSeconds = 10
        super.tearDown()
    }

    func testTheCommandSetIsClosedAndSpelledOut() {
        XCTAssertEqual(ProcessRunner.Command.diskutilInfo(path: "/Volumes/X").path, "/usr/sbin/diskutil")
        XCTAssertEqual(ProcessRunner.Command.diskutilInfo(path: "/Volumes/X").arguments, ["info", "-plist", "/Volumes/X"])
        XCTAssertEqual(ProcessRunner.Command.diskutilList.arguments, ["list", "-plist"])
        XCTAssertEqual(ProcessRunner.Command.diskutilApfsList.arguments, ["apfs", "list", "-plist"])
        XCTAssertEqual(ProcessRunner.Command.tmutilDestinations.path, "/usr/bin/tmutil")
        XCTAssertEqual(ProcessRunner.Command.tmutilDestinations.arguments, ["destinationinfo", "-X"])
    }

    func testAKeyOffTheCatalogueIsNeverRun() {
        var asked = false
        ProcessRunner.interceptor = { _ in asked = true; return nil }
        let read = ProcessRunner.run(.defaultsRead(domain: "com.apple.finder", key: "ShowPathbar"))
        let write = ProcessRunner.run(.defaultsWrite(domain: "com.apple.finder", key: "ShowPathbar", type: .int, value: "1"))
        XCTAssertFalse(read.ran)
        XCTAssertFalse(write.ran)
        XCTAssertFalse(asked, "a command off the allowlist does not even reach the runner")
        XCTAssertTrue(ProcessRunner.Command.defaultsWrite(domain: "com.apple.finder", key: "ShowPathbar", type: .int, value: "1").arguments.isEmpty)
    }

    func testACatalogueKeyBecomesAnArgumentArray() throws {
        guard case .defaults(let domain, let keys, _) = try XCTUnwrap(Catalogue.recipe("xcode-deriveddata")).method, let key = keys.first(where: { $0.value == .destinationPath }) else {
            return XCTFail("the DerivedData recipe writes a path key")
        }
        let write = ProcessRunner.Command.defaultsWrite(domain: domain, key: key.name, type: key.type, value: "/Volumes/X/DerivedData")
        XCTAssertEqual(write.arguments, ["write", domain, key.name, "-string", "/Volumes/X/DerivedData"])
        XCTAssertEqual(ProcessRunner.Command.defaultsRead(domain: domain, key: key.name).arguments, ["read", domain, key.name])
        XCTAssertEqual(write.path, "/usr/bin/defaults")
    }

    func testDiskutilListRunsAndParses() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/sbin/diskutil") else { throw XCTSkip("diskutil is not on this machine") }
        let out = await ProcessRunner.runAsync(.diskutilList)
        XCTAssertTrue(out.ok, "diskutil list exited with \(out.status)")
        XCTAssertFalse(out.stdout.isEmpty)
    }

    func testACommandThatTakesTooLongIsAbandonedNotKilled() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/sbin/diskutil") else { throw XCTSkip("diskutil is not on this machine") }
        ProcessRunner.timeoutSeconds = 0.0001
        let out = ProcessRunner.run(.diskutilList)
        XCTAssertTrue(out.timedOut)
        XCTAssertFalse(out.ok)
    }
}

final class DefaultsRedirectTests: MacTestCase {
    private let fake = FakeDefaults()

    override func tearDown() {
        fake.uninstall()
        super.tearDown()
    }

    private func planAndRecipe(_ sb: Sandbox) throws -> (MovePlan, Recipe) {
        let recipe = try XCTUnwrap(Catalogue.recipe("xcode-deriveddata"))
        guard case .defaults(let domain, let keys, let restore) = recipe.method else { throw XCTSkip("not a defaults recipe") }
        _ = restore
        var plan = Fixtures.plan(sb, recipeID: recipe.id)
        let writes = keys.compactMap { key -> DefaultsWrite? in
            switch key.value {
            case .destinationPath: return DefaultsWrite(key: key.name, type: key.type, value: plan.destination.finalPath)
            case .int(let n): return DefaultsWrite(key: key.name, type: key.type, value: String(n))
            case .string(let s): return DefaultsWrite(key: key.name, type: key.type, value: s)
            }
        }
        let revert = keys.compactMap { key -> DefaultsWrite? in
            guard let neutral = key.neutral else { return nil }
            switch neutral {
            case .int(let n): return DefaultsWrite(key: key.name, type: key.type, value: String(n))
            case .string(let s): return DefaultsWrite(key: key.name, type: key.type, value: s)
            case .destinationPath: return nil
            }
        }
        plan.redirect = .defaults(domain: domain, writes: writes, prior: keys.map { PriorValue(key: $0.name) }, revert: revert)
        return (plan, recipe)
    }

    private func requireNotRunning(_ recipe: Recipe, _ sb: Sandbox) throws {
        if RunningCheck.state(recipe: recipe, snapshot: RunningApps.snapshot(for: recipe, home: sb.home)) != .notRunning {
            throw XCTSkip("\(recipe.name) is running on this machine")
        }
    }

    func testApplyWritesTheValuesReadsThemBackAndJournalsFirst() throws {
        let sb = try makeSandbox()
        let (plan, recipe) = try planAndRecipe(sb)
        try requireNotRunning(recipe, sb)
        fake.install()
        let r = DefaultsRedirect.apply(plan, recipe: recipe, home: sb.home)
        XCTAssertTrue(r.isApplied, r.text)
        guard case .defaults(_, let writes, _, _) = plan.redirect else { return XCTFail("defaults plan") }
        for w in writes { XCTAssertEqual(fake.store[w.key], w.value) }
        let all = lines(sb)
        XCTAssertEqual(steps(all), ["redirect.intent", "redirect.result"])
        XCTAssertTrue((all[0].note ?? "").contains("defaults"))
        XCTAssertEqual(all[1].status, .ok)
        // The first command is the write; the reads come after it.
        XCTAssertTrue(fake.commands.first.map { if case .defaultsWrite = $0 { return true } else { return false } } ?? false)
    }

    func testAKeyThatIsNotOnTheCatalogueIsRefusedBeforeAnythingRuns() throws {
        let sb = try makeSandbox()
        let (_, recipe) = try planAndRecipe(sb)
        fake.install()
        let r = DefaultsRedirect.revert(domain: "com.apple.dt.Xcode", writes: [DefaultsWrite(key: "NotOnTheList", type: .int, value: "1")],
                                        subject: JournalSubject(moveID: Fixtures.moveID, recipe: "x@1"), recipe: recipe, home: sb.home)
        guard case .refused = r else { return XCTFail("expected refused, got \(r)") }
        XCTAssertTrue(fake.commands.isEmpty)
        XCTAssertTrue(lines(sb).isEmpty)
    }

    func testAValueThatDoesNotReadBackIsAFailureAndIsJournaledAsOne() throws {
        let sb = try makeSandbox()
        let (plan, recipe) = try planAndRecipe(sb)
        try requireNotRunning(recipe, sb)
        fake.install()
        fake.lie = "something else"
        let r = DefaultsRedirect.apply(plan, recipe: recipe, home: sb.home)
        guard case .failed = r else { return XCTFail("expected failed, got \(r)") }
        XCTAssertEqual(lines(sb).last?.status, .failed)
    }

    func testRevertWritesTheNeutralValueAndNeverDeletesAKey() throws {
        let sb = try makeSandbox()
        let (plan, recipe) = try planAndRecipe(sb)
        try requireNotRunning(recipe, sb)
        fake.install()
        guard case .defaults(let domain, _, _, let revert) = plan.redirect, !revert.isEmpty else { throw XCTSkip("this recipe has nothing to put back") }
        let r = DefaultsRedirect.revert(domain: domain, writes: revert, subject: JournalSubject(plan), recipe: recipe, home: sb.home)
        XCTAssertTrue(r.isApplied, r.text)
        for w in revert { XCTAssertEqual(fake.store[w.key], w.value) }
        XCTAssertEqual(steps(lines(sb, plan.id)), ["undoRedirect.intent", "undoRedirect.result"])
        for c in fake.commands {
            if case .defaultsWrite = c { continue }
            if case .defaultsRead = c { continue }
            XCTFail("only reads and writes are ever run, got \(c)")
        }
    }

    func testNothingIsWrittenWhenTheJournalIsUnwritable() throws {
        let sb = try makeSandbox()
        let (plan, recipe) = try planAndRecipe(sb)
        try requireNotRunning(recipe, sb)
        fake.install()
        XCTAssertTrue(Journal.prepare(home: sb.home))
        XCTAssertEqual(chmod(Journal.directory(home: sb.home), 0o500), 0)
        defer { chmod(Journal.directory(home: sb.home), 0o700) }
        guard case .notAttempted = DefaultsRedirect.apply(plan, recipe: recipe, home: sb.home) else { return XCTFail("expected notAttempted") }
        XCTAssertTrue(fake.store.isEmpty)
    }

    // MARK: a setting parked by the guard

    /// The journal of a swapped `defaults` move whose setting points at the (absent) drive, as the engine leaves it.
    private func swappedSetting(_ sb: Sandbox) throws -> (plan: MovePlan, recipe: Recipe, record: RelocationRecord) {
        let (plan, recipe) = try planAndRecipe(sb)
        try requireNotRunning(recipe, sb)
        fake.install()
        let subject = JournalSubject(plan)
        XCTAssertTrue(Journal.begin(plan, onDriveMissing: .revertSetting, volume: Fixtures.volumeRef(), home: sb.home, at: Fixtures.t0))
        XCTAssertTrue(Journal.intent(.preflight, subject: subject, home: sb.home, state: .preflight))
        XCTAssertTrue(Journal.intent(.copy, subject: subject, home: sb.home, state: .copying))
        XCTAssertTrue(Journal.intent(.verify, subject: subject, home: sb.home, state: .verifying))
        let applied = DefaultsRedirect.apply(plan, recipe: recipe, home: sb.home)
        XCTAssertTrue(applied.isApplied, applied.text)
        XCTAssertTrue(Journal.result(.swapped, subject: subject, home: sb.home, status: .ok, state: .swapped))
        let record = try XCTUnwrap(Fixtures.currentRecord(sb, plan.id))
        XCTAssertEqual(record.state, .swapped)
        XCTAssertEqual(record.onDriveMissing, .revertSetting)
        return (plan, recipe, record)
    }

    func testTheGuardParksASettingWithAParkLineNotARollbackLine() throws {
        let sb = try makeSandbox()
        let (plan, _, record) = try swappedSetting(sb)
        let result = Park.park(record, facts: JournalFacts(moveID: plan.id, all: Journal.loadAll(home: sb.home), home: sb.home), removal: .ejected, home: sb.home)
        guard case .reverted = result else { return XCTFail("expected reverted, got \(result)") }
        let tail = steps(lines(sb, plan.id)).suffix(2)
        XCTAssertEqual(Array(tail), ["park.intent", "park.result"])
        XCTAssertFalse(steps(lines(sb, plan.id)).contains { $0.hasPrefix("undoRedirect") }, "undoRedirect belongs to a rollback")

        let parked = try XCTUnwrap(Fixtures.currentRecord(sb, plan.id))
        XCTAssertTrue(parked.isParked)
        XCTAssertFalse(parked.rollbackStarted)
        XCTAssertFalse(parked.needsCheckBeforeReconnect, "ejected: no check is needed")
        XCTAssertEqual(JournalFacts(moveID: plan.id, all: Journal.loadAll(home: sb.home), home: sb.home).lastRemoval, .ejected)
        // Recovery sees a parked setting, not an interrupted rollback.
        XCTAssertEqual(Recovery.decide(record: parked, facts: Recover.gatherFacts(parked, home: sb.home)), .noop)
    }

    /// Xcode's custom-location key is not written back (only the mode key selects the default location), yet the setting has to read
    /// as the prior value, or the guard calls the parked relocation a conflict and never reconnects it.
    func testAParkedSettingReadsAsPriorAndTheGuardCallsItParked() throws {
        let sb = try makeSandbox()
        let (plan, _, record) = try swappedSetting(sb)
        guard case .defaults(let domain, _, _, let revert) = plan.redirect, !revert.isEmpty else { throw XCTSkip("this recipe has nothing to put back") }
        XCTAssertEqual(Recover.settingFact(record, domain: domain, mount: nil), .new)
        _ = Park.park(record, facts: JournalFacts(moveID: plan.id, all: Journal.loadAll(home: sb.home), home: sb.home), removal: .unclean, home: sb.home)
        for w in record.defaultsWrites where !revert.contains(where: { $0.key == w.key }) {
            XCTAssertEqual(fake.store[w.key], w.value, "a key with nothing to write back keeps its value")
        }
        XCTAssertEqual(Recover.settingFact(record, domain: domain, mount: nil), .prior)

        let parked = try XCTUnwrap(Fixtures.currentRecord(sb, plan.id))
        let facts = try XCTUnwrap(Reconcile.gather(parked, entries: Journal.loadAll(home: sb.home), mounted: try XCTUnwrap(VolumeIdentity.all()), home: sb.home))
        XCTAssertEqual(facts.path, .placeholder)
        XCTAssertEqual(GuardPolicy.classify(facts), .parked)

        // Somebody else's value for the mode key is still a conflict.
        if let mode = revert.first { fake.store[mode.key] = "99" }
        XCTAssertEqual(Recover.settingFact(record, domain: domain, mount: nil), .other)
    }

    func testASettingThatStillHoldsTheOldMountPathIsNewButNotAtTheCurrentOne() throws {
        let sb = try makeSandbox()
        let (_, _, record) = try swappedSetting(sb)
        let domain = try XCTUnwrap(record.defaultsDomain)
        let here = try XCTUnwrap(Recover.settingState(record, domain: domain, mount: Fixtures.absentMount))
        XCTAssertEqual(here.fact, .new)
        XCTAssertTrue(here.atMount)
        // The drive came back as "/Volumes/Other": the setting is still the move's, but names the old path.
        let moved = try XCTUnwrap(Recover.settingState(record, domain: domain, mount: "/Volumes/Other"))
        XCTAssertEqual(moved.fact, .new)
        XCTAssertFalse(moved.atMount)
        // Once it holds the values for the new mount point, it is at it.
        let rewritten = Health.recomputedWrites(record, mountPoint: "/Volumes/Other")
        for w in rewritten { fake.store[w.key] = w.value }
        let after = try XCTUnwrap(Recover.settingState(record, domain: domain, mount: "/Volumes/Other"))
        XCTAssertEqual(after.fact, .new)
        XCTAssertTrue(after.atMount)
    }
}
