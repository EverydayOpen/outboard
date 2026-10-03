import Foundation
import XCTest
@testable import OutboardCore

final class TextTests: XCTestCase {
    // MARK: banned phrases

    func testThePatternsEqualTheFileTheGrepReads() throws {
        let text = try String(contentsOf: repoRoot.appendingPathComponent("tools/banned_phrases.txt"), encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        XCTAssertEqual(BannedPhrases.patterns, lines)
        XCTAssertGreaterThan(lines.count, 40)
    }

    func testBannedPhrasesCatchTheSpecsExamplesAndSpareHonestCopy() {
        for bad in ["Safe to unplug", "Safely eject your drive", "100% safe", "We guarantee it", "no data loss", "never lose a file", "Your files stay intact", "Runs faster from an SSD",
                    "Speeds up Xcode", "works like internal storage", "use an external SSD as internal", "Automatically moves new apps", "Auto-configure new installs", "fully reversible",
                    "a verified backup of your data", "Tested on macOS 26", "Move in one click", "This is risk-free", "Apple-approved", "expands your storage", "It will boost your builds"] {
            XCTAssertFalse(BannedPhrases.hits(in: bad).isEmpty, bad)
        }
        for good in ["Your original is kept as DerivedData.before-move until you confirm.", "Eject the drive in Finder first.", "Compared 48,211 files by size and SHA-256: 0 differences.",
                     "Not yet tried on a real Mac.", "Safety copies still on this Mac: 41 GB until you confirm.", "macOS protects this folder.", "Measured on this Mac. Nothing was moved.",
                     "Outboard drive was ejected. Plug it back in and we'll put things back.", "Outboard can't make unplugging a drive harmless."] {
            XCTAssertEqual(BannedPhrases.hits(in: good), [], good)
        }
        XCTAssertEqual(BannedPhrases.hits(in: "It is safe  no-claim-ok"), [], "the marker names a phrase only to disclaim it")
        XCTAssertEqual(BannedPhrases.hits(in: "line one\nsafe\nline three"), ["safe"])
    }

    // MARK: the consent sheet

    private func sheet(_ recipeID: String, bytes: UInt64 = 30_000_000_000, drive: DriveFacts? = nil, unverified: Bool = true) -> ConsentSheet {
        let r = T.recipe(recipeID)
        let d = drive ?? T.drive()
        let report = Eligibility.evaluate(volume: d, recipe: r, source: SourceNeeds(logicalBytes: bytes, isCaseSensitive: .no), policy: .release)
        return ConsentSheetText.sheet(recipe: r, scan: T.scan(recipeID, bytes: bytes), drive: T.volumeRef(name: d.name), mountPoint: d.mountPoint, report: report, free: 45_000_000_000, unverified: unverified)
    }

    func testTheConsentSheetsAreTheSpecs() {
        let o = sheet("ollama-models")
        XCTAssertEqual(o.title, "Move your Ollama models to Outboard drive?")
        XCTAssertEqual(o.subtitle, "30 GB \u{00B7} Community method \u{00B7} Large to download again")
        XCTAssertEqual(o.unverifiedLine, "Not yet tried on a real Mac.")
        XCTAssertEqual(o.moveButtonTitle, "Move 30 GB")
        XCTAssertEqual(o.cancelButtonTitle, "Cancel")
        XCTAssertFalse(o.cancelIsDefault)
        XCTAssertEqual(o.envLine, "export OLLAMA_MODELS='/Volumes/Outboard/Outboard/ollama-models/models'")
        XCTAssertEqual(o.relaunchNote, "Ollama can restart by itself. Quit it from its menu bar icon and wait for its row above to say Not running.")
        XCTAssertEqual(o.permissionNote, "macOS may ask Ollama for permission to use the drive the first time.")
        XCTAssertEqual(o.footerLink, "What happens if I unplug the drive?")
        XCTAssertEqual(o.checkboxes.map(\.id), ["quit-ollama", "models-away"])
        XCTAssertNil(sheet("ollama-models", unverified: false).unverifiedLine)

        let x = sheet("xcode-deriveddata", bytes: 41_000_000_000)
        XCTAssertEqual(x.title, "Move Xcode's build data to Outboard drive?")
        XCTAssertEqual(x.subtitle, "41 GB \u{00B7} Official setting \u{00B7} Rebuilds itself")
        XCTAssertEqual(x.moveButtonTitle, "Move 41 GB")
        XCTAssertNil(x.envLine)
        XCTAssertNil(x.relaunchNote)

        let b = sheet("ios-device-backups", bytes: 16_000_000_000, drive: T.drive { $0.isEncrypted = .no })
        XCTAssertTrue(b.cancelIsDefault, "Cancel is the default for a recipe that can't be replaced")
        XCTAssertEqual(b.checkboxes.map(\.id), ["device-disconnected", "backups-on-drive-only", "community-method", "ack-e16"])
        XCTAssertEqual(b.checkboxes.last?.text, "This drive isn't encrypted. I understand anyone with the drive can read what is on it.")
        XCTAssertEqual(sheet("ios-device-backups", drive: T.drive { $0.isEncrypted = .unknown }).checkboxes.last?.text,
                       "We couldn't tell whether this drive is encrypted. Tick to confirm you accept that.")
        XCTAssertEqual(sheet("ios-device-backups").checkboxes.count, 3, "an encrypted drive adds no acknowledgement")
        XCTAssertEqual(sheet("ollama-models", drive: T.drive(name: "Backup SSD")).title, "Move your Ollama models to Backup SSD?")
        XCTAssertEqual(sheet("ollama-models", drive: T.drive(name: "Backup SSD")).envLine, "export OLLAMA_MODELS='/Volumes/Backup SSD/Outboard/ollama-models/models'")
        XCTAssertEqual(sheet("photos-library", bytes: 1).whatToKnow, [], "a guided card has no consent sheet")
    }

    func testTheSheetSaysTheGuardActsOnlyWhileOutboardRuns() {
        for r in Catalogue.automated {
            let s = sheet(r.id, bytes: 5_000_000_000)
            let acts = r.onDriveMissing == .parkPlaceholder || r.onDriveMissing == .revertSetting
            XCTAssertEqual(s.whatToKnow.filter { $0 == ConsentSheetText.guardOnlyWhileRunning }.count, acts ? 1 : 0, r.id)
            if acts {
                // the recipe's own unplug bullet starts the claim, the fixed bullet follows it directly
                let at = s.whatToKnow.firstIndex { $0.contains(ConsentSheetText.whileRunningPhrase) }
                XCTAssertNotNil(at, r.id)
                XCTAssertEqual(at.map { s.whatToKnow[$0 + 1] }, ConsentSheetText.guardOnlyWhileRunning, r.id)
            }
            XCTAssertEqual(BannedPhrases.hits(in: s.whatToKnow.joined(separator: "\n")), [], r.id)
        }
        XCTAssertTrue(ConsentSheetText.guardOnlyWhileRunning.contains("only while it is running"))
        XCTAssertTrue(ConsentSheetText.guardOnlyWhileRunning.contains("until you open Outboard"))
        // Xcode: a running Xcode blocks the setting from being put back, and the sheet says so
        XCTAssertTrue(sheet("xcode-deriveddata").whatToKnow.joined(separator: " ").contains("If Xcode is open when the drive is unplugged, the setting is not changed until you quit Xcode"))
    }

    func testTheLedgerAlwaysShowsThreeLines() {
        let drive = T.volumeRef()
        let before = ConsentSheetText.ledger(bytes: 41_000_000_000, drive: drive, free: 45_000_000_000, state: .planned, leaf: "DerivedData")
        XCTAssertEqual(before, [
            LedgerLine(label: "On Outboard drive after the move", amount: "41 GB", note: "Outboard drive has 45 GB free now"),
            LedgerLine(label: "Still on your Mac", amount: "41 GB", note: "as DerivedData.before-move, until you confirm"),
            LedgerLine(label: "Back on your Mac's storage", amount: "0 GB", note: "after you confirm and empty the Trash"),
        ])
        let after = ConsentSheetText.ledger(bytes: 41_000_000_000, drive: drive, free: 45_000_000_000, state: .originalTrashed, leaf: "DerivedData")
        XCTAssertEqual(after.map(\.label), ["On Outboard drive", "In the Trash", "Back on your Mac's storage"])
        XCTAssertEqual(after[1].amount, "41 GB")
        XCTAssertEqual(after[2].note, "after you empty the Trash")
        XCTAssertEqual(ConsentSheetText.ledger(bytes: 1, drive: drive, free: 1, state: .aborted), [])
        XCTAssertTrue(ConsentSheetText.ledger(bytes: 1, drive: drive, free: 1, state: .planned)[1].note.contains(".before-move"))
    }

    func testTheConfirmDialog() {
        let derived = T.record(recipeID: "xcode-deriveddata", state: .swapped, method: .defaults) { $0.logicalBytes = 41_000_000_000 }
        let d = ConsentSheetText.confirmDialog(record: derived)
        XCTAssertEqual(d.title, "Use the move for good?")
        XCTAssertEqual(d.body, "Xcode's build data is now on Outboard drive. Your original is still on this Mac as DerivedData.before-move (41 GB). Confirming does two things: it ends the option to roll back, and it moves the original to the Trash. Your Mac gets the space back when you empty the Trash.")
        XCTAssertEqual(d.checkboxText, "I opened Xcode and my data is there.")
        XCTAssertEqual(d.cancelTitle, "Not yet")
        XCTAssertEqual(d.confirmTitle, "Confirm and move to Trash")
        XCTAssertTrue(d.confirmIsDefault)
        let ollama = ConsentSheetText.confirmDialog(record: T.record(recipeID: "ollama-models"))
        XCTAssertTrue(ollama.body.hasPrefix("Your Ollama models are now on Outboard drive."))
        XCTAssertFalse(ConsentSheetText.confirmDialog(record: T.record(recipeID: "ios-device-backups")).confirmIsDefault, "never the default for a recipe that can't be replaced")
        XCTAssertEqual(ConsentSheetText.confirmDialog(record: T.record(recipeID: "ios-device-backups")).checkboxText, "I opened Finder and my data is there.")
        let note = ConsentSheetText.rollbackNote(record: T.record(), changedFiles: 12)
        XCTAssertEqual(note, "Roll back to your original from 15 Jan. 12 files changed on Outboard drive since then; they stay on the drive and are not copied back.")
        XCTAssertEqual(ConsentSheetText.rollbackNote(record: T.record(), changedFiles: 0), "Roll back to your original from 15 Jan.")
        XCTAssertEqual(ConsentSheetText.forgetWarning, "Outboard cannot get this data back without the drive.")
    }

    // MARK: education, guided

    func testTheFiveCardsAreTheSpecsAndFeedTheSite() throws {
        XCTAssertEqual(Education.cards.map(\.title), ["What this does", "What can move", "What never moves", "How a move works", "If you unplug the drive"])
        XCTAssertEqual(Education.cards[0].body, "Outboard finds the big folders that apps keep on your Mac. For apps where it's known to work, it moves them to an external drive you choose. It looks first, and changes nothing until you say so.")
        XCTAssertEqual(Education.cards[3].body, "It copies the folder to your drive, then checks every file against the original. Only if every file matches does it switch the app over. Your original stays on your Mac, renamed, until you've tried the app and said it works. Nothing is deleted without you.")
        XCTAssertEqual(Education.cards[4].emphasis, "Outboard can't stop you unplugging a drive or make that harmless.")
        XCTAssertEqual(Education.cards[4].buttonTitle, "Keep Outboard running at login")
        XCTAssertEqual(Education.cards[4].buttonNote, "Without it, an unplugged drive leaves apps pointing at nothing until you open Outboard.")
        XCTAssertEqual(Set(Education.cards.map(\.id)).count, 5)
        XCTAssertEqual(Education.driveSteps.count, 5)
        XCTAssertEqual(Education.driveSteps[1], "Click Add Volume in the toolbar. Name it Outboard.")
        XCTAssertEqual(Education.badFormat("exFAT"), "This drive is exFAT. Apps need APFS. Changing the format erases everything on it, and Outboard can't do that for you.")
        for card in Education.cards { XCTAssertEqual(BannedPhrases.hits(in: [card.title, card.body, card.emphasis ?? "", card.buttonTitle ?? "", card.buttonNote ?? ""].joined(separator: "\n")), [], card.id) }
        for s in Education.driveSteps + [Education.guardOn, Education.guardQuit, Education.loginItemNeedsApproval, Education.somethingNotMovable, Education.fullDiskAccessSteps, Education.sleepAndHubs, Education.driveStepsTitle] {
            XCTAssertEqual(BannedPhrases.hits(in: s), [], s)
        }
        let json = Education.exportJSON()
        golden("export", "education.json", json)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual((obj["cards"] as? [Any])?.count, 5)
        XCTAssertEqual(obj["footer"] as? String, ReportText.footer)
        XCTAssertEqual(obj["affiliation"] as? String, "Outboard is not affiliated with or endorsed by any app it lists.")
    }

    func testGuidedCards() {
        let good = Eligibility.evaluate(volume: T.drive(), recipe: T.recipe("photos-library"), source: nil, policy: .release)
        let photos = GuidedText.card(recipe: T.recipe("photos-library"), drive: good)
        XCTAssertEqual(photos.steps.count, 4)
        XCTAssertEqual(photos.openButtonTitle, "Open Photos")
        XCTAssertEqual(photos.bundleID, "com.apple.Photos")
        XCTAssertEqual(photos.closingLine, "Outboard can't see inside Photos. When you're done, open Photos and check that it works.")
        XCTAssertEqual(photos.driveVerdict, "No problems found with this drive for Photos.")
        XCTAssertFalse(photos.driveIsRefused)
        XCTAssertEqual(photos.missingDriveSentence, "Photos stops using the library and starts a new empty one in the default place.")
        XCTAssertFalse(photos.notes.isEmpty)
        XCTAssertNil(GuidedText.card(recipe: T.recipe("photos-library"), drive: nil).driveVerdict)
        let exfat = Eligibility.evaluate(volume: T.drive { $0.fileSystem = .exfat }, recipe: T.recipe("photos-library"), source: nil, policy: .release)
        XCTAssertTrue(GuidedText.card(recipe: T.recipe("photos-library"), drive: exfat).driveIsRefused)
        let hfs = Eligibility.evaluate(volume: T.drive { $0.fileSystem = .hfsPlus }, recipe: T.recipe("photos-library"), source: nil, policy: .release)
        XCTAssertEqual(GuidedText.card(recipe: T.recipe("photos-library"), drive: hfs).driveVerdict, "This drive uses the older Mac OS Extended format. APFS is a better fit.")
        let android = GuidedText.card(recipe: T.recipe("android-sdk"), drive: nil, driveName: "Backup SSD")
        XCTAssertEqual(android.envLine, "export ANDROID_HOME='/Volumes/Backup SSD/Outboard/android-sdk/sdk'")
        for r in Catalogue.guided {
            let c = GuidedText.card(recipe: r, drive: good)
            XCTAssertFalse(c.steps.isEmpty, r.id)
            XCTAssertEqual(BannedPhrases.hits(in: ([c.title, c.closingLine, c.missingDriveSentence, c.driveVerdict ?? ""] + c.steps + c.notes).joined(separator: "\n")), [], r.id)
        }
    }

    // MARK: every sentence the app can say

    func testEveryConsentSheetPassesTheBannedPhraseCheck() {
        for r in Catalogue.automated {
            for d in [T.drive(), T.drive { $0.isEncrypted = .no }, T.drive { $0.fileSystem = .hfsPlus; $0.isSolidState = .unknown }] {
                let s = sheet(r.id, drive: d)
                var parts: [String] = [s.title, s.subtitle, s.unverifiedLine ?? "", s.whatChanges, s.permissionNote, s.relaunchNote ?? ""]
                parts += [s.moveButtonTitle, s.cancelButtonTitle, s.footerLink]
                parts += s.whatToKnow
                parts += s.checkboxes.map(\.text)
                parts += s.warnings
                for line in s.ledger { parts += [line.label, line.amount, line.note] }
                let all = parts.joined(separator: "\n")
                XCTAssertEqual(BannedPhrases.hits(in: all), [], r.id)
                XCTAssertFalse(all.contains("Overflow"), r.id)
                XCTAssertFalse(all.contains("Storage Planner"), r.id)
            }
        }
    }

    // MARK: the activity log

    func testTheActivityLinesAreTheSpecsAndSayWhatWasDone() throws {
        let plan = T.plan()
        let rows = ActivityText.rows(from: T.journal(plan), problemsOnly: false).map(\.text)
        XCTAssertEqual(rows, [
            "Planned moving Ollama models to Outboard drive (30 GB, 100 files).",
            "Checked Outboard drive (APFS, 480 GB free): 14 of 14 checks passed.",
            "Started copying Ollama models to Outboard drive (30 GB, 100 files).",
            "Finished copying.",
            "Compared 100 files by size and SHA-256: 0 differences.",
            "Moved the checked copy to its final place on the drive.",
            "Renamed models to models.before-move.",
            "Put a link at models pointing to the drive.",
            "The move is ready. Waiting for you to try Ollama and confirm.",
            "You confirmed the move.",
            "You confirmed. Moved models.before-move to the Trash.",
        ])
        XCTAssertEqual(ActivityText.rows(from: T.journal(plan), problemsOnly: true), [])
        let all = ActivityText.rows(from: T.journal(plan), problemsOnly: false)
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "one id per line")
        XCTAssertTrue(all.allSatisfy { $0.moveID == plan.id && $0.tone == .normal })
        XCTAssertEqual(all.first?.recipeName, "Ollama models")
        for e in all { XCTAssertFalse(e.text.contains("/"), "no paths: \(e.text)") }
    }

