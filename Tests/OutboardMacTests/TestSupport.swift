import Darwin
import Foundation
import XCTest
import OutboardCore
@testable import OutboardMac

/// A fake HOME for one test, under /Users/Shared (a path macOS never rewrites: the real path of a /var/folders temp folder is
/// /private/var/..., which Core's never-list rightly refuses). Nothing here touches the real home. `trashItem` puts what it moves
/// into the real Trash, so tests that trash something skip when the session cannot do it.
final class Sandbox {
    let root: String
    var home: String { root + "/home" }

    init() throws {
        root = "/Users/Shared/OutboardTests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home + "/Library/Application Support", withIntermediateDirectories: true)
    }

    func cleanup() {
        unlock(root)
        try? FileManager.default.removeItem(atPath: root)
    }

    /// Puts a folder or file back into a state that can be removed (a test may have made one unreadable or read-only).
    private func unlock(_ path: String) {
        var st = stat()
        guard lstat(path, &st) == 0 else { return }
        if (st.st_mode & S_IFMT) == S_IFLNK { return }
        chmod(path, (st.st_mode & S_IFMT) == S_IFDIR ? 0o700 : 0o600)
        guard (st.st_mode & S_IFMT) == S_IFDIR else { return }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] { unlock(path + "/" + name) }
    }

    // MARK: building

    @discardableResult
    func put(_ rel: String, bytes: Int = 100, fill: UInt8 = 0x41) -> String {
        let path = home + "/" + rel
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: path, contents: Data(repeating: fill, count: bytes))
        return path
    }

    @discardableResult
    func dir(_ rel: String) -> String {
        let path = home + "/" + rel
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    func link(_ rel: String, to target: String) {
        let path = home + "/" + rel
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
    }

    func exists(_ path: String) -> Bool { Fs.exists(path) }

    func mode(_ path: String) -> UInt32 {
        var st = stat()
        XCTAssertEqual(lstat(path, &st), 0, path)
        return UInt32(st.st_mode & 0o777)
    }

    func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }

    func names(in rel: String) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: home + "/" + rel)) ?? []).sorted() }
}

class MacTestCase: XCTestCase {
    func makeSandbox() throws -> Sandbox {
        let sb = try Sandbox()
        addTeardownBlock { sb.cleanup() }
        return sb
    }
}

/// Builders for the Core types the Mac verbs take.
enum Fixtures {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let volumeUUID = "3E1C0B7A-0000-4000-8000-000000000001"
    static let token = ["tok", "0001", "abcd"].joined(separator: "-")
    static let moveID = "20270115T080000Z-3fa9c1"
    /// A mount point no real drive has, so a test that reaches for the drive finds nothing and writes nothing there.
    static let absentMount = "/Volumes/OutboardTest-NoSuchDrive-7f3a9c"

    static func volumeRef(name: String = "Outboard") -> VolumeRef { VolumeRef(uuid: volumeUUID, name: name, token: token) }

    /// A plan for `npm-cache` whose source is `<home>/.npm` (the fake home's), on a drive that is not mounted anywhere: good for
    /// everything that does not need the drive (rules, stamps, renames beside the original).
    static func plan(_ sandbox: Sandbox, recipeID: String = "npm-cache", id: String = moveID, mount: String = Fixtures.absentMount) -> MovePlan {
        let recipe = Catalogue.recipe(recipeID)!
        let source = recipe.absoluteSource(home: sandbox.home)!
        let stamp = Fs.stamp(of: source) ?? FileStamp(device: 0, inode: 0, type: .directory)
        let leaf = MovePlanner.leafName(forSource: recipe.source ?? "x")
        let destination = PlanDestination(volumeUUID: volumeUUID, volumeName: "Outboard", mountPoint: mount, volumeToken: token,
                                          recipeFolder: Names.driveFolder + "/" + recipe.id, leaf: leaf)
        return MovePlan(id: id, recipeID: recipe.id, recipeVersion: recipe.version, recipeName: recipe.name, method: recipe.kind, risk: recipe.riskClass,
                        sourcePath: source, macPath: source, sourceStamp: stamp, sourceFingerprint: TreeFingerprint(files: 1, directories: 1, logicalBytes: 100, allocatedBytes: 4096),
                        destination: destination, redirect: .symbolicLink(linkPath: source, target: destination.finalPath),
                        consent: ConsentRecord(recipeVersion: recipe.version, tickedIDs: [], sawUnverifiedNote: true), createdAt: t0)
    }

