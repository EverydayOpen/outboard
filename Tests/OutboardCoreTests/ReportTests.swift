import Foundation
import XCTest
@testable import OutboardCore

final class ReportTests: XCTestCase {
    private let now = T.t0.addingTimeInterval(86_400 * 3)

    private func options(hide: Bool = false, sample: Bool = false) -> ReportOptions {
        ReportOptions(hidePaths: hide, appVersion: "1.0.0", macOSVersion: "26.0", macModel: "Mac14,12", now: now, isSample: sample)
    }

    /// A move that finished, one that stopped on a mismatch, and one that is waiting for a decision.
    private func fixture() -> (records: [RelocationRecord], log: [JournalEntry]) {
        let done = T.plan("ollama-models", id: "20270115T080000Z-3fa9c1")
        var log = T.journal(done)
        let stopped = T.plan("npm-cache", bytes: 2_000_000_000, id: "20270116T090000Z-bbbbbb")
        log.append(T.begin(stopped, seq: 1, at: 100_000))
        log.append(T.line(stopped.id, 2, .result, .verify, status: .mismatch, at: 100_100) { $0.verification = VerificationSummary(filesCompared: 900, bytesCompared: 1_999_000_000, differences: 2, completedAt: T.t0) })
        log.append(T.line(stopped.id, 3, .result, .abort, status: .ok, state: .aborted, at: 100_200) { $0.abort = .mismatch })
        let waiting = T.plan("xcode-deriveddata", bytes: 41_000_000_000, id: "20270117T100000Z-cccccc")
        log += T.journal(waiting, upTo: .swapped, mac: "~/Library/Developer/Xcode/DerivedData").enumerated().map { (i, e) in
            var line = e
            line.ts = T.t0.addingTimeInterval(200_000 + Double(i) * 60)
            return line
        }
        return (RelocationFold.records(from: log), log)
    }

    func testTheOpenLineSaysOnlyHowTheDriveLeftThatWasSeen() {
        let pulled = T.record(id: "a1", state: .confirmed) { $0.needsCheckBeforeReconnect = true; $0.removalKind = .unclean }
        let unseen = T.record(id: "b1", state: .confirmed) { $0.needsCheckBeforeReconnect = true; $0.removalKind = .unknown }
        let doc = ReportText.document(records: [pulled, unseen], log: [], drives: [], options: options())
        let open = doc.relocations.map(\.unresolved)
        XCTAssertEqual(doc.relocations.count, 2)
        let lines = doc.relocations.flatMap(\.unresolved)
        XCTAssertTrue(lines.contains("The drive was removed without ejecting; Check and reconnect is needed before it is reconnected."), "\(open)")
        XCTAssertTrue(lines.contains("The drive was not connected when Outboard looked, and Outboard didn't see how it was removed; Check and reconnect is needed before it is reconnected."), "\(open)")
        for line in lines { XCTAssertEqual(BannedPhrases.hits(in: line), [], line) }
    }

    func testTheDocumentAndBothRenderingsAreGolden() throws {
        let (records, log) = fixture()
        XCTAssertEqual(records.count, 3)
        let doc = ReportText.document(records: records, log: log, drives: [T.drive()], options: options())
        golden("reports", "report.md", ReportText.markdown(doc))
        golden("reports", "report.json", ReportText.json(doc))
        let hidden = ReportText.document(records: records, log: log, drives: [T.drive()], options: options(hide: true))
        golden("reports", "report-hidden.md", ReportText.markdown(hidden))
        golden("reports", "report-sample.md", ReportText.markdown(ReportText.document(records: [], log: [], drives: [], options: options(sample: true))))

        XCTAssertEqual(doc.schema, 1)
        XCTAssertEqual(doc.provenance, "Generated on this Mac. Not uploaded.")
        XCTAssertEqual(doc.footer, "This report lists what Outboard did and checked. It does not show that your data is undamaged or that a drive is reliable. Outboard has not been tried on every Mac or every drive.")
        XCTAssertEqual(ReportText.footer, doc.footer)
        XCTAssertEqual(doc.drives, [ReportDrive(name: "Outboard", uuidPrefix: "3E1C0B7A", format: "APFS", encrypted: .yes, firstUsed: T.t0)])
        XCTAssertEqual(doc.relocations.map(\.recipeID), ["ollama-models", "npm-cache", "xcode-deriveddata"], "oldest first")
        XCTAssertEqual(doc.relocations[0].state, .originalTrashed)
        XCTAssertEqual(doc.relocations[1].state, .aborted)
        XCTAssertEqual(doc.relocations[2].unresolved, ["Waiting for you to try the app and confirm."])
        XCTAssertTrue(doc.problems.contains { $0.contains("Compared 900 files by size and SHA-256: 2 differences found") })
        XCTAssertEqual(doc.relocations[0].timeline.count, 11)
        // the report claims nothing it was not told
        XCTAssertNil(doc.relocations[2].health)
    }