    func testProblemsAndUnknownStepsAreShownNotHidden() throws {
        let plan = T.plan()
        var lines = T.journal(plan, upTo: .verify)
        lines.removeLast()
        lines.append(T.line(plan.id, 30, .result, .verify, status: .mismatch) { $0.verification = VerificationSummary(filesCompared: 100, bytesCompared: 1, differences: 3, completedAt: T.t0) })
        lines.append(T.line(plan.id, 31, .result, .abort, status: .ok, state: .aborted) { $0.abort = .mismatch })
        var future = T.line(plan.id, 32, .result, .swapped, status: .ok)
        future.step = "someFutureStep"
        lines.append(future)
        let problems = ActivityText.rows(from: lines, problemsOnly: true)
        XCTAssertEqual(problems.map(\.text), [
            "Compared 100 files by size and SHA-256: 3 differences found. Nothing on your Mac was changed.",
            "Stopped: a file on the drive differs from the original. Nothing on your Mac was changed.",
            "Unknown step \"someFutureStep\" (result, ok).",
        ])
        XCTAssertTrue(problems.allSatisfy { $0.tone == .problem })
        // failed and refused steps say so plainly
        let failed = T.line(plan.id, 40, .result, .setAside, status: .failed) { $0.errno = 13 }
        XCTAssertEqual(ActivityText.entry(for: failed, recipeNames: [:]).text, "Renaming the original didn't finish: it failed (error 13).")
        let refused = T.line(plan.id, 41, .result, .redirect, status: .refused)
        XCTAssertEqual(ActivityText.entry(for: refused, recipeNames: [:]).text, "Pointing the app at the drive didn't finish: a rule refused it.")
        XCTAssertEqual(ActivityText.entry(for: failed, recipeNames: ["ollama-models": "Ollama models"]).tone, .problem)
        // the guard's and the user's lines
        let park = T.line("m", 50, .result, .park, status: .ok) { $0.note = "unclean"; $0.volName = "Outboard" }
        XCTAssertEqual(ActivityText.entry(for: park, recipeNames: ["ollama-models": "Ollama models"]).text, "Outboard drive was removed without ejecting. Moved the link for Ollama models aside and put a note where the folder was.")
        var ejected = park
        ejected.note = "ejected"
        XCTAssertTrue(ActivityText.entry(for: ejected, recipeNames: [:]).text.hasPrefix("Outboard drive was ejected."))
        var settingPark = park
        settingPark.note = "unclean,defaults"
        XCTAssertEqual(ActivityText.entry(for: settingPark, recipeNames: ["ollama-models": "Xcode build data"]).text,
                       "Outboard drive was removed without ejecting. Put the Xcode build data setting back to its default.")
        // what the park line says is what Outboard saw: an eject, an unmount without one, or neither (it was gone when Outboard looked)
        for (note, how) in [("park:ejected", "was ejected."), ("park:unclean", "was removed without ejecting."),
                            ("park:unknown", "was not connected when Outboard looked, and Outboard didn't see how it was removed.")] {
            var line = park
            line.note = note
            XCTAssertEqual(ActivityText.entry(for: line, recipeNames: ["ollama-models": "Ollama models"]).text,
                           "Outboard drive \(how) Moved the link for Ollama models aside and put a note where the folder was.", note)
        }
        var unsaid = park
        unsaid.note = nil
        XCTAssertTrue(ActivityText.entry(for: unsaid, recipeNames: [:]).text.hasPrefix("Outboard drive was not connected when Outboard looked, and Outboard didn't see how it was removed."),
                      "a park line that names no kind claims no kind")
        let check = T.line("m", 51, .result, .checkAndReconnect, status: .ok) { $0.counts = JournalCounts(files: 38_911, differences: 0) }
        XCTAssertEqual(ActivityText.entry(for: check, recipeNames: [:]).text, "You chose Check and reconnect: 38,911 files compared, 0 differences.")
        let recovered = T.line("m", 52, .result, .recover, status: .ok) { $0.note = "Restored your original models after an interruption." }
        XCTAssertEqual(ActivityText.entry(for: recovered, recipeNames: [:]).text, "Restored your original models after an interruption.")
        XCTAssertEqual(ActivityText.entry(for: T.line("app", 1, .result, .guideViewed, status: .ok), recipeNames: ["ollama-models": "Ollama models"]).text, "Viewed the steps for Ollama models.")
        XCTAssertNil(ActivityText.entry(for: T.line("app", 1, .result, .startGuard, status: .ok), recipeNames: [:]).moveID)
        // an intent with no result is still shown (the step is ambiguous)
        let lone = [T.begin(plan), T.line(plan.id, 2, .intent, .setAside) { $0.src = "~/.ollama/models" }]
        XCTAssertEqual(ActivityText.rows(from: lone, problemsOnly: false).count, 2)
        // every line, every status: a sentence, no banned phrase, no slash
        for step in MoveStep.allCases {
            for phase in [JournalPhase.intent, .result] {
                for status in [StepStatus?.none, .ok, .failed, .refused, .mismatch, .interrupted] {
                    for abort in [AbortReason?.none] + AbortReason.allCases.map({ Optional($0) }) {
                        let line = T.line("m", 1, phase, step, status: status) { $0.abort = abort; $0.src = "~/a/b"; $0.to = "~/a/b.before-move"; $0.volName = "Outboard"; $0.errno = 2 }
                        let text = ActivityText.entry(for: line, recipeNames: ["ollama-models": "Ollama models"]).text
                        XCTAssertFalse(text.isEmpty)
                        XCTAssertEqual(BannedPhrases.hits(in: text), [], text)
                        XCTAssertFalse(text.contains("/") || text.contains("~"), text)
                    }
                }
            }
        }
    }