    static func record(_ sandbox: Sandbox, recipeID: String = "npm-cache", id: String = moveID, state: MoveState = .swapped,
                       mutate: (inout RelocationRecord) -> Void = { _ in }) -> RelocationRecord {
        let recipe = Catalogue.recipe(recipeID)!
        var r = RelocationRecord(id: id, recipeID: recipe.id, recipeVersion: recipe.version, recipeName: recipe.name, method: recipe.kind, risk: recipe.riskClass,
                                 onDriveMissing: recipe.onDriveMissing, state: state, macPath: Fs.tilde(recipe.absoluteSource(home: sandbox.home)!, home: sandbox.home),
                                 volume: volumeRef(), relativePath: "Outboard/" + recipe.id + "/" + MovePlanner.leafName(forSource: recipe.source ?? "x"),
                                 logicalBytes: 100, fileCount: 1, safetyCopy: .kept, last: JournalMark(step: .swapped, phase: .result, status: .ok),
                                 createdAt: t0, updatedAt: t0)
        mutate(&r)
        return r
    }
}

extension XCTestCase {
    /// The journal lines of one move, in order.
    func lines(_ sandbox: Sandbox, _ moveID: String = Fixtures.moveID) -> [JournalEntry] {
        Journal.loadAll(home: sandbox.home).filter { $0.id == moveID }
    }

    func steps(_ entries: [JournalEntry]) -> [String] { entries.map { "\($0.step).\($0.phase.rawValue)" } }
}

extension Fixtures {
    /// A move that got as far as the swap, laid out on disk the way the engine leaves it, with the journal lines the verbs write:
    /// the original renamed to `.npm.before-move`, and (when `redirected`) a link at `.npm` pointing into a folder inside the sandbox
    /// that stands in for the drive's copy. `upTo` stops the journal after that step (a crash).
    struct Layout {
        var plan: MovePlan
        var subject: JournalSubject
        var driveFolder: String
        var macPath: String
        var beforePath: String
    }

    @discardableResult
    static func swapped(_ sb: Sandbox, redirected: Bool = true, journalUpTo: MoveStep? = nil) throws -> Layout {
        sb.put(".npm/orig.bin", bytes: 10)
        let plan = Fixtures.plan(sb)
        let subject = JournalSubject(plan)
        let home = sb.home
        let macPath = plan.macPath
        let before = plan.beforeMovePath
        let drive = sb.dir("fakedrive/Outboard/npm-cache/npm")
        sb.put("fakedrive/Outboard/npm-cache/npm/copy.bin", bytes: 10)
        var ok = Journal.begin(plan, onDriveMissing: .parkPlaceholder, volume: volumeRef(), home: home, at: t0)
        ok = ok && Journal.intent(.preflight, subject: subject, home: home, state: .preflight)
        Journal.result(.preflight, subject: subject, home: home, status: .ok)
        ok = ok && Journal.intent(.copy, subject: subject, home: home, src: macPath, to: plan.stagingPath, stamp: plan.sourceStamp, state: .copying)
        Journal.result(.copy, subject: subject, home: home, status: .ok, stamp: plan.sourceStamp)
        ok = ok && Journal.intent(.verify, subject: subject, home: home, state: .verifying)
        Journal.result(.verify, subject: subject, home: home, status: .ok)
        XCTAssertTrue(ok)
        if journalUpTo == .verify { return Layout(plan: plan, subject: subject, driveFolder: drive, macPath: macPath, beforePath: before) }
        XCTAssertTrue(Journal.intent(.setAside, subject: subject, home: home, src: macPath, to: before, stamp: plan.sourceStamp))
        try FileManager.default.moveItem(atPath: macPath, toPath: before)
        if journalUpTo != .setAside {
            Journal.result(.setAside, subject: subject, home: home, status: .ok, src: macPath, to: before, stamp: Fs.stamp(of: before))
        }
        if redirected {
            XCTAssertTrue(Journal.intent(.redirect, subject: subject, home: home, src: macPath, to: drive, note: JournalNote.link))
            try FileManager.default.createSymbolicLink(atPath: macPath, withDestinationPath: drive)
            Journal.result(.redirect, subject: subject, home: home, status: .ok, src: macPath, to: drive, stamp: Fs.stamp(of: macPath), note: JournalNote.link)
            Journal.result(.swapped, subject: subject, home: home, status: .ok, state: .swapped)
        }
        return Layout(plan: plan, subject: subject, driveFolder: drive, macPath: macPath, beforePath: before)
    }

    static func currentRecord(_ sb: Sandbox, _ id: String = moveID) -> RelocationRecord? {
        RelocationFold.records(from: Journal.loadAll(home: sb.home)).first { $0.id == id }
    }
}

extension XCTestCase {
    /// A built executable next to the test bundle (`OutboardFixture`, `OutboardCrashHelper`): SwiftPM puts them in the same folder as the
    /// `.xctest`. Looks beside the bundle of this class, the main bundle and the running test binary.
    func builtProduct(_ name: String) -> String? {
        var folders = [Bundle(for: Sandbox.self).bundleURL.deletingLastPathComponent(), Bundle.main.bundleURL, Bundle.main.bundleURL.deletingLastPathComponent()]
        if let first = CommandLine.arguments.first { folders.append(URL(fileURLWithPath: first).deletingLastPathComponent()) }
        for folder in folders {
            let path = folder.appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}
