import Darwin
import Foundation
import XCTest
import OutboardCore
@testable import OutboardMac

/// A folder above the source that is a link: the never-list and the sync check read path text, so the Mac layer follows the links
/// of the parent folders and refuses a detour (Fs.ancestorProblem). Written, not compiled.
final class AncestorLinkTests: MacTestCase {
    /// `~/.ollama` is a link into `rel`, which holds the real `models` folder. The plan is Ollama's, so its source is `~/.ollama/models`.
    private func linkedOllama(_ sb: Sandbox, into rel: String) -> MovePlan {
        sb.put(rel + "/models/m.bin", bytes: 10)
        sb.link(".ollama", to: sb.home + "/" + rel)
        return Fixtures.plan(sb, recipeID: "ollama-models")
    }

    func testAParentThatIsNotALinkPasses() throws {
        let sb = try makeSandbox()
        sb.dir(".npm")
        XCTAssertNil(Fs.ancestorProblem(sb.home + "/.npm", home: sb.home))
        XCTAssertNil(Fs.ancestorProblem(sb.home + "/no/such/folder/x", home: sb.home), "a parent that is not there fails by itself later")
    }

    func testAHomeThatIsItselfBehindALinkStillPasses() throws {
        let sb = try makeSandbox()
        sb.dir(".npm")
        let alias = sb.root + "/alias"
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: sb.home)
        XCTAssertNil(Fs.ancestorProblem(alias + "/.npm", home: alias))
        XCTAssertNil(Fs.ancestorProblem(alias + "/.npm/inner", home: alias))
    }

    func testAParentLinkedIntoACloudStorageFolderIsRefusedWithTheNeverListWording() throws {
        let sb = try makeSandbox()
        let plan = linkedOllama(sb, into: "Library/CloudStorage/Dropbox-Work/ollama")
        let why = try XCTUnwrap(Fs.ancestorProblem(plan.macPath, home: sb.home))
        XCTAssertTrue(why.contains("iCloud"), why)
    }

    func testAParentLinkedIntoMobileDocumentsIsRefused() throws {
        let sb = try makeSandbox()
        let plan = linkedOllama(sb, into: "Library/Mobile Documents/com~apple~CloudDocs/ollama")
        XCTAssertTrue(try XCTUnwrap(Fs.ancestorProblem(plan.macPath, home: sb.home)).contains("iCloud"))
    }

    func testAParentLinkedIntoDocumentsIsRefused() throws {
        let sb = try makeSandbox()
        let plan = linkedOllama(sb, into: "Documents/stash")
        XCTAssertTrue(try XCTUnwrap(Fs.ancestorProblem(plan.macPath, home: sb.home)).contains("iCloud"))
    }

    func testAnyOtherDetourIsRefusedToo() throws {
        let sb = try makeSandbox()
        let plan = linkedOllama(sb, into: "Elsewhere/ollama")
        XCTAssertEqual(Fs.ancestorProblem(plan.macPath, home: sb.home), Fs.linkedParentText)
    }

    func testTheRenamerRefusesThroughALinkedParentAndJournalsNothing() throws {
        let sb = try makeSandbox()
        let plan = linkedOllama(sb, into: "Library/CloudStorage/Dropbox-Work/ollama")
        let r = Renamer.perform(.setAside, from: plan.macPath, to: plan.beforeMovePath, ctx: RuleContext(plan: plan, home: sb.home),
                                subject: JournalSubject(plan), home: sb.home, expected: plan.sourceStamp)
        guard case .refused(let why) = r else { return XCTFail("expected refused, got \(r)") }
        XCTAssertTrue(why.contains("iCloud"), why)
        XCTAssertEqual(sb.names(in: "Library/CloudStorage/Dropbox-Work/ollama/models"), ["m.bin"])
        XCTAssertFalse(sb.exists(plan.beforeMovePath))
        XCTAssertTrue(lines(sb).isEmpty, "no intent line for a rename that never starts")
    }

    func testTheLastLookBeforeTheSwapRefusesALinkedParent() throws {
        let sb = try makeSandbox()
        let plan = linkedOllama(sb, into: "Documents/stash")
        guard case .changed(let why) = Guard.recheck(plan, home: sb.home) else { return XCTFail("expected changed") }
        XCTAssertTrue(why.contains("iCloud"), why)
    }

    func testTheLinkerRefusesToMakeALinkThroughALinkedParent() throws {
        let sb = try makeSandbox()
        let plan = linkedOllama(sb, into: "Library/CloudStorage/Dropbox-Work/ollama")
        try FileManager.default.moveItem(atPath: plan.macPath, toPath: sb.home + "/models-away")
        let made = Linker.create(linkPath: plan.macPath, target: plan.destination.finalPath, ctx: RuleContext(plan: plan, home: sb.home),
                                 volume: Fixtures.volumeRef(), mountPoint: plan.destination.mountPoint, subject: JournalSubject(plan), home: sb.home)
        guard case .refused(let why) = made else { return XCTFail("expected refused, got \(made)") }
        XCTAssertTrue(why.contains("iCloud"), why)
        XCTAssertFalse(sb.exists(plan.macPath))
    }
}

