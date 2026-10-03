import Darwin
import Foundation
import XCTest
import OutboardCore
@testable import OutboardMac

final class JournalTests: MacTestCase {
    private let subject = JournalSubject(moveID: Fixtures.moveID, recipe: "npm-cache@1")

    private func currentFile(_ sb: Sandbox) -> String {
        Journal.directory(home: sb.home) + "/" + ActivityLog.fileName(for: Date())
    }

    func testFolderIs0700AndFileIs0600() throws {
        let sb = try makeSandbox()
        XCTAssertTrue(Journal.intent(.preflight, subject: subject, home: sb.home))
        XCTAssertEqual(sb.mode(Journal.directory(home: sb.home)), 0o700)
        XCTAssertEqual(sb.mode(currentFile(sb)), 0o600)
    }

    func testLinesAppendInOrderAndSequenceCounts() throws {
        let sb = try makeSandbox()
        XCTAssertTrue(Journal.intent(.copy, subject: subject, home: sb.home, src: sb.home + "/.npm", state: .copying))
        XCTAssertTrue(Journal.result(.copy, subject: subject, home: home(sb), status: .ok))
        XCTAssertTrue(Journal.intent(.verify, subject: subject, home: sb.home, state: .verifying))
        let all = lines(sb)
        XCTAssertEqual(steps(all), ["copy.intent", "copy.result", "verify.intent"])
        XCTAssertEqual(all.map(\.seq), [1, 2, 3])
        XCTAssertEqual(all.first?.recipe, "npm-cache@1")
    }

    private func home(_ sb: Sandbox) -> String { sb.home }

    func testPathsAreStoredWithTilde() throws {
        let sb = try makeSandbox()
        XCTAssertTrue(Journal.intent(.setAside, subject: subject, home: sb.home, src: sb.home + "/.npm", to: sb.home + "/.npm.before-move"))
        let line = try XCTUnwrap(lines(sb).first)
        XCTAssertEqual(line.src, "~/.npm")
        XCTAssertEqual(line.to, "~/.npm.before-move")
        let raw = try XCTUnwrap(sb.read(currentFile(sb)))
        XCTAssertFalse(raw.contains(sb.home), "the file must not carry the home folder")
    }

    func testBeginWritesThePlanAndFoldsToARecord() throws {
        let sb = try makeSandbox()
        sb.dir(".npm")
        let plan = Fixtures.plan(sb)
        XCTAssertTrue(Journal.begin(plan, onDriveMissing: .parkPlaceholder, volume: Fixtures.volumeRef(), home: sb.home, at: Fixtures.t0))
        let record = try XCTUnwrap(RelocationFold.records(from: Journal.loadAll(home: sb.home)).first)
        XCTAssertEqual(record.id, plan.id)
        XCTAssertEqual(record.state, .planned)
        XCTAssertEqual(record.macPath, "~/.npm")
        XCTAssertEqual(record.relativePath, plan.destination.relativePath)
    }

    func testASymlinkedFolderIsRefused() throws {
        let sb = try makeSandbox()
        let elsewhere = sb.dir("elsewhere")
        try FileManager.default.createDirectory(atPath: sb.home + "/Library/Application Support", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: Journal.directory(home: sb.home), withDestinationPath: elsewhere)
        XCTAssertFalse(Journal.prepare(home: sb.home))
        XCTAssertFalse(Journal.intent(.preflight, subject: subject, home: sb.home), "nothing is written through a link")
        XCTAssertEqual(sb.names(in: "elsewhere"), [])
    }

    func testAFolderWithAnotherModeIsNeverChmodedBack() throws {
        let sb = try makeSandbox()
        try FileManager.default.createDirectory(atPath: Journal.directory(home: sb.home), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        XCTAssertFalse(Journal.prepare(home: sb.home))
        XCTAssertEqual(sb.mode(Journal.directory(home: sb.home)), 0o755)
    }

    func testASymlinkedFileIsRefused() throws {
        let sb = try makeSandbox()
        XCTAssertTrue(Journal.prepare(home: sb.home))
        let decoy = sb.put("decoy.txt")
        try FileManager.default.createSymbolicLink(atPath: currentFile(sb), withDestinationPath: decoy)
        XCTAssertFalse(Journal.intent(.preflight, subject: subject, home: sb.home))
        XCTAssertEqual(sb.read(decoy), String(repeating: "A", count: 100), "the file behind the link is untouched")
    }

    func testAnUnwritableJournalMeansNothingIsWritten() throws {
        let sb = try makeSandbox()
        XCTAssertTrue(Journal.prepare(home: sb.home))
        XCTAssertEqual(chmod(Journal.directory(home: sb.home), 0o500), 0)
        defer { chmod(Journal.directory(home: sb.home), 0o700) }
        // The folder now has the wrong mode: fail closed, whatever the reason.
        XCTAssertFalse(Journal.isWritable(home: sb.home))
        XCTAssertFalse(Journal.intent(.preflight, subject: subject, home: sb.home))
    }

    func testATornLastLineIsIgnoredAndTheNextLineIsNotGluedToIt() throws {
        let sb = try makeSandbox()
        XCTAssertTrue(Journal.intent(.preflight, subject: subject, home: sb.home, state: .preflight))
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: currentFile(sb)))
        handle.seekToEndOfFile()
        handle.write(Data("{\"v\":1,\"id\":\"torn\"".utf8))
        handle.closeFile()
        XCTAssertTrue(Journal.intent(.copy, subject: subject, home: sb.home, state: .copying))
        let all = Journal.loadAll(home: sb.home)
        XCTAssertEqual(steps(all.filter { $0.id == Fixtures.moveID }), ["preflight.intent", "copy.intent"])
        XCTAssertFalse(all.contains { $0.id == "torn" })
    }

    func testSequenceCountsPerMove() throws {
        let sb = try makeSandbox()
        XCTAssertTrue(Journal.intent(.preflight, subject: subject, home: sb.home))
        XCTAssertTrue(Journal.intent(.copy, subject: subject, home: sb.home))
        // Each move id counts its own lines.
        let other = JournalSubject(moveID: "20270115T090000Z-aaaaaa", recipe: "npm-cache@1")
        XCTAssertTrue(Journal.intent(.preflight, subject: other, home: sb.home))
        XCTAssertEqual(lines(sb, other.moveID).map(\.seq), [1])
        XCTAssertEqual(lines(sb).map(\.seq), [1, 2])
    }

    func testResultLinesCarryStatusStampAndNote() throws {
        let sb = try makeSandbox()
        let stamp = FileStamp(device: 1, inode: 2, type: .directory)
        XCTAssertTrue(Journal.result(.park, subject: subject, home: sb.home, status: .failed, errno: Int32(EPERM), stamp: stamp, note: "x"))
        let line = try XCTUnwrap(lines(sb).first)
        XCTAssertEqual(line.phase, .result)
        XCTAssertEqual(line.status, .failed)
        XCTAssertEqual(line.errno, Int32(EPERM))
        XCTAssertEqual(line.stamp, stamp)
        XCTAssertTrue(line.isProblem)
    }

    func testNoFileContentsOrArgumentsAreEverWritten() throws {
        let sb = try makeSandbox()
        let secret = sb.put(".npm/token.txt", bytes: 20, fill: 0x53)
        XCTAssertTrue(Journal.intent(.setAside, subject: subject, home: sb.home, src: sb.home + "/.npm"))
        let raw = try XCTUnwrap(sb.read(currentFile(sb)))
        XCTAssertFalse(raw.contains("SSSS"))
        XCTAssertFalse(raw.contains(secret))
    }
}
