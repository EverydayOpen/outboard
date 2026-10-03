import Darwin
import Foundation
import XCTest
import OutboardCore
@testable import OutboardMac

final class PlaceholderTests: MacTestCase {
    private let subject = JournalSubject(moveID: Fixtures.moveID, recipe: "npm-cache@1")

    func testTheNoteIsReadOnlyFromTheMomentItExists() throws {
        let sb = try makeSandbox()
        let path = sb.home + "/.npm"
        guard case .created(let stamp) = Placeholder.create(at: path, driveName: "Outboard", removal: .ejected, subject: subject, home: sb.home) else {
            return XCTFail("expected the note to be created")
        }
        XCTAssertEqual(sb.mode(path), 0o444)
        XCTAssertEqual(stamp.type, .file)
        XCTAssertEqual(sb.read(path), PlaceholderText.body(driveName: "Outboard"))
        XCTAssertLessThanOrEqual(stamp.size, UInt64(Limits.placeholderMaxBytes))
    }

    func testAnExistingFolderOrFileIsNeverOverwritten() throws {
        let sb = try makeSandbox()
        sb.put(".npm/keep.bin", bytes: 7)
        guard case .refused = Placeholder.create(at: sb.home + "/.npm", driveName: "Outboard", removal: .unknown, subject: subject, home: sb.home) else {
            return XCTFail("a folder at the path must be refused")
        }
        XCTAssertEqual(sb.names(in: ".npm"), ["keep.bin"])
        let file = sb.put("note.txt", bytes: 5, fill: 0x42)
        guard case .refused = Placeholder.create(at: file, driveName: "Outboard", removal: .unknown, subject: subject, home: sb.home) else {
            return XCTFail("a file at the path must be refused")
        }
        XCTAssertEqual(sb.read(file), "BBBBB")
        XCTAssertTrue(lines(sb).isEmpty, "a refused note writes no journal line")
    }

    func testTheJournalHasTheIntentFirstAndTheStampAfter() throws {
        let sb = try makeSandbox()
        let path = sb.home + "/.npm"
        guard case .created(let stamp) = Placeholder.create(at: path, driveName: "Outboard", removal: .unclean, subject: subject, home: sb.home) else {
            return XCTFail("expected the note to be created")
        }
        let all = lines(sb)
        XCTAssertEqual(steps(all), ["park.intent", "park.result"])
        XCTAssertEqual(all.last?.stamp, stamp)
        XCTAssertTrue((all.last?.note ?? "").hasPrefix(JournalNote.placeholder))
        XCTAssertTrue((all.last?.note ?? "").contains("unclean"))
        let facts = JournalFacts(moveID: Fixtures.moveID, all: Journal.loadAll(home: sb.home), home: sb.home)
        XCTAssertEqual(facts.lastPlaceholder, stamp)
        XCTAssertEqual(facts.lastRemoval, .unclean)
    }

    func testNothingIsCreatedWhenTheJournalCannotTakeTheIntent() throws {
        let sb = try makeSandbox()
        XCTAssertTrue(Journal.prepare(home: sb.home))
        XCTAssertEqual(chmod(Journal.directory(home: sb.home), 0o500), 0)
        defer { chmod(Journal.directory(home: sb.home), 0o700) }
        let path = sb.home + "/.npm"
        guard case .notAttempted = Placeholder.create(at: path, driveName: "Outboard", removal: .unknown, subject: subject, home: sb.home) else {
            return XCTFail("expected notAttempted")
        }
        XCTAssertFalse(sb.exists(path))
    }
}