/// "Already redirected" means the setting sends the app elsewhere now. A rollback leaves the path key set, so the key alone says nothing.
final class RedirectedSettingTests: MacTestCase {
    /// A key that is not in `values` reads as absent (`.some(nil)`), like `defaults read` exiting 1.
    private func read(_ values: [String: String]) -> (DefaultsKeySpec) -> String?? {
        { key in .some(values[key.name]) }
    }

    func testDerivedDataIsRedirectedOnlyWhileItsModeKeyIsNotNeutral() throws {
        let sb = try makeSandbox()
        let recipe = try XCTUnwrap(Catalogue.recipe("xcode-deriveddata"))
        let path = "IDECustomDerivedDataLocation", mode = "IDEDerivedDataPathMode"
        XCTAssertTrue(DefaultsRedirect.isRedirected(recipe, home: sb.home, read: read([path: "/Volumes/X/DD", mode: "2"])))
        XCTAssertFalse(DefaultsRedirect.isRedirected(recipe, home: sb.home, read: read([path: "/Volumes/X/DD", mode: "0"])), "rolled back: the path stays, the mode is neutral")
        XCTAssertFalse(DefaultsRedirect.isRedirected(recipe, home: sb.home, read: read([path: "/Volumes/X/DD"])), "no mode key at all means the default location")
        XCTAssertTrue(DefaultsRedirect.isRedirected(recipe, home: sb.home, read: { key -> String?? in key.name == mode ? nil : .some("/Volumes/X/DD") }),
                      "a mode that cannot be read is not taken as neutral")
        XCTAssertFalse(DefaultsRedirect.isRedirected(recipe, home: sb.home, read: read([:])))
        XCTAssertFalse(DefaultsRedirect.isRedirected(recipe, home: sb.home, read: read([path: "", mode: "2"])))
    }

    func testArchivesAreRedirectedOnlyWhileThePathDiffersFromTheDefaultFolder() throws {
        let sb = try makeSandbox()
        let recipe = try XCTUnwrap(Catalogue.recipe("xcode-archives"))
        let key = "IDECustomDistributionArchivesLocation"
        XCTAssertTrue(DefaultsRedirect.isRedirected(recipe, home: sb.home, read: read([key: "/Volumes/X/Archives"])))
        XCTAssertFalse(DefaultsRedirect.isRedirected(recipe, home: sb.home, read: read([key: sb.home + "/Library/Developer/Xcode/Archives"])),
                       "a rollback writes the default folder back")
        XCTAssertFalse(DefaultsRedirect.isRedirected(recipe, home: sb.home, read: read([key: sb.home + "/Library/Developer/Xcode/Archives/"])))
        XCTAssertFalse(DefaultsRedirect.isRedirected(recipe, home: sb.home, read: read([key: "~/Library/Developer/Xcode/Archives"])))
    }