    func testHidingPathsLeavesNoFolderNameInSourceOrDestination() {
        let (records, log) = fixture()
        let hidden = ReportText.document(records: records, log: log, drives: [], options: options(hide: true))
        for r in hidden.relocations {
            XCTAssertEqual(r.source, r.recipeName)
            XCTAssertFalse(r.destination.contains("Outboard/"), r.destination)
        }
        let open = ReportText.document(records: records, log: log, drives: [], options: options())
        XCTAssertEqual(open.relocations[0].source, "~/.ollama/models")
        XCTAssertEqual(open.relocations[0].destination, "Outboard drive: Outboard/ollama-models/models")
        XCTAssertEqual(open.drives.first?.format, "not connected", "a drive that isn't there is not described")
    }

    func testTheMarkdownCarriesOnlyWhatWasDoneAndChecked() {
        let (records, log) = fixture()
        let md = ReportText.markdown(ReportText.document(records: records, log: log, drives: [T.drive()], options: options()))
        XCTAssertTrue(md.hasPrefix("# Outboard report\n"))
        XCTAssertTrue(md.contains("Generated on this Mac. Not uploaded."))
        XCTAssertTrue(md.contains("- Compared: 100 files (30 GB) by size and SHA-256, 0 differences; the copy on the drive was read without the page cache."))
        XCTAssertTrue(md.hasSuffix(ReportText.footer + "\n"))
        XCTAssertEqual(BannedPhrases.hits(in: md), [])
        XCTAssertFalse(md.contains("/Users/"), "no personal paths")
        let sample = ReportText.markdown(ReportText.document(records: [], log: [], drives: [], options: options(sample: true)))
        XCTAssertTrue(sample.contains("Sample data"))
        XCTAssertTrue(sample.contains("Nothing has been moved."))
        XCTAssertTrue(sample.contains("None recorded."))
    }

    func testTheJSONIsValidSortedAndCompleteWithSchemaOne() throws {
        let (records, log) = fixture()
        let json = ReportText.json(ReportText.document(records: records, log: log, drives: [T.drive()], options: options()))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["schema"] as? Int, 1)
        XCTAssertEqual(obj["generatedAt"] as? String, "2027-01-18T08:00:00Z")
        XCTAssertEqual((obj["relocations"] as? [[String: Any]])?.count, 3)
        XCTAssertEqual(obj["footer"] as? String, ReportText.footer)
        XCTAssertEqual(obj["isSample"] as? Bool, false)
        let first = (obj["relocations"] as? [[String: Any]])?.first
        XCTAssertEqual((first?["verification"] as? [String: Any])?["filesCompared"] as? Int, 100)
        XCTAssertEqual((first?["timeline"] as? [[String: Any]])?.count, 11)
        let keys = json.components(separatedBy: "\n").filter { $0.hasPrefix("  \"") }.map { $0.dropFirst(3).prefix { $0 != "\"" } }
        XCTAssertEqual(keys.map(String.init), keys.map(String.init).sorted(), "top-level keys are sorted")
        XCTAssertEqual(json, ReportText.json(ReportText.document(records: records, log: log, drives: [T.drive()], options: options())), "deterministic")
    }

    func testHealthWordsAreOnlyWhatTheCallerGaveOrTheJournalShows() {
        let (records, log) = fixture()
        var parked = records
        parked[parked.firstIndex { $0.recipeID == "ollama-models" }!].isParked = true
        let doc = ReportText.document(records: parked, log: log, drives: [], options: options())
        XCTAssertEqual(doc.relocations[0].health, "Drive away")
        let given = ReportText.document(records: records, log: log, drives: [], options: options(), health: [records.first { $0.recipeID == "ollama-models" }!.id: .healthy])
        XCTAssertEqual(given.relocations[0].health, "Healthy")
    }
}
