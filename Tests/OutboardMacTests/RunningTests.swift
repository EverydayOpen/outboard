import Darwin
import Foundation
import XCTest
import OutboardCore
@testable import OutboardMac

/// The running check against real processes: a copy of the tiny `OutboardFixture` executable is run from inside a fake `Foo.app`
/// bundle, and the check must see it by name; a child that holds a file open under a folder must be named as a holder.
final class RunningTests: MacTestCase {
    private var children: [Process] = []

    override func tearDown() {
        for p in children where p.isRunning {
            p.terminate()
            p.waitUntilExit()
        }
        children = []
        super.tearDown()
    }

    private func launch(_ sb: Sandbox, as path: String, output: FileHandle? = nil) throws -> Process {
        let source = builtProduct("OutboardFixture") ?? "/bin/sleep"
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: source, toPath: path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["120"]
        if let output { process.standardOutput = output }
        try process.run()
        children.append(process)
        Thread.sleep(forTimeInterval: 0.4)
        // A copied system binary may not run outside the system volume: skip rather than fail.
        guard process.isRunning else { throw XCTSkip("could not start a helper process from \(source)") }
        return process
    }

    private func recipe(processName: String) -> Recipe {
        var r = Catalogue.recipe("npm-cache")!
        r.bundleIDs = []
        r.processNames = [processName]
        return r
    }

    func testAProcessRunningFromInsideABundleIsSeenByName() throws {
        let sb = try makeSandbox()
        guard Processes.names()?.contains("launchd") == true else { throw XCTSkip("the process list cannot be read here") }
        _ = try launch(sb, as: sb.home + "/Applications/Foo.app/Contents/MacOS/Foo")
        let names = try XCTUnwrap(Processes.names())
        XCTAssertTrue(names.contains("Foo"))
        let r = recipe(processName: "Foo")
        let snapshot = RunningApps.snapshot(for: r, home: sb.home, includeHandles: false)
        XCTAssertTrue(snapshot.readable)
        XCTAssertEqual(RunningCheck.state(recipe: r, snapshot: snapshot), .running)
        XCTAssertEqual(RunningCheck.state(recipe: recipe(processName: "NoSuchProcessXyz"), snapshot: snapshot), .notRunning)
    }

    func testAnUnreadableProcessListBlocksInsteadOfPassing() {
        let snapshot = RunningSnapshot(readable: false)
        XCTAssertEqual(RunningCheck.state(recipe: recipe(processName: "Foo"), snapshot: snapshot), .unknown)
    }

    func testAChildHoldingAFileOpenUnderAFolderIsNamedAsAHolder() throws {
        let sb = try makeSandbox()
        guard Processes.names()?.contains("launchd") == true else { throw XCTSkip("the process list cannot be read here") }
        let folder = sb.dir(".npm")
        let file = sb.put(".npm/log.txt", bytes: 0)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: file))
        defer { handle.closeFile() }
        _ = try launch(sb, as: sb.home + "/bin/holder", output: handle)
        guard let holders = Processes.openHandleHolders(under: folder) else { throw XCTSkip("open handles cannot be listed here") }
        if holders.isEmpty { throw XCTSkip("this session may not look at another process's file descriptors") }
        XCTAssertTrue(holders.contains("holder"), "got \(holders)")
        XCTAssertFalse(Processes.openHandleHolders(under: sb.dir("elsewhere"))?.contains("holder") ?? false)
        // This test process holds nothing under the folder once the handle is closed, and it is never named.
        XCTAssertFalse(holders.contains(ProcessInfo.processInfo.processName))
    }

    /// A rollback the user asked for while the app runs is refused before it writes anything. If it wrote a `rollback` line, the next
    /// launch would read it as a rollback that was started and finish it, undoing a move the user had only tried to undo.
    func testARollbackRefusedBecauseTheAppRunsWritesNothingAndRecoveryLeavesTheMoveAlone() throws {
        let sb = try makeSandbox()
        guard Processes.names()?.contains("launchd") == true else { throw XCTSkip("the process list cannot be read here") }
        let layout = try Fixtures.swapped(sb)
        _ = try launch(sb, as: sb.home + "/bin/npm")
        guard Processes.names()?.contains("npm") == true else { throw XCTSkip("the helper process is not listed here") }
        let record = try XCTUnwrap(Fixtures.currentRecord(sb))
        let before = Journal.loadAll(home: sb.home).count

        let outcome = Rollback.run(record, home: sb.home)
        XCTAssertFalse(outcome.ok)
        XCTAssertTrue(outcome.message.contains("running"), outcome.message)
        XCTAssertEqual(Journal.loadAll(home: sb.home).count, before, "a refused rollback adds no line")

        children.forEach { $0.terminate(); $0.waitUntilExit() }
        children = []
        let recovered = Recover.run(home: sb.home)
        XCTAssertTrue(recovered.isEmpty, "nothing to finish: \(recovered.map(\.message))")
        XCTAssertEqual(Fs.kind(Fs.info(layout.macPath).st), .symlink, "the redirect is still in place")
        XCTAssertTrue(sb.exists(layout.beforePath), "the safety copy is still there")
        XCTAssertEqual(Fixtures.currentRecord(sb)?.state, .swapped)
    }
}