    func testARecipeWithoutASettingIsNeverRedirectedByOne() throws {
        let sb = try makeSandbox()
        let recipe = try XCTUnwrap(Catalogue.recipe("npm-cache"))
        XCTAssertFalse(DefaultsRedirect.isRedirected(recipe, home: sb.home, read: { _ in .some("/Volumes/X") }))
    }
}

/// A "Return to Mac" is a move of its own, so the link it parks is looked up under the move it brings back, and P7 only accepts the
/// link or the note that move made.
final class ReturnIdentityTests: MacTestCase {
    private let returnID = "20270116T080000Z-aaaaaa"

    /// The target the return engine builds: from the return plan, which has its own move id.
    private func returnTarget(_ layout: Fixtures.Layout, _ sb: Sandbox) throws -> RollbackTarget {
        var plan = layout.plan
        plan.direction = .returnToMac
        plan.id = returnID
        return try XCTUnwrap(RollbackTarget(plan: plan, home: sb.home))
    }

    func testTheLinkOfTheMoveBeingBroughtBackIsParked() throws {
        let sb = try makeSandbox()
        let layout = try Fixtures.swapped(sb)
        let record = try XCTUnwrap(Fixtures.currentRecord(sb))
        let result = Redirect.revert(try returnTarget(layout, sb), home: sb.home, factsMoveID: record.id)
        XCTAssertTrue(result.isApplied, result.text)
        XCTAssertFalse(sb.exists(layout.macPath))
        XCTAssertEqual(Fs.linkTarget(Park.parkedFolder(moveID: returnID, home: sb.home) + "/link"), layout.driveFolder)
    }

    func testALinkThatIsNotTheOneTheMoveMadeIsLeftAlone() throws {
        let sb = try makeSandbox()
        let layout = try Fixtures.swapped(sb)
        let record = try XCTUnwrap(Fixtures.currentRecord(sb))
        try FileManager.default.removeItem(atPath: layout.macPath)
        let other = sb.dir("somewhere-else")
        try FileManager.default.createSymbolicLink(atPath: layout.macPath, withDestinationPath: other)
        let result = Redirect.revert(try returnTarget(layout, sb), home: sb.home, factsMoveID: record.id)
        XCTAssertFalse(result.isApplied)
        XCTAssertEqual(Fs.linkTarget(layout.macPath), other, "somebody else's link stays where it is")
    }

    private func p7(_ sb: Sandbox, _ plan: MovePlan) throws -> PreflightCheck {
        var returning = plan
        returning.direction = .returnToMac
        returning.id = returnID
        let recipe = try XCTUnwrap(Catalogue.recipe(plan.recipeID))
        let facts = JournalFacts(moveID: plan.id, all: Journal.loadAll(home: sb.home), home: sb.home)
        let result = Preflight.runReturn(returning, recipe: recipe, home: sb.home, snapshot: RunningSnapshot(readable: true),
                                         journalWritable: true, original: facts)
        return try XCTUnwrap(result.report.checks.first { $0.check == .p7 })
    }

    func testPreflightAcceptsOnlyTheLinkTheMoveMade() throws {
        let sb = try makeSandbox()
        let layout = try Fixtures.swapped(sb)
        XCTAssertTrue(try p7(sb, layout.plan).passed, "the link Outboard made")
        try FileManager.default.removeItem(atPath: layout.macPath)
        XCTAssertTrue(try p7(sb, layout.plan).passed, "nothing at the path")
        try FileManager.default.createSymbolicLink(atPath: layout.macPath, withDestinationPath: sb.dir("somewhere-else"))
        XCTAssertFalse(try p7(sb, layout.plan).passed, "any other link")
    }

    func testPreflightRefusesASmallReadOnlyFileThatIsNotOurNote() throws {
        let sb = try makeSandbox()
        let layout = try Fixtures.swapped(sb)
        try FileManager.default.removeItem(atPath: layout.macPath)
        sb.put(".npm", bytes: 20)
        XCTAssertEqual(chmod(layout.macPath, 0o444), 0)
        XCTAssertFalse(try p7(sb, layout.plan).passed, "it looks like a note but the journal never wrote it")
    }
}

