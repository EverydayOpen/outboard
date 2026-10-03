import Foundation
import XCTest
@testable import OutboardCore

/// Shared builders for the Core suites (core owner). Every secret-looking value a test needs is built from pieces at runtime.
enum T {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15 08:00:00 UTC
    static let home = "/Users/jane"
    static let uuid = "3E1C0B7A-0000-4000-8000-000000000001"
    static let token = ["tok", "0001", "abcd"].joined(separator: "-")

    static func volumeRef(name: String = "Outboard") -> VolumeRef { VolumeRef(uuid: uuid, name: name, token: token) }

    /// An APFS SSD that passes every rule for every recipe: encrypted, marked, 480 GB free of 500.
    static func drive(name: String = "Outboard", uuid: String? = T.uuid, mutate: (inout DriveFacts) -> Void = { _ in }) -> DriveFacts {
        var d = DriveFacts(uuid: uuid, name: name, mountPoint: "/Volumes/\(name)", fileSystem: .apfs, fileSystemRaw: "apfs", bus: .usb, busRaw: "USB",
                           isLocal: true, isInternal: .no, isWritable: .yes, isSolidState: .yes, isEncrypted: .yes, ownershipHonoured: .yes,
                           supportsSymlinks: .yes, supportsHardLinks: .yes, isCaseSensitive: .no, smart: .notSupported,
                           capacityBytes: 500_000_000_000, availableBytes: 480_000_000_000, hasOutboardMarker: true, markerToken: T.token)
        mutate(&d)
        return d
    }

    static func recipe(_ id: String) -> Recipe { Catalogue.recipe(id)! }

    static func fingerprint(bytes: UInt64, files: Int = 100) -> TreeFingerprint {
        TreeFingerprint(files: files, directories: 10, symlinks: 0, logicalBytes: bytes, allocatedBytes: bytes)
    }

    static func scan(_ recipeID: String, path: String? = nil, bytes: UInt64, state: SizeState = .measured, isLink: Bool = false,
                     reason: NotMeasuredReason? = nil, mutate: (inout SizeScan) -> Void = { _ in }) -> SizeScan {
        let r = recipe(recipeID)
        var s = SizeScan(recipeID: recipeID, path: path ?? r.source ?? "~/x", state: state, reason: reason, fingerprint: fingerprint(bytes: bytes),
                         isLink: isLink, stamp: FileStamp(device: 16_777_234, inode: 88_123, type: .directory), measuredAt: t0)
        mutate(&s)
        return s
    }

    static func consent(for recipeID: String, report: EligibilityReport? = nil, unverifiedNote: Bool = true) -> ConsentRecord {
        let r = recipe(recipeID)
        let boxes = r.consent?.checkboxes.map(\.id) ?? []
        return ConsentRecord(recipeVersion: r.version, tickedIDs: boxes, ackIDs: report?.acks.map(\.ackID) ?? [], sawUnverifiedNote: unverifiedNote)
    }

    static func prior(for recipeID: String) -> [PriorValue] {
        if case .defaults(_, let keys, _) = recipe(recipeID).method { return keys.map { PriorValue(key: $0.name) } }
        return []
    }

    static func plan(_ recipeID: String = "ollama-models", bytes: UInt64 = 30_000_000_000, id: String = "20270115T080000Z-3fa9c1",
                     drive: DriveFacts? = nil, mutate: (inout MovePlan) -> Void = { _ in }) -> MovePlan {
        let r = recipe(recipeID)
        let d = drive ?? T.drive()
        let report = Eligibility.evaluate(volume: d, recipe: r, source: SourceNeeds(logicalBytes: bytes, isCaseSensitive: .no, hasHardLinks: false, hasSymlinks: true), policy: .release)
        let result = MovePlanner.plan(recipe: r, folder: scan(recipeID, bytes: bytes), drive: d, report: report, consent: consent(for: recipeID, report: report),
                                      prior: prior(for: recipeID), home: home, now: t0, moveID: id, groupID: nil,
                                      prefs: Preferences(showUnverifiedMoves: true))
        var p = result.plan!
        mutate(&p)
        return p
    }

    static func record(id: String = "20270115T080000Z-3fa9c1", recipeID: String = "ollama-models", state: MoveState = .swapped,
                       last: JournalMark = JournalMark(step: .swapped, phase: .result, status: .ok), method: MethodKind? = nil,
                       safety: SafetyCopyState = .kept, mutate: (inout RelocationRecord) -> Void = { _ in }) -> RelocationRecord {
        let r = recipe(recipeID)
        let m = method ?? r.kind
        var rec = RelocationRecord(
            id: id, recipeID: recipeID, recipeVersion: r.version, recipeName: r.name, method: m, risk: r.riskClass, onDriveMissing: r.onDriveMissing,
            state: state, macPath: r.source ?? "~/x", volume: volumeRef(), relativePath: "Outboard/\(recipeID)/\(MovePlanner.leafName(forSource: r.source ?? "x"))",
            logicalBytes: 30_000_000_000, fileCount: 1200, safetyCopy: safety, last: last, createdAt: t0, updatedAt: t0)
        if m == .defaults {
            rec.defaultsDomain = "com.apple.dt.Xcode"
            rec.defaultsWrites = [DefaultsWrite(key: "IDECustomDerivedDataLocation", type: .string, value: "/Volumes/Outboard/Outboard/\(recipeID)/DerivedData")]
            rec.defaultsRevert = [DefaultsWrite(key: "IDEDerivedDataPathMode", type: .int, value: "0")]
        }
        mutate(&rec)
        return rec
    }