    func testTheJournalLineIsOneLineOfJSONWithSortedKeys() throws {
        let line = T.journal(T.plan())[3]   // the copy intent
        let text = ActivityLog.encode(line)
        XCTAssertFalse(text.contains("\n"))
        XCTAssertTrue(text.hasPrefix("{\"counts\":"), "keys are sorted: \(text.prefix(40))")
        XCTAssertTrue(text.contains("\"ts\":\"2027-01-15T08:04:00Z\""), "ISO-8601, whole seconds")
        XCTAssertEqual(ActivityLog.decode(line: text), line)
        XCTAssertNil(ActivityLog.decode(line: "not json"))
        XCTAssertNil(ActivityLog.decode(line: String(text.dropLast(5))))
        let all = T.journal(T.plan())
        let file = all.map(ActivityLog.encode).joined(separator: "\n") + "\n"
        let back = ActivityLog.decodeAll("\n" + file + "\n\n")
        XCTAssertEqual(back.entries, all)
        XCTAssertEqual(back.skippedLines, 0)
        XCTAssertEqual(ActivityLog.fileName(for: T.t0), "journal-2027-01.jsonl")
        XCTAssertEqual(ActivityLog.fileName(for: Date(timeIntervalSince1970: 1_791_022_500)), "journal-2026-10.jsonl")
        for ok in ["journal-2026-10.jsonl", "journal-1999-01.jsonl"] { XCTAssertTrue(ActivityLog.isJournalFile(ok), ok) }
        for bad in ["journal-2026-10.json", "journal-26-10.jsonl", "journal-2026-1a.jsonl", "journal-2026_10.jsonl", "x.jsonl", "journal-2026-10.jsonl.bak", ""] { XCTAssertFalse(ActivityLog.isJournalFile(bad), bad) }
        // the begin line carries the plan and nothing else about the files
        let begin = ActivityLog.encode(all[0])
        XCTAssertTrue(begin.contains("\"relativePath\":\"Outboard/ollama-models/models\""))
        XCTAssertFalse(begin.contains("/Users/"), "paths use ~ in the journal")
        XCTAssertTrue(begin.contains("\"macPath\":\"~/.ollama/models\""))
    }