/// A setting leaves the path itself to the app, so a folder an app made there cannot be left in the way of the rollback.
final class DefaultsRollbackForeignTests: MacTestCase {
    private let fake = FakeDefaults()

    override func tearDown() {
        fake.uninstall()
        super.tearDown()
    }

    func testARollbackSetsAFolderTheAppMadeAsideAndPutsTheOriginalBack() throws {
        let sb = try makeSandbox()
        let recipe = try XCTUnwrap(Catalogue.recipe("xcode-deriveddata"))
        if RunningCheck.state(recipe: recipe, snapshot: RunningApps.snapshot(for: recipe, home: sb.home)) != .notRunning {
            throw XCTSkip("\(recipe.name) is running on this machine")
        }
        fake.install()
        sb.put("Library/Developer/Xcode/DerivedData/orig.o", bytes: 10)
        guard case .defaults(let domain, let keys, _) = recipe.method else { throw XCTSkip("not a defaults recipe") }
        var plan = Fixtures.plan(sb, recipeID: recipe.id)
        let writes = keys.compactMap { key -> DefaultsWrite? in
            switch key.value {
            case .destinationPath: return DefaultsWrite(key: key.name, type: key.type, value: plan.destination.finalPath)
            case .int(let n): return DefaultsWrite(key: key.name, type: key.type, value: String(n))
            case .string(let s): return DefaultsWrite(key: key.name, type: key.type, value: s)
            }
        }
        let revert = keys.compactMap { key -> DefaultsWrite? in
            switch key.neutral {
            case .int(let n)?: return DefaultsWrite(key: key.name, type: key.type, value: String(n))
            case .string(let s)?: return DefaultsWrite(key: key.name, type: key.type, value: PathText.expandTilde(s, home: sb.home))
            default: return nil
            }
        }
        plan.redirect = .defaults(domain: domain, writes: writes, prior: keys.map { PriorValue(key: $0.name) }, revert: revert)
        let subject = JournalSubject(plan)
        let home = sb.home
        XCTAssertTrue(Journal.begin(plan, onDriveMissing: .revertSetting, volume: Fixtures.volumeRef(), home: home, at: Fixtures.t0))
        XCTAssertTrue(Journal.intent(.preflight, subject: subject, home: home, state: .preflight))
        XCTAssertTrue(Journal.intent(.copy, subject: subject, home: home, state: .copying))
        XCTAssertTrue(Journal.intent(.verify, subject: subject, home: home, state: .verifying))
        XCTAssertTrue(Journal.intent(.setAside, subject: subject, home: home, src: plan.macPath, to: plan.beforeMovePath, stamp: plan.sourceStamp))
        try FileManager.default.moveItem(atPath: plan.macPath, toPath: plan.beforeMovePath)
        Journal.result(.setAside, subject: subject, home: home, status: .ok, src: plan.macPath, to: plan.beforeMovePath, stamp: Fs.stamp(of: plan.beforeMovePath))
        let applied = DefaultsRedirect.apply(plan, recipe: recipe, home: home)
        XCTAssertTrue(applied.isApplied, applied.text)
        Journal.result(.swapped, subject: subject, home: home, status: .ok, state: .swapped)

        // Xcode was opened for a moment and made its own folder.
        sb.put("Library/Developer/Xcode/DerivedData/made-by-app.o", bytes: 4)
        let record = try XCTUnwrap(Fixtures.currentRecord(sb, plan.id))
        XCTAssertTrue(record.canRollBack)
        let outcome = Rollback.run(record, home: home)
        XCTAssertTrue(outcome.ok, outcome.message)
        XCTAssertEqual(outcome.state, .rolledBack)
        XCTAssertEqual(sb.names(in: "Library/Developer/Xcode/DerivedData"), ["orig.o"], "the original is back")
        XCTAssertEqual(sb.names(in: "Library/Developer/Xcode/DerivedData.created-while-rolling-back"), ["made-by-app.o"], "set aside whole, never merged")
        XCTAssertFalse(sb.exists(plan.beforeMovePath))
        for w in revert { XCTAssertEqual(fake.store[w.key], w.value, "the setting was written back") }
    }
}

