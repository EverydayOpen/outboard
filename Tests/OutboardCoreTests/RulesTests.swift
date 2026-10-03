import Foundation
import XCTest
@testable import OutboardCore

final class RulesTests: XCTestCase {
    private let home = T.home
    private lazy var plan = T.plan("ollama-models")
    private lazy var ctx = RuleContext(plan: plan, home: home)

    private var mac: String { plan.macPath }                     // /Users/jane/.ollama/models
    private var before: String { mac + ".before-move" }
    private var staging: String { plan.stagingPath }
    private var final: String { plan.destination.finalPath }
    private var parked: String { ctx.parkedFolder }

    private func allowed(_ v: RuleVerdict, _ message: String = "", line: UInt = #line) { XCTAssertEqual(v, .allowed, "\(message) \(v.reason ?? "")", line: line) }
    private func refused(_ v: RuleVerdict, _ message: String = "", line: UInt = #line) { XCTAssertFalse(v.isAllowed, message, line: line) }

    func testTheContextDerivesEveryPathFromThePlan() {
        XCTAssertEqual(mac, "/Users/jane/.ollama/models")
        XCTAssertEqual(ctx.beforeMovePath, "/Users/jane/.ollama/models.before-move")
        XCTAssertEqual(ctx.stagingPath, "/Volumes/Outboard/Outboard/ollama-models/.staging-20270115T080000Z-3fa9c1")
        XCTAssertEqual(ctx.finalPath, "/Volumes/Outboard/Outboard/ollama-models/models")
        XCTAssertEqual(ctx.recipeFolder, "/Volumes/Outboard/Outboard/ollama-models")
        XCTAssertEqual(ctx.mountPoint, "/Volumes/Outboard")
        XCTAssertEqual(ctx.parkedFolder, "/Users/jane/Library/Application Support/Outboard/Parked/20270115T080000Z-3fa9c1")
        XCTAssertEqual(ctx.returningPath, "/Users/jane/.ollama/models.returning-20270115T080000Z-3fa9c1")
        let record = T.record()
        let fromRecord = RuleContext(record: record, home: home, mountPoint: "/Volumes/Outboard 1")
        XCTAssertEqual(fromRecord.finalPath, "/Volumes/Outboard 1/Outboard/ollama-models/models", "a drive that came back under another name")
        XCTAssertEqual(fromRecord.macPath, mac)
        let away = RuleContext(record: record, home: home, mountPoint: nil)
        XCTAssertEqual(away.finalPath, "")
        XCTAssertEqual(away.mountPoint, "")
    }

    // MARK: rename

    func testRenameApprovesExactlyTheClosedShapes() {
        allowed(RenameRules.check(.setAside, from: mac, to: before, ctx: ctx))
        allowed(RenameRules.check(.undoSetAside, from: before, to: mac, ctx: ctx))
        allowed(RenameRules.check(.publish, from: staging, to: final, ctx: ctx))
        allowed(RenameRules.check(.park, from: mac, to: parked + "/link", ctx: ctx))
        allowed(RenameRules.check(.unpark, from: mac, to: parked + "/note", ctx: ctx))
        allowed(RenameRules.check(.unpark, from: mac, to: parked + "/note-2", ctx: ctx))
        allowed(RenameRules.check(.unpark, from: parked + "/link", to: mac, ctx: ctx))
        allowed(RenameRules.check(.park, from: mac, to: parked + "/link-2", ctx: ctx), "a second park after a retarget left link behind")
        allowed(RenameRules.check(.park, from: mac, to: parked + "/link-13", ctx: ctx))
        allowed(RenameRules.check(.unpark, from: parked + "/link-2", to: mac, ctx: ctx))
        allowed(RenameRules.check(.setAsideForeign, from: mac, to: mac + ".created-while-moving", ctx: ctx))
        allowed(RenameRules.check(.setAsideForeign, from: mac, to: mac + ".created-while-moving-3", ctx: ctx))
        allowed(RenameRules.check(.setAsideForeign, from: mac, to: mac + ".created-while-rolling-back", ctx: ctx))
        allowed(RenameRules.check(.setAsideForeign, from: mac, to: mac + ".while-away-2027-01-15", ctx: ctx))
        allowed(RenameRules.check(.setAsideForeign, from: mac, to: mac + ".while-away-2027-01-15-2", ctx: ctx))
    }

    func testRenameRefusesEveryOtherShape() {
        refused(RenameRules.check(.setAside, from: mac, to: mac + ".bak", ctx: ctx), "wrong suffix")
        refused(RenameRules.check(.setAside, from: mac, to: "/Users/jane/elsewhere/models.before-move", ctx: ctx), "another folder")
        refused(RenameRules.check(.setAside, from: "/Users/jane/.ollama/other", to: "/Users/jane/.ollama/other.before-move", ctx: ctx), "not the plan's folder")
        refused(RenameRules.check(.setAside, from: mac, to: mac, ctx: ctx), "same path")
        refused(RenameRules.check(.undoSetAside, from: mac, to: before, ctx: ctx), "reversed")
        refused(RenameRules.check(.publish, from: staging, to: "/Volumes/Outboard/Outboard/other/models", ctx: ctx), "another recipe folder")
        refused(RenameRules.check(.publish, from: "/Volumes/Outboard/Outboard/ollama-models/.staging-x", to: final, ctx: ctx), "another move's staging")
        refused(RenameRules.check(.publish, from: staging, to: "/Volumes/Outboard/models", ctx: ctx), "outside the recipe folder")
        refused(RenameRules.check(.park, from: mac, to: parked + "/other", ctx: ctx), "not the link slot")
        refused(RenameRules.check(.park, from: mac, to: "/tmp/link", ctx: ctx))
        refused(RenameRules.check(.park, from: mac, to: parked + "/link-", ctx: ctx), "a suffix needs digits")
        refused(RenameRules.check(.park, from: mac, to: parked + "/link-x", ctx: ctx))
        refused(RenameRules.check(.park, from: mac, to: parked + "/link-2/inside", ctx: ctx), "not a sibling slot")
        refused(RenameRules.check(.unpark, from: parked + "/link-a", to: mac, ctx: ctx))
        refused(RenameRules.check(.unpark, from: mac, to: parked + "/notes", ctx: ctx))
        refused(RenameRules.check(.unpark, from: mac, to: mac + ".x", ctx: ctx))
        refused(RenameRules.check(.setAsideForeign, from: mac, to: mac + ".created-while-moving/sub", ctx: ctx), "not a sibling")
        refused(RenameRules.check(.setAsideForeign, from: mac, to: mac + ".deleted", ctx: ctx))
        refused(RenameRules.check(.setAsideForeign, from: mac, to: mac + ".while-away-today", ctx: ctx))
        refused(RenameRules.check(.setAsideForeign, from: mac, to: mac + ".created-while-moving-x", ctx: ctx))
        // wrong op for the pair
        refused(RenameRules.check(.park, from: mac, to: before, ctx: ctx))
        refused(RenameRules.check(.setAside, from: staging, to: final, ctx: ctx))
    }

    func testRenameRefusesTraversalRelativePathsAndSyncedFolders() {
        refused(RenameRules.check(.setAside, from: "/Users/jane/.ollama/../.ollama/models", to: before, ctx: ctx), "..")
        refused(RenameRules.check(.setAside, from: "models", to: "models.before-move", ctx: ctx), "relative")
        refused(RenameRules.check(.park, from: mac, to: parked + "/../link", ctx: ctx))
        refused(RenameRules.check(.publish, from: staging, to: "/Volumes/Outboard/Outboard/ollama-models/../models", ctx: ctx))
        refused(RenameRules.check(.setAside, from: "", to: before, ctx: ctx))
        // a plan whose mac path is on the never-list is never renamed, even when the shape is right
        for bad in ["/Users/jane/Documents/models", "/Users/jane/Library/Mail", "/Users/jane/Library/Containers/com.x/Data", "/Users/jane/Library/Mobile Documents/x",
                    "/Users/jane/Library/Caches", "/Users/jane", "/Applications/Foo.app/Contents", "/opt/homebrew/Cellar", "/Users/jane/Desktop/x"] {
            var p = T.plan("ollama-models")
            p.macPath = bad
            p.sourcePath = bad
            let c = RuleContext(plan: p, home: home)
            refused(RenameRules.check(.setAside, from: bad, to: bad + ".before-move", ctx: c), bad)
        }
        // the drive side may not be a sync folder
        var synced = T.plan("ollama-models")
        synced.destination.mountPoint = "/Volumes/Dropbox"
        let c = RuleContext(plan: synced, home: home)
        refused(RenameRules.check(.publish, from: c.stagingPath, to: c.finalPath, ctx: c))
    }

    func testRenameNeedsADriveForPublish() {
        let away = RuleContext(record: T.record(), home: home, mountPoint: nil)
        refused(RenameRules.check(.publish, from: staging, to: final, ctx: away))
        // an odd mount point is refused
        var odd = T.plan("ollama-models")
        odd.destination.mountPoint = "/Users/jane/mnt"
        let c = RuleContext(plan: odd, home: home)
        refused(RenameRules.check(.publish, from: c.stagingPath, to: c.finalPath, ctx: c))
    }

    func testAReturnRenamesOnlyItsOwnCopyIntoPlace() throws {
        let record = T.record(state: .confirmed)
        let result = MovePlanner.returnPlan(for: record, drive: T.drive(), home: home, now: T.t0, moveID: "20270116T080000Z-aaaaaa")
        let back = try XCTUnwrap(result.plan, result.refusal ?? "")
        let c = RuleContext(plan: back, home: home)
        XCTAssertEqual(c.direction, .returnToMac)
        allowed(RenameRules.check(.publish, from: c.returningPath, to: c.macPath, ctx: c))
        allowed(RenameRules.check(.park, from: c.macPath, to: c.parkedFolder + "/link", ctx: c))
        refused(RenameRules.check(.setAside, from: c.macPath, to: c.beforeMovePath, ctx: c), "a return keeps no safety copy of the link")
        refused(RenameRules.check(.publish, from: c.stagingPath, to: c.finalPath, ctx: c))
        allowed(CopyRules.check(source: c.finalPath, destination: c.returningPath, ctx: c))
        refused(CopyRules.check(source: c.finalPath, destination: c.macPath, ctx: c), "never straight onto the path")
        refused(LinkRules.check(linkPath: c.macPath, target: c.finalPath, ctx: c), "a return creates no link")
    }

    // MARK: copy, link, trash

    func testCopyApprovesOnlyThePlansSourceIntoItsStaging() {
        allowed(CopyRules.check(source: mac, destination: staging, ctx: ctx))
        refused(CopyRules.check(source: mac, destination: final, ctx: ctx), "not into the final name")
        refused(CopyRules.check(source: mac + "/blobs", destination: staging, ctx: ctx), "not a part of the folder")
        refused(CopyRules.check(source: "/Users/jane/Documents", destination: staging, ctx: ctx))
        refused(CopyRules.check(source: mac, destination: "/Volumes/Outboard/.staging-x", ctx: ctx), "outside the recipe folder")
        refused(CopyRules.check(source: mac, destination: mac + "/inside", ctx: ctx), "into its own source")
        refused(CopyRules.check(source: mac, destination: "/Volumes/Outboard/Outboard/ollama-models/../x/.staging-y", ctx: ctx))
        refused(CopyRules.check(source: mac, destination: ctx.recipeFolder + "/not-staging", ctx: ctx))
    }

    func testLinkApprovesOnlyThePlansLinkToTheRecordedVolume() {
        allowed(LinkRules.check(linkPath: mac, target: final, ctx: ctx))
        refused(LinkRules.check(linkPath: mac, target: "/Volumes/Other/Outboard/ollama-models/models", ctx: ctx), "another volume")
        refused(LinkRules.check(linkPath: mac, target: "/Users/jane/elsewhere", ctx: ctx), "a target on the Mac")
        refused(LinkRules.check(linkPath: "/Users/jane/.ollama", target: final, ctx: ctx), "another path")
        refused(LinkRules.check(linkPath: mac, target: final + "/../../../etc", ctx: ctx))
        // a drive that came back under another name: the target is recomputed from the current mount point
        let renamed = RuleContext(record: T.record(), home: home, mountPoint: "/Volumes/Outboard 1")
        allowed(LinkRules.check(linkPath: mac, target: "/Volumes/Outboard 1/Outboard/ollama-models/models", ctx: renamed))
        refused(LinkRules.check(linkPath: mac, target: final, ctx: renamed), "the old target is evidence, never reused")
    }

    func testTrashApprovesOnlyTheConfirmedOriginalAndKnownLeftovers() {
        var confirmed = RuleContext(record: T.record(state: .confirmed), home: home, mountPoint: "/Volumes/Outboard")
        allowed(TrashRules.allows(path: before, ctx: confirmed))
        refused(TrashRules.allows(path: mac, ctx: confirmed), "never the live folder")
        refused(TrashRules.allows(path: "/Users/jane/Documents", ctx: confirmed))
        refused(TrashRules.allows(path: before + "/x", ctx: confirmed))
        for state in [MoveState.swapped, .originalTrashed, .planned, .aborted] {
            let c = RuleContext(record: T.record(state: state), home: home, mountPoint: "/Volumes/Outboard")
            refused(TrashRules.allows(path: before, ctx: c), "\(state)")
        }
        let leftover = "/Volumes/Outboard/Outboard/ollama-models/.staging-20270115T080000Z-3fa9c1"
        refused(TrashRules.allows(path: leftover, ctx: confirmed), "not named by the journal")
        confirmed.knownLeftovers = [leftover]
        allowed(TrashRules.allows(path: leftover, ctx: confirmed))
        confirmed.knownLeftovers = ["/Users/jane/Documents", "/Volumes/Outboard", "/Users/jane/.ollama/models", "/Volumes/Outboard/other"]
        refused(TrashRules.allows(path: "/Users/jane/Documents", ctx: confirmed), "listed, but not on the drive")
        refused(TrashRules.allows(path: "/Volumes/Outboard", ctx: confirmed))
        refused(TrashRules.allows(path: "/Users/jane/.ollama/models", ctx: confirmed))
        refused(TrashRules.allows(path: "/Volumes/Outboard/other", ctx: confirmed), "outside Outboard/")
        let paths = RuleContext.leftoverPaths([
            Leftover(id: "a", moveID: "m", kind: .incompleteCopy, path: "Outboard/x/.staging-m", onDrive: true, bytes: 1, createdAt: T.t0),
            Leftover(id: "b", moveID: "m", kind: .safetyCopy, path: "~/x.before-move", onDrive: false, bytes: 1, createdAt: T.t0),
            Leftover(id: "c", moveID: "m", kind: .setAsideForeign, path: "~/x.created-while-moving", onDrive: false, bytes: 1, createdAt: T.t0),
        ], mountPoint: "/Volumes/Outboard")
        XCTAssertEqual(paths, ["/Volumes/Outboard/Outboard/x/.staging-m"])
        XCTAssertEqual(RuleContext.leftoverPaths([], mountPoint: nil), [])
    }

    func testTheHalfCopiedFolderOfAStoppedReturnMayGoToTheTrash() {
        var back = T.record(state: .aborted)
        back.direction = .returnToMac
        let c = RuleContext(record: back, home: home, mountPoint: "/Volumes/Outboard")
        allowed(TrashRules.allows(path: c.returningPath, ctx: c))
        refused(TrashRules.allows(path: c.macPath, ctx: c))
        var running = back
        running.state = .copying
        refused(TrashRules.allows(path: RuleContext(record: running, home: home, mountPoint: "/Volumes/Outboard").returningPath, ctx: RuleContext(record: running, home: home, mountPoint: "/Volumes/Outboard")))
        var forward = T.record(state: .aborted)
        forward.direction = .toDrive
        let f = RuleContext(record: forward, home: home, mountPoint: "/Volumes/Outboard")
        refused(TrashRules.allows(path: f.returningPath, ctx: f), "only a return has such a folder")
    }

    // MARK: the never-list

    func testNeverListReasons() {
        func reason(_ p: String) -> String? { NeverList.reason(forPath: p, home: home)?.recipeID }
        XCTAssertEqual(reason("/Users/jane"), "never-caches-home")
        XCTAssertEqual(reason("/Users/jane/"), "never-caches-home")
        XCTAssertEqual(reason("/users/JANE"), "never-caches-home", "case-insensitive like the volume")
        XCTAssertEqual(reason("/Users/jane/Library"), "never-caches-home")
        XCTAssertEqual(reason("/Users/jane/Library/Caches"), "never-caches-home")
        XCTAssertNil(reason("/Users/jane/Library/Caches/llama.cpp"), "a per-app cache is fine")
        XCTAssertEqual(reason("/Users/jane/Library/Containers/com.x/Data"), "never-containers")
        XCTAssertEqual(reason("/Users/jane/Library/Group Containers/group.x"), "never-containers")
        XCTAssertEqual(reason("/Users/jane/library/containers"), "never-containers")
        XCTAssertEqual(reason("/Users/jane/Library/Mail/V10"), "never-apple-data")
        XCTAssertEqual(reason("/Users/jane/Library/Safari"), "never-apple-data")
        XCTAssertEqual(reason("/Users/jane/Library/Messages/chat.db"), "never-apple-data")
        XCTAssertEqual(reason("/Users/jane/Documents"), "never-icloud")
        XCTAssertEqual(reason("/Users/jane/Desktop/x"), "never-icloud")
        XCTAssertEqual(reason("/Users/jane/Library/Mobile Documents/com~apple~CloudDocs/x"), "never-icloud")
        XCTAssertEqual(reason("/Users/jane/Library/CloudStorage/OneDrive-X"), "never-icloud")
        XCTAssertEqual(reason("/Users/jane/Dropbox/x"), "never-icloud")
        XCTAssertEqual(reason("/opt/homebrew"), "never-homebrew")
        XCTAssertEqual(reason("/opt/homebrew/Cellar/x"), "never-homebrew")
        XCTAssertEqual(reason("/usr/local/bin"), "never-homebrew")
        XCTAssertEqual(reason("/Applications"), "never-app-bundles")
        XCTAssertEqual(reason("/Applications/Xcode.app/Contents"), "never-app-bundles")
        XCTAssertEqual(reason("/Users/jane/Downloads/Foo.app"), "never-app-bundles")
        XCTAssertEqual(reason("/Users/jane/Library/Developer/CoreSimulator/Devices"), "never-simulator-runtimes")
        XCTAssertEqual(reason("/Library/Developer/CoreSimulator/Images"), "never-system")
        XCTAssertEqual(reason("/Users/jane/.orbstack/data"), "never-docker-orbstack")
        XCTAssertEqual(reason("/Users/jane/.docker"), "never-docker-orbstack")
        XCTAssertEqual(reason("/Users/jane/Library/pnpm/store"), "never-pnpm-uv")
        XCTAssertEqual(reason("/Users/jane/.cache/uv"), "never-pnpm-uv")
        XCTAssertEqual(reason("/"), "never-system")
        XCTAssertEqual(reason("/System/Library"), "never-system")
        XCTAssertEqual(reason("/Users/jane/a/../b"), "never-path")
        XCTAssertEqual(reason("relative"), "never-path")
        // the folders the recipes use are fine
        for ok in ["/Users/jane/.ollama/models", "/Users/jane/.cache/huggingface/hub", "/Users/jane/.npm", "/Users/jane/Library/Developer/Xcode/DerivedData",
                   "/Users/jane/Library/Developer/Xcode/Archives", "/Users/jane/Library/Application Support/MobileSync/Backup", "/Users/jane/Pictures/Photos Library.photoslibrary",
                   "/Users/jane/Library/Android/sdk", "/Volumes/Outboard/Outboard/x", "/Users/janet/x"] {
            XCTAssertNil(reason(ok), ok)
        }
        XCTAssertFalse((NeverList.reason(forPath: "/Users/jane/Documents", home: home)?.text ?? "").isEmpty)
    }

    func testSyncedPathAndOutboardOwn() {
        XCTAssertTrue(NeverList.isSyncedPath("/Users/jane/Library/Mobile Documents/x"))
        XCTAssertTrue(NeverList.isSyncedPath("/Volumes/X/CloudStorage/y"))
        XCTAssertTrue(NeverList.isSyncedPath("/Users/jane/Library/Application Support/CloudDocs/session"))
        XCTAssertTrue(NeverList.isSyncedPath("/Users/jane/Library/Mobile Documents/iCloud~com~x/Documents"))
        XCTAssertTrue(NeverList.isSyncedPath("/Users/jane/OneDrive - Contoso/x"))
        XCTAssertTrue(NeverList.isSyncedPath("/Users/jane/Google Drive/x"))
        XCTAssertFalse(NeverList.isSyncedPath("/Volumes/Outboard/Outboard/x"))
        XCTAssertFalse(NeverList.isSyncedPath("/Users/jane/.ollama/models"))
        XCTAssertTrue(NeverList.isOutboardOwn("/Users/jane/Library/Application Support/Outboard/journal-2027-01.jsonl", home: home))
        XCTAssertTrue(NeverList.isOutboardOwn("/Users/jane/Library/Application Support/Outboard", home: home))
        XCTAssertFalse(NeverList.isOutboardOwn("/Users/jane/Library/Application Support/Other", home: home))
        XCTAssertFalse(NeverList.isOutboardOwn("/Users/jane/Library/Application Support/OutboardX", home: home))
    }
}