    // MARK: the diagnostics

    func testDiagnosticsNameNoFileFolderOrDrive() {
        let secret = "Jane's Tax Backups"
        let d = T.drive(name: secret)
        let text = DiagnosticsText.text(volumes: [d, T.drive { $0.isLocal = false; $0.fileSystem = .network }], scans: [
            T.scan("ios-device-backups", bytes: 0, state: .notMeasured, reason: .needsFullDiskAccess) { $0.errnoCode = 1 },
            T.scan("ollama-models", bytes: 30_000_000_000),
        ], osVersion: "26.0", appVersion: "1.0.0")
        XCTAssertTrue(text.hasPrefix("Outboard 1.0.0 on macOS 26.0"))
        XCTAssertTrue(text.contains("Volume 1"))
        XCTAssertTrue(text.contains("Volume 2"))
        XCTAssertTrue(text.contains("- ios-device-backups: notMeasured, needsFullDiskAccess, errno 1"))
        XCTAssertFalse(text.contains(secret))
        XCTAssertFalse(text.contains(T.uuid))
        XCTAssertFalse(text.contains("Library"))
        XCTAssertFalse(text.contains("/Users"))
        XCTAssertFalse(text.contains("/Volumes"))
        XCTAssertTrue(text.contains("verdicts: "))
        XCTAssertEqual(BannedPhrases.hits(in: text), [])
        XCTAssertTrue(DiagnosticsText.text(volumes: [], scans: [], osVersion: "26", appVersion: "1").contains("- none"))
    }