    static func line(_ id: String = "m1", _ seq: Int, _ phase: JournalPhase, _ step: MoveStep, status: StepStatus? = nil, state: MoveState? = nil,
                     at: Double = 0, mutate: (inout JournalEntry) -> Void = { _ in }) -> JournalEntry {
        var e = JournalEntry(id: id, seq: seq, ts: t0.addingTimeInterval(at), phase: phase, step: step, recipe: "ollama-models@1", state: state, status: status)
        mutate(&e)
        return e
    }

    /// The begin line for a plan.
    static func begin(_ plan: MovePlan, seq: Int = 1, at: Double = 0) -> JournalEntry {
        let jp = MovePlanner.journalPlan(plan, onDriveMissing: T.recipe(plan.recipeID).onDriveMissing, volume: volumeRef(), fileCount: plan.sourceFingerprint.files, home: home)
        return JournalEntry(id: plan.id, seq: seq, ts: t0.addingTimeInterval(at), phase: .intent, step: .begin, recipe: "\(plan.recipeID)@\(plan.recipeVersion)",
                            state: .planned, plan: jp)
    }

    /// Every line a move to the drive writes, in order, with the states the Mac layer sets (`upTo` cuts the list after the last line of that step).
    static func journal(_ plan: MovePlan, upTo last: MoveStep? = nil, mac: String = "~/.ollama/models") -> [JournalEntry] {
        let rid = "\(plan.recipeID)@\(plan.recipeVersion)"
        var seq = 1
        var lines: [JournalEntry] = [begin(plan, seq: 1)]
        func add(_ phase: JournalPhase, _ step: MoveStep, status: StepStatus? = nil, state: MoveState? = nil, _ mutate: (inout JournalEntry) -> Void = { _ in }) {
            seq += 1
            var e = JournalEntry(id: plan.id, seq: seq, ts: t0.addingTimeInterval(Double(seq) * 60), phase: phase, step: step, recipe: rid, state: state, status: status)
            mutate(&e)
            lines.append(e)
        }
        add(.intent, .preflight, state: .preflight)
        add(.result, .preflight, status: .ok) { $0.counts = JournalCounts(checksPassed: 14, checksTotal: 14, freeBytes: 480_000_000_000); $0.volName = "Outboard"; $0.fsName = "APFS" }
        add(.intent, .copy, state: .copying) { $0.counts = JournalCounts(files: 100, bytes: plan.logicalBytes); $0.volName = "Outboard" }
        add(.result, .copy, status: .ok)
        add(.intent, .verify, state: .verifying)
        add(.result, .verify, status: .ok) { $0.verification = VerificationSummary(filesCompared: 100, bytesCompared: plan.logicalBytes, differences: 0, manifestDigest: "d", completedAt: t0) }
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

    static func stripSpaces(_ s: String) -> String { s.replacingOccurrences(of: "\n", with: " ") }
}

extension XCTestCase {
    /// Compares `actual` with `Tests/OutboardCoreTests/Fixtures/<dir>/<name>`. With `OUTBOARD_GOLDEN_OUT` set (a directory) the file is written
    /// there instead, so a Docker run can hand the regenerated golden files back to the working tree.
    func golden(_ dir: String, _ name: String, _ actual: String, file: StaticString = #filePath, line: UInt = #line) {
        if let out = ProcessInfo.processInfo.environment["OUTBOARD_GOLDEN_OUT"], !out.isEmpty {
            let folder = URL(fileURLWithPath: out).appendingPathComponent(dir)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? actual.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
            return
        }
        let url = URL(fileURLWithPath: "\(file)").deletingLastPathComponent().appendingPathComponent("Fixtures/\(dir)/\(name)")
        guard let expected = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("Missing golden file Fixtures/\(dir)/\(name). Regenerate with OUTBOARD_GOLDEN_OUT.", file: file, line: line)
            return
        }
        XCTAssertEqual(actual, expected, "Golden file Fixtures/\(dir)/\(name) is out of date. Regenerate with OUTBOARD_GOLDEN_OUT.", file: file, line: line)
    }

    /// The repo root, for the tests that read `tools/` and `Sources/`.
    var repoRoot: URL {
        URL(fileURLWithPath: "\(#filePath)").deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}