/// How a drive left: an eject counts only when the unmount followed it, and a mark does not outlive its drive.
final class RemovalMarkTests: MacTestCase {
    private let uuid = "3E1C0B7A-0000-4000-8000-0000000000AA"

    override func tearDown() {
        VolumeWatcher.clearRemoval(of: uuid)
        super.tearDown()
    }

    func testAnUnmountRightAfterAWillUnmountIsAnEject() {
        let now = Date()
        VolumeWatcher.noteWillUnmount(uuid, at: now)
        VolumeWatcher.noteDidUnmount(uuid, at: now.addingTimeInterval(2))
        XCTAssertEqual(VolumeWatcher.removal(of: uuid), .ejected)
    }

    func testAnUnmountWithNoWillUnmountIsUnclean() {
        VolumeWatcher.noteDidUnmount(uuid)
        XCTAssertEqual(VolumeWatcher.removal(of: uuid), .unclean)
    }

    func testAWillUnmountThatNothingAnsweredDoesNotMakeALaterPullAnEject() {
        let long = Date().addingTimeInterval(-3_600)
        VolumeWatcher.noteWillUnmount(uuid, at: long)   // the eject was refused: the drive stayed
        VolumeWatcher.noteDidUnmount(uuid)
        XCTAssertEqual(VolumeWatcher.removal(of: uuid), .unclean)
    }

    func testTheGuardSeeingTheDriveStillMountedDropsAStaleWillUnmount() {
        let asked = Date().addingTimeInterval(-VolumeWatcher.ejectWindowSeconds - 5)
        VolumeWatcher.noteWillUnmount(uuid, at: asked)
        VolumeWatcher.noteStillMounted([uuid])
        VolumeWatcher.noteDidUnmount(uuid)
        XCTAssertEqual(VolumeWatcher.removal(of: uuid), .unclean)
    }

    func testAFreshWillUnmountSurvivesThePassThatRunsBeforeTheUnmount() {
        VolumeWatcher.noteWillUnmount(uuid)
        VolumeWatcher.noteStillMounted([uuid])   // the pass the willUnmount trigger starts, while the drive is still there
        VolumeWatcher.noteDidUnmount(uuid)
        XCTAssertEqual(VolumeWatcher.removal(of: uuid), .ejected)
    }

    func testAMarkOfAnEarlierRemovalIsDroppedWhileTheDriveIsMounted() {
        VolumeWatcher.setRemovalForTests(.ejected, uuid: uuid)
        VolumeWatcher.noteStillMounted([uuid])
        XCTAssertNil(VolumeWatcher.removal(of: uuid))
    }

    func testAMarkJustSetIsKeptForTheSecondsAfterTheUnmount() {
        VolumeWatcher.noteDidUnmount(uuid)
        VolumeWatcher.noteStillMounted([uuid])   // the mount table can lag the notification by a moment
        XCTAssertEqual(VolumeWatcher.removal(of: uuid), .unclean)
    }

    func testMountingClearsEverything() {
        VolumeWatcher.noteWillUnmount(uuid)
        VolumeWatcher.noteDidUnmount(uuid)
        VolumeWatcher.clearRemoval(of: uuid)
        XCTAssertNil(VolumeWatcher.removal(of: uuid))
    }
}

final class ConfirmRefusalTests: MacTestCase {
    func testConfirmWithTheDriveAbsentChangesNothing() throws {
        let sb = try makeSandbox()
        sb.put(".npm.before-move/a.bin")
        let record = Fixtures.record(sb)
        let before = Journal.loadAll(home: sb.home).count
        let outcome = Confirm.run(record, home: sb.home)
        XCTAssertFalse(outcome.ok)
        XCTAssertTrue(outcome.message.contains("in first"), outcome.message)
        XCTAssertEqual(Journal.loadAll(home: sb.home).count, before, "a refused confirm writes nothing")
        XCTAssertTrue(sb.exists(sb.home + "/.npm.before-move/a.bin"))
    }
}