    // MARK: JSON

    func testTheJSONWriterIsDeterministic() {
        let v = JSONValue.object(["b": .num(1), "a": .strings(["x\"y", "line\nbreak", "tab\t", "\u{1}", "é/"]), "c": .null, "d": .array([]), "e": .object([:]), "f": .bool(true)])
        let expected = """
        {
          "a": [
            "x\\"y",
            "line\\nbreak",
            "tab\\t",
            "\\u0001",
            "é/"
          ],
          "b": 1,
          "c": null,
          "d": [],
          "e": {},
          "f": true
        }
        """
        XCTAssertEqual(v.render(), expected)
        XCTAssertEqual(JSONValue.object(["b": .num(1), "a": .string("x")]).render(pretty: false), "{\"a\":\"x\",\"b\":1}")
        XCTAssertEqual(JSONValue.unum(UInt64.max).render(), String(Int64.max), "clamped, never trapping")
    }

    func testAJournalLineHasNoRoomForFileContentsOrCommands() throws {
        var line = T.journal(T.plan())[0]
        line.stamp = FileStamp(device: 1, inode: 2, type: .directory)
        line.src = "~/a"; line.to = "~/b"; line.vol = T.uuid; line.volName = "Outboard"; line.fsName = "APFS"; line.status = .ok; line.errno = 2
        line.abort = .interrupted; line.note = "note"; line.counts = JournalCounts(files: 1, bytes: 1); line.trashedPath = "~/.Trash/x"
        line.verification = VerificationSummary(filesCompared: 1, bytesCompared: 1, completedAt: T.t0)
        let data = try ISO8601Lite.encoder().encode(line)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let allowed: Set<String> = ["v", "id", "seq", "ts", "phase", "step", "recipe", "state", "src", "to", "stamp", "vol", "volName", "fsName", "status", "errno", "abort",
                                    "note", "plan", "counts", "verification", "trashedPath"]
        XCTAssertEqual(Set(object.keys).subtracting(allowed), [], "a key that could carry contents, arguments or a command")
        let plan = try XCTUnwrap(object["plan"] as? [String: Any])
        XCTAssertFalse(plan.keys.contains { $0.lowercased().contains("argv") || $0.lowercased().contains("command") || $0.lowercased().contains("content") })
    }
}
