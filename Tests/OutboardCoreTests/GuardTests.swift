import Foundation
import XCTest
@testable import OutboardCore

final class GuardTests: XCTestCase {
    private func facts(_ path: PathKind, drive: DrivePresence = .mountedAtRecordedPath, sentinel: SentinelFact = .ok, onVolume: Tri = .yes, errno: Int32? = nil,
                       marker: Bool = false, foreign: Bool = false, removal: RemovalKind? = nil, app: RunState = .notRunning, unchanged: Bool = true,
                       sameName: Bool = false) -> GuardFacts {
        GuardFacts(path: path, drive: drive, sentinel: sentinel, targetOnRecordedVolume: onVolume, targetErrno: errno, hasOurMarker: marker,
                   placeholderUnchanged: unchanged, linkIsForeign: foreign, removal: removal, targetApp: app, sameNameDifferentDrive: sameName)
    }

    // MARK: the twelve rows

    func testClassifyIsTheTwelveRowTable() {
        XCTAssertEqual(GuardPolicy.classify(facts(.link)), .healthy)
        XCTAssertEqual(GuardPolicy.classify(facts(.link, drive: .mountedElsewhere, onVolume: .no)), .retarget)
        XCTAssertEqual(GuardPolicy.classify(facts(.link, drive: .absent, onVolume: .unknown)), .park)
        XCTAssertEqual(GuardPolicy.classify(facts(.link, errno: 1)), .needsPermission)
        XCTAssertEqual(GuardPolicy.classify(facts(.link, errno: 13)), .needsPermission)
        XCTAssertEqual(GuardPolicy.classify(facts(.placeholder)), .restore)
        XCTAssertEqual(GuardPolicy.classify(facts(.placeholder, drive: .mountedElsewhere)), .restore)
        XCTAssertEqual(GuardPolicy.classify(facts(.placeholder, drive: .absent)), .parked)
        XCTAssertEqual(GuardPolicy.classify(facts(.other, drive: .absent)), .divergedWhileAbsent)
        XCTAssertEqual(GuardPolicy.classify(facts(.other)), .diverged)
        XCTAssertEqual(GuardPolicy.classify(facts(.missing)), .recreate)
        XCTAssertEqual(GuardPolicy.classify(facts(.link, foreign: true)), .foreign)
        XCTAssertEqual(GuardPolicy.classify(facts(.link, sentinel: .missing)), .suspect)
        XCTAssertEqual(GuardPolicy.classify(facts(.link, sentinel: .wrong)), .suspect)
        XCTAssertEqual(GuardPolicy.classify(facts(.placeholder, sentinel: .wrong)), .suspect)
        XCTAssertEqual(GuardPolicy.classify(facts(.link, drive: .mountedReadOnlyOrLocked)), .lockedOrReadOnly)
        XCTAssertEqual(GuardPolicy.classify(facts(.placeholder, drive: .mountedReadOnlyOrLocked)), .lockedOrReadOnly)
        // all twelve states are reachable
        var seen: Set<GuardState> = []
        for path in [PathKind.real, .link, .placeholder, .missing, .other] {
            for drive in [DrivePresence.absent, .mountedAtRecordedPath, .mountedElsewhere, .mountedReadOnlyOrLocked] {
                for sentinel in [SentinelFact.ok, .missing, .wrong, .unreadable] {
                    for onVolume in Tri.allCases {
                        for errno in [nil, 1, 13, 2] as [Int32?] {
                            for foreign in [false, true] { seen.insert(GuardPolicy.classify(facts(path, drive: drive, sentinel: sentinel, onVolume: onVolume, errno: errno, foreign: foreign))) }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(seen, Set(GuardState.allCases))
    }

    func testTheGuardFailsClosed() {
        // permission is its own state: never "drive missing", never a park
        XCTAssertEqual(GuardPolicy.action(for: .needsPermission, record: T.record()), .reportOnly)
        // an unknown resolution is not healthy
        XCTAssertEqual(GuardPolicy.classify(facts(.link, onVolume: .unknown)), .suspect)
        // the stale /Volumes/<Name> case: the link resolves to a folder that is not on the recorded volume
        XCTAssertEqual(GuardPolicy.classify(facts(.link, onVolume: .no)), .retarget)
        // a wrong sentinel never restores
        for sentinel in [SentinelFact.missing, .wrong, .unreadable] { XCTAssertEqual(GuardPolicy.classify(facts(.placeholder, sentinel: sentinel)), .suspect) }
        // whatever stands at the path and is not ours is never touched
        for state in [GuardState.divergedWhileAbsent, .diverged, .foreign, .suspect, .needsPermission, .lockedOrReadOnly] {
            XCTAssertEqual(GuardPolicy.action(for: state, record: T.record()), .reportOnly, "\(state)")
        }
        XCTAssertEqual(GuardPolicy.classify(facts(.real, drive: .absent)), .divergedWhileAbsent, "the original sitting at an active relocation's path is not merged")
    }

    func testActions() {
        let link = T.record()
        XCTAssertEqual(GuardPolicy.action(for: .healthy, record: link), GuardAction.none)
        XCTAssertEqual(GuardPolicy.action(for: .parked, record: link), GuardAction.none)
        XCTAssertEqual(GuardPolicy.action(for: .retarget, record: link), .retarget)
        XCTAssertEqual(GuardPolicy.action(for: .park, record: link), .park)
        XCTAssertEqual(GuardPolicy.action(for: .restore, record: link), .unpark)
        XCTAssertEqual(GuardPolicy.action(for: .recreate, record: link), .recreate)
        let setting = T.record(recipeID: "xcode-deriveddata", method: .defaults)
        XCTAssertEqual(GuardPolicy.action(for: .park, record: setting), .park, "revertSetting parks by writing the value back")
        let archives = T.record(recipeID: "xcode-archives", method: .defaults)
        XCTAssertEqual(archives.onDriveMissing, .leaveAlone)
        XCTAssertEqual(GuardPolicy.action(for: .park, record: archives), .reportOnly, "a stale setting is harmless, a rewrite is not")
    }

    func testHealthIsDerivedFromStateHeldAndRecord() {
        let r = T.record()
        XCTAssertEqual(GuardPolicy.health(state: .healthy, held: nil, record: r), .healthy)
        XCTAssertEqual(GuardPolicy.health(state: .retarget, held: nil, record: r), .healthy)
        XCTAssertEqual(GuardPolicy.health(state: .park, held: nil, record: r), .driveAway)
        XCTAssertEqual(GuardPolicy.health(state: .parked, held: nil, record: r), .driveAway)
        XCTAssertEqual(GuardPolicy.health(state: .restore, held: nil, record: r), .driveAway)
        XCTAssertEqual(GuardPolicy.health(state: .restore, held: .uncleanRemoval, record: r), .held)
        XCTAssertEqual(GuardPolicy.health(state: .needsPermission, held: .needsPermission, record: r), .held)
        XCTAssertEqual(GuardPolicy.health(state: .lockedOrReadOnly, held: nil, record: r), .held)
        XCTAssertEqual(GuardPolicy.health(state: .diverged, held: nil, record: r), .conflict)
        XCTAssertEqual(GuardPolicy.health(state: .divergedWhileAbsent, held: nil, record: r), .conflict)
        XCTAssertEqual(GuardPolicy.health(state: .foreign, held: nil, record: r), .conflict)
        XCTAssertEqual(GuardPolicy.health(state: .suspect, held: nil, record: r), .broken)
        XCTAssertEqual(GuardPolicy.health(state: .recreate, held: nil, record: r), .broken)
        // every state has a word
        for s in GuardState.allCases { XCTAssertFalse(GuardPolicy.health(state: s, held: nil, record: r).displayName.isEmpty) }
    }

    // MARK: Held

    func testHeldNamesTheFirstPreconditionThatFails() {
        let record = T.record(state: .confirmed)
        let clean = ReturnCheckResult(quickPassed: true, hashed: 200, mismatches: 0, fullCheck: false, sampleOf: 41_203)
        XCTAssertEqual(Held.evaluate(facts: facts(.placeholder), record: record, check: clean), .clear)
        XCTAssertEqual(Held.evaluate(facts: facts(.placeholder, sentinel: .missing), record: record, check: clean), .hold(.wrongDrive))
        XCTAssertEqual(Held.evaluate(facts: facts(.placeholder, onVolume: .no), record: record, check: clean), .hold(.wrongDrive))
        XCTAssertEqual(Held.evaluate(facts: facts(.placeholder, errno: 13), record: record, check: clean), .hold(.needsPermission))
        XCTAssertEqual(Held.evaluate(facts: facts(.placeholder, drive: .mountedReadOnlyOrLocked), record: record, check: clean), .hold(.readOnlyOrLocked))
        XCTAssertEqual(Held.evaluate(facts: facts(.placeholder, unchanged: false), record: record, check: clean), .hold(.quickCheckFailed))
        XCTAssertEqual(Held.evaluate(facts: facts(.placeholder, app: .running), record: record, check: clean), .hold(.appRunning))
        XCTAssertEqual(Held.evaluate(facts: facts(.placeholder, app: .unknown), record: record, check: clean), .hold(.appRunning), "unknown blocks")
        XCTAssertEqual(Held.evaluate(facts: facts(.placeholder, drive: .absent), record: record, check: clean), .hold(.quickCheckFailed))
        XCTAssertEqual(Held.evaluate(facts: facts(.placeholder, drive: .absent, sameName: true), record: record, check: clean), .hold(.wrongDrive))
        // checks on return
        XCTAssertEqual(Held.evaluate(facts: facts(.placeholder), record: record, check: nil), .hold(.quickCheckFailed), "no check, no reconnect")
        XCTAssertEqual(Held.evaluate(facts: facts(.placeholder), record: record, check: ReturnCheckResult(quickPassed: false, hashed: 200, mismatches: 0, fullCheck: false)), .hold(.quickCheckFailed))
        XCTAssertEqual(Held.evaluate(facts: facts(.placeholder), record: record, check: ReturnCheckResult(quickPassed: true, hashed: 200, mismatches: 3, fullCheck: false)), .hold(.sampleMismatch))
    }

    func testAnUncleanRemovalNeedsTheFullCheck() {
        var record = T.record(state: .confirmed)
        record.needsCheckBeforeReconnect = true
        let sample = ReturnCheckResult(quickPassed: true, hashed: 200, mismatches: 0, fullCheck: false)
        let full = ReturnCheckResult(quickPassed: true, hashed: 38_911, mismatches: 0, fullCheck: true, changedSince: 2_290)
        XCTAssertEqual(Held.evaluate(facts: facts(.placeholder), record: record, check: sample), .hold(.uncleanRemoval), "a sample is not enough after a pulled cable")
        XCTAssertEqual(Held.evaluate(facts: facts(.placeholder), record: record, check: nil), .hold(.uncleanRemoval))
        XCTAssertEqual(Held.evaluate(facts: facts(.placeholder), record: record, check: full), .clear)
        XCTAssertEqual(Held.evaluate(facts: facts(.placeholder), record: record, check: ReturnCheckResult(quickPassed: true, hashed: 5, mismatches: 1, fullCheck: true)), .hold(.sampleMismatch))
        // the same when only this session saw the removal
        var clean = T.record(state: .confirmed)
        clean.needsCheckBeforeReconnect = false
        XCTAssertEqual(Held.evaluate(facts: facts(.placeholder, removal: .unclean), record: clean, check: sample), .hold(.uncleanRemoval))
        XCTAssertEqual(Held.evaluate(facts: facts(.placeholder, removal: .unknown), record: clean, check: sample), .hold(.uncleanRemoval))
        XCTAssertEqual(Held.evaluate(facts: facts(.placeholder, removal: .ejected), record: clean, check: sample), .clear)
        // a full check clears a failed quick check: files an app deleted are not a corruption
        XCTAssertEqual(Held.evaluate(facts: facts(.placeholder), record: clean, check: ReturnCheckResult(quickPassed: false, hashed: 900, mismatches: 0, fullCheck: true, missing: 4)), .clear)
    }

    func testReconnectAnywayIsNeverOfferedForIrreplaceableRecipes() {
        XCTAssertTrue(Held.allowsReconnectAnyway(T.record(recipeID: "ollama-models")))
        XCTAssertTrue(Held.allowsReconnectAnyway(T.record(recipeID: "npm-cache")))
        XCTAssertFalse(Held.allowsReconnectAnyway(T.record(recipeID: "ios-device-backups")))
        XCTAssertFalse(Held.allowsReconnectAnyway(T.record(recipeID: "xcode-archives", method: .defaults)))
    }

    // MARK: the snapshot and the banners

    private func snapshot(_ records: [RelocationRecord], _ f: [String: GuardFacts], held: [String: HeldReason] = [:], returns: [String: ReturnReport] = [:],
                          parkFailed: Set<String> = []) -> GuardSnapshot {
        GuardPolicy.snapshot(records: records, facts: f, held: held, lastReturn: returns, parkFailed: parkFailed)
    }

    func testTheSnapshotIsEquatableAndCarriesNoTimestamp() {
        let r = T.record(state: .confirmed)
        let a = snapshot([r], [r.id: facts(.link)])
        var later = r
        later.updatedAt = T.t0.addingTimeInterval(9999)
        let b = snapshot([later], [r.id: facts(.link)])
        XCTAssertEqual(a, b, "a timer tick that finds nothing new gives an equal value")
        XCTAssertTrue(a.isAllHealthy)
        XCTAssertFalse(a.showsAttentionDot)
        XCTAssertEqual(a.banners, [])
        XCTAssertEqual(a.relocations.first?.health, .healthy)
        let away = snapshot([r], [r.id: facts(.link, drive: .absent, onVolume: .unknown)])
        XCTAssertNotEqual(a, away)
        XCTAssertTrue(away.showsAttentionDot)
        XCTAssertEqual(GuardSnapshot.empty, GuardSnapshot())
    }

    func testTheSnapshotWatchesOnlyActiveMoveToDriveRecords() {
        let active = T.record(id: "a", state: .swapped)
        let aborted = T.record(id: "b", state: .aborted)
        var back = T.record(id: "c", state: .swapped)
        back.direction = .returnToMac
        let rolled = T.record(id: "d", state: .rolledBack)
        let allFacts = ["a": facts(.link), "b": facts(.link), "c": facts(.link), "d": facts(.link)]
        let s = snapshot([active, aborted, back, rolled], allFacts)
        XCTAssertEqual(s.relocations.map(\.moveID), ["a"])
        XCTAssertEqual(GuardPolicy.watched([active, aborted, back, rolled]).map(\.id), ["a"])
        XCTAssertEqual(snapshot([active], [:]).relocations, [], "no facts yet, no claim")
    }

    func testBannersAreTheSpecsExactCopy() {
        let backups = T.record(id: "b1", recipeID: "ios-device-backups", state: .confirmed)
        let ollama = T.record(id: "o1", recipeID: "ollama-models", state: .confirmed)
        let away = facts(.placeholder, drive: .absent, onVolume: .unknown, removal: .ejected)
        let ejected = snapshot([backups, ollama], [backups.id: away, ollama.id: away])
        XCTAssertEqual(ejected.banners.count, 1, "two apps on one drive share a banner")
        XCTAssertEqual(ejected.banners.first?.kind, .ejected)
        XCTAssertEqual(ejected.banners.first?.text, "Outboard drive was ejected. iPhone backups and Ollama models are on it, so those apps can't see them. We put a note where each one was. Plug it back in and we'll put things back.")
        XCTAssertEqual(ejected.banners.first?.moveIDs, ["b1", "o1"])

        let one = snapshot([ollama], [ollama.id: away])
        XCTAssertEqual(one.banners.first?.text, "Outboard drive was ejected. Ollama models are on it, so that app can't see them. We put a note where it was. Plug it back in and we'll put things back.")

        let unclean = snapshot([backups], [backups.id: facts(.placeholder, drive: .absent, onVolume: .unknown, removal: .unclean)])
        XCTAssertEqual(unclean.banners.first?.text, "Outboard drive was removed without ejecting. Please check your files before reconnecting.")
        XCTAssertEqual(unclean.banners.first?.actions, [.checkAndReconnect])
        XCTAssertEqual(unclean.relocations.first?.health, .driveAway)

        let backClean = snapshot([ollama], [ollama.id: facts(.link)], returns: [ollama.id: ReturnReport(sampled: 200, sampleOf: 41_203)])
        XCTAssertEqual(backClean.banners.first?.text, "Outboard drive is back. Ollama models are connected again. Checked 200 of 41,203 files: all matched.")
        XCTAssertEqual(backClean.banners.first?.kind, .backClean)
        let backChecked = snapshot([ollama], [ollama.id: facts(.link)], returns: [ollama.id: ReturnReport(fullCheck: true, comparedFiles: 38_911, changedSince: 2_290)])
        XCTAssertEqual(backChecked.banners.first?.text, "Checked 38,911 files that haven't changed since they were copied: all matched. 2,290 files have changed since and weren't compared.")
        let renamed = snapshot([ollama], [ollama.id: facts(.link)], returns: [ollama.id: ReturnReport(driveRenamed: true)])
        XCTAssertEqual(renamed.banners.first?.text, "Outboard drive was renamed. We updated the link for Ollama models.")

        let held = facts(.placeholder)
        let appRunning = snapshot([ollama], [ollama.id: held], held: [ollama.id: .appRunning])
        XCTAssertEqual(appRunning.banners.first?.text, "Outboard drive is back. Quit Ollama and we'll reconnect its models.")
        XCTAssertEqual(appRunning.relocations.first?.health, .held)

        let mismatch = snapshot([ollama], [ollama.id: held], held: [ollama.id: .sampleMismatch], returns: [ollama.id: ReturnReport(sampled: 200, sampleOf: 41_000, mismatches: 3)])
        XCTAssertEqual(mismatch.banners.first?.text, "3 of 200 files differ from when they were copied. We haven't reconnected anything.")
        XCTAssertEqual(mismatch.banners.first?.actions, [.showFiles, .reconnectAnyway, .leaveDisconnected])
        let mismatchBackups = snapshot([backups], [backups.id: held], held: [backups.id: .sampleMismatch], returns: [backups.id: ReturnReport(sampled: 200, mismatches: 3)])
        XCTAssertEqual(mismatchBackups.banners.first?.actions, [.showFiles, .leaveDisconnected], "never for irreplaceable recipes")

        let other = snapshot([ollama], [ollama.id: facts(.placeholder, sentinel: .ok)], held: [ollama.id: .wrongDrive])
        XCTAssertEqual(other.banners.first?.text, "A drive named Outboard is connected, but it isn't the one we moved your data to. We left everything as it was.")

        let conflict = snapshot([backups], [backups.id: facts(.other, drive: .absent)])
        XCTAssertEqual(conflict.banners.first?.kind, .conflict)
        XCTAssertEqual(conflict.banners.first?.text, "Something new appeared where iPhone backups should be (made while the drive was away). We haven't touched it.")
        XCTAssertEqual(conflict.banners.first?.actions, [.showInFinder, .setAsideAndReconnect, .leaveAsIs])
        XCTAssertEqual(conflict.relocations.first?.health, .conflict)

        let permission = snapshot([ollama], [ollama.id: facts(.link, errno: 1)])
        XCTAssertEqual(permission.banners.first?.text, "macOS blocked access to the drive.")
        XCTAssertEqual(permission.banners.first?.actions, [.openPrivacySettings])

        let derived = T.record(id: "x1", recipeID: "xcode-deriveddata", state: .confirmed, method: .defaults)
        let revert = snapshot([derived], [derived.id: facts(.link, drive: .absent, onVolume: .unknown)], held: [derived.id: .appRunning])
        XCTAssertEqual(revert.banners.first?.kind, .revertPending)
        XCTAssertEqual(revert.banners.first?.text, "Outboard drive is away. Quit Xcode and we'll put its setting back.")
        let ejectedSetting = snapshot([derived], [derived.id: facts(.placeholder, drive: .absent, onVolume: .unknown, removal: .ejected)])
        XCTAssertTrue(ejectedSetting.banners.first?.text.contains("We put its setting back.") ?? false, "the setting really is back (parked)")

        let foreign = snapshot([ollama], [ollama.id: facts(.link, foreign: true)])
        XCTAssertEqual(foreign.banners.first?.kind, .foreignLink)
        let suspect = snapshot([ollama], [ollama.id: facts(.link, sentinel: .wrong)])
        XCTAssertEqual(suspect.banners.first?.kind, .suspect)
        let locked = snapshot([ollama], [ollama.id: facts(.link, drive: .mountedReadOnlyOrLocked)])
        XCTAssertEqual(locked.banners.first?.kind, .locked)
        XCTAssertEqual(BannerText.journalNotWritable.text, "I can't write the activity log, so nothing was changed.")
        XCTAssertEqual(BannerText.driveChanged.text, "The drive changed while we were getting ready. Nothing was changed.")
    }

    // MARK: what the banner may say the guard did

    func testTheEjectedBannerSaysItPutANoteOnlyWhenTheRecordIsParked() {
        let ollama = T.record(id: "o1", recipeID: "ollama-models", state: .confirmed)
        let linkStillThere = facts(.link, drive: .absent, onVolume: .unknown, removal: .ejected)   // state .park: no note yet
        let notYet = snapshot([ollama], [ollama.id: linkStillThere])
        XCTAssertEqual(notYet.relocations.first?.state, .park)
        XCTAssertEqual(notYet.banners.first?.kind, .ejected)
        XCTAssertEqual(notYet.banners.first?.text, "Outboard drive was ejected. Ollama models are on it, so that app can't see them. We haven't put a note where it was yet. Plug it back in and we'll put things back.")
        XCTAssertFalse(notYet.banners.first?.text.contains("We put a note") ?? true)

        // the park was tried and failed
        let failed = snapshot([ollama], [ollama.id: linkStillThere], parkFailed: [ollama.id])
        XCTAssertEqual(failed.relocations.first?.parkFailed, true)
        XCTAssertEqual(failed.banners.first?.text, "Outboard drive was ejected. Ollama models are on it, so that app can't see them. Outboard couldn't put a note there. Plug it back in and we'll put things back.")

        // the note stands: the claim is made, and a stale failure flag changes nothing once the state is no longer `park`
        let parked = snapshot([ollama], [ollama.id: facts(.placeholder, drive: .absent, onVolume: .unknown, removal: .ejected)], parkFailed: [ollama.id])
        XCTAssertEqual(parked.relocations.first?.state, .parked)
        XCTAssertEqual(parked.relocations.first?.parkFailed, false, "short-lived: only while the state is park")
        XCTAssertTrue(parked.banners.first?.text.contains("We put a note where it was.") ?? false)
    }

    func testTheEjectedBannerSaysItPutTheSettingBackOnlyWhenItDid() {
        let derived = T.record(id: "x1", recipeID: "xcode-deriveddata", state: .confirmed, method: .defaults)
        XCTAssertEqual(derived.onDriveMissing, .revertSetting)
        let notYet = snapshot([derived], [derived.id: facts(.link, drive: .absent, onVolume: .unknown, removal: .ejected)])
        XCTAssertEqual(notYet.banners.first?.kind, .ejected)
        XCTAssertEqual(notYet.banners.first?.text, "Outboard drive was ejected. Xcode build data is on it, so that app can't see it. We haven't put its setting back yet. Plug it back in and we'll put things back.")
        let failed = snapshot([derived], [derived.id: facts(.link, drive: .absent, onVolume: .unknown, removal: .ejected)], parkFailed: [derived.id])
        XCTAssertTrue(failed.banners.first?.text.contains("Outboard couldn't put its setting back.") ?? false)
        XCTAssertFalse(failed.banners.first?.text.contains("We put") ?? true)
        // an app that is running keeps its own banner
        let running = snapshot([derived], [derived.id: facts(.link, drive: .absent, onVolume: .unknown)], held: [derived.id: .appRunning])
        XCTAssertEqual(running.banners.first?.kind, .revertPending)

        // the drive left while Xcode runs: the park was refused, and that is "waiting for the app", not a failure
        func away(_ app: RunState) -> GuardFacts { facts(.link, drive: .absent, onVolume: .unknown, removal: .ejected, app: app) }
        let waiting = snapshot([derived], [derived.id: away(.running)], parkFailed: [derived.id])
        XCTAssertEqual(waiting.relocations.first?.held, .appRunning)
        XCTAssertEqual(waiting.banners.first?.kind, .revertPending)
        XCTAssertEqual(waiting.banners.first?.text, "Outboard drive is away. Quit Xcode and we'll put its setting back.")
        // an unreadable process list is not "quit it", and a failure with the app closed is still a failure
        XCTAssertEqual(snapshot([derived], [derived.id: away(.unknown)], parkFailed: [derived.id]).banners.first?.kind, .ejected)
        XCTAssertEqual(snapshot([derived], [derived.id: away(.notRunning)], parkFailed: [derived.id]).banners.first?.kind, .ejected)
        // no failed attempt yet, or a recipe that parks a note: nothing changes
        XCTAssertEqual(snapshot([derived], [derived.id: away(.running)]).banners.first?.kind, .ejected)
        let ollama = T.record(id: "o1", recipeID: "ollama-models", state: .confirmed)
        XCTAssertNil(snapshot([ollama], [ollama.id: away(.running)], parkFailed: [ollama.id]).relocations.first?.held)
        // the next pass puts the setting back: the wait is over
        let reverted = snapshot([derived], [derived.id: facts(.placeholder, drive: .absent, onVolume: .unknown, removal: .ejected, app: .running)])
        XCTAssertNil(reverted.relocations.first?.held)
        XCTAssertTrue(reverted.banners.first?.text.contains("We put its setting back.") ?? false)
    }

    func testOneRecordThatIsNotParkedKeepsTheWholeGroupFromClaimingANote() {
        let a = T.record(id: "a", recipeID: "ollama-models", state: .confirmed)
        let b = T.record(id: "b", recipeID: "npm-cache", state: .confirmed)
        let both = snapshot([a, b], [a.id: facts(.placeholder, drive: .absent, onVolume: .unknown, removal: .ejected),
                                      b.id: facts(.link, drive: .absent, onVolume: .unknown, removal: .ejected)])
        XCTAssertEqual(both.banners.count, 1)
        XCTAssertTrue(both.banners.first?.text.contains("We haven't put a note where each one was yet.") ?? false, both.banners.first?.text ?? "")
        let bothParked = snapshot([a, b], [a.id: facts(.placeholder, drive: .absent, onVolume: .unknown, removal: .ejected),
                                            b.id: facts(.placeholder, drive: .absent, onVolume: .unknown, removal: .ejected)])
        XCTAssertTrue(bothParked.banners.first?.text.contains("We put a note where each one was.") ?? false)
        // a recipe that leaves the setting alone has nothing to park, whatever the state
        let archives = T.record(id: "c", recipeID: "xcode-archives", state: .confirmed, method: .defaults)
        let left = snapshot([archives], [archives.id: facts(.link, drive: .absent, onVolume: .unknown, removal: .ejected)])
        XCTAssertTrue(left.banners.first?.text.contains("We left its setting as it was.") ?? false)
    }

    func testOnlyAnUnmountTheGuardSawIsCalledARemovalWithoutEjecting() {
        let ollama = T.record(id: "o1", recipeID: "ollama-models", state: .confirmed)
        let pulled = snapshot([ollama], [ollama.id: facts(.placeholder, drive: .absent, onVolume: .unknown, removal: .unclean)])
        XCTAssertEqual(pulled.banners.first?.kind, .removedUnclean)
        XCTAssertEqual(pulled.banners.first?.text, "Outboard drive was removed without ejecting. Please check your files before reconnecting.")
        let unseen = snapshot([ollama], [ollama.id: facts(.placeholder, drive: .absent, onVolume: .unknown, removal: .unknown)])
        XCTAssertEqual(unseen.banners.first?.kind, .removedUnclean)
        XCTAssertEqual(unseen.banners.first?.text, "Outboard drive was not connected when Outboard looked, and Outboard didn't see how it was removed. Please check your files before reconnecting, because Outboard can't tell how it left.")
        XCTAssertEqual(unseen.banners.first?.actions, [.checkAndReconnect])
        // the drive is back and the live notification is gone: the park line's word is used, and its absence is "unknown"
        let backAfterPull = T.record(id: "o1", recipeID: "ollama-models", state: .confirmed) { $0.removalKind = .unclean; $0.needsCheckBeforeReconnect = true }
        let back = snapshot([backAfterPull], [backAfterPull.id: facts(.placeholder)], held: [backAfterPull.id: .uncleanRemoval])
        XCTAssertEqual(back.banners.first?.text, "Outboard drive was removed without ejecting. Please check your files before reconnecting.")
        let backUnknown = T.record(id: "o1", recipeID: "ollama-models", state: .confirmed) { $0.removalKind = .unknown; $0.needsCheckBeforeReconnect = true }
        let backU = snapshot([backUnknown], [backUnknown.id: facts(.placeholder)], held: [backUnknown.id: .uncleanRemoval])
        XCTAssertTrue(backU.banners.first?.text.contains("didn't see how it was removed") ?? false)
        // two relocations, one pulled and one unseen: the weaker claim covers both
        let other = T.record(id: "n1", recipeID: "npm-cache", state: .confirmed)
        let mixed = snapshot([ollama, other], [ollama.id: facts(.placeholder, drive: .absent, onVolume: .unknown, removal: .unclean),
                                               other.id: facts(.placeholder, drive: .absent, onVolume: .unknown, removal: .unknown)])
        XCTAssertFalse(mixed.banners.first?.text.contains("removed without ejecting") ?? true)
        // an eject the guard saw keeps its banner
        let ejected = snapshot([ollama], [ollama.id: facts(.placeholder, drive: .absent, onVolume: .unknown, removal: .ejected)])
        XCTAssertEqual(ejected.banners.first?.kind, .ejected)
    }

    func testBannersAreOrderedBySeverityAndEveryTextIsClean() {
        let a = T.record(id: "a", recipeID: "ollama-models", state: .confirmed)
        var b = T.record(id: "b", recipeID: "npm-cache", state: .confirmed)
        b.volume = VolumeRef(uuid: "OTHER-UUID", name: "Backup SSD", token: "t2")
        let s = snapshot([a, b], [a.id: facts(.placeholder, drive: .absent, removal: .ejected), b.id: facts(.other, drive: .mountedAtRecordedPath)])
        XCTAssertEqual(s.banners.map(\.kind), [.conflict, .ejected], "the conflict first")
        XCTAssertEqual(s.banners[0].text.contains("npm cache"), true)
        var texts: [String] = []
        for h in [HeldReason?.none] + HeldReason.allCases.map({ Optional($0) }) {
            for path in [PathKind.placeholder, .link, .other, .missing] {
                for drive in [DrivePresence.absent, .mountedAtRecordedPath, .mountedReadOnlyOrLocked] {
                    for removal in [RemovalKind?.none, .ejected, .unclean] {
                        let f = facts(path, drive: drive, foreign: false, removal: removal)
                        let held = h.map { [a.id: $0] } ?? [:]
                        texts += snapshot([a], [a.id: f], held: held, returns: [a.id: ReturnReport(sampled: 200, sampleOf: 400, mismatches: 1)]).banners.map(\.text)
                    }
                }
            }
        }
        XCTAssertFalse(texts.isEmpty)
        for t in texts { XCTAssertEqual(BannedPhrases.hits(in: t), [], t) }
    }

    func testThePlaceholderTextIsExact() {
        XCTAssertEqual(PlaceholderText.body(driveName: "Outboard"),
                       "Outboard moved this folder's contents to the drive \"Outboard\". The drive isn't connected, so this note is here instead. Outboard puts things back when the drive returns, but only while Outboard is running, so open Outboard if it is closed. This note does not check the data on the drive.")
        XCTAssertTrue(PlaceholderText.body(driveName: "Outboard").contains("only while Outboard is running"), "the note outlives the app, so it says when things are put back")
        XCTAssertFalse(PlaceholderText.body(driveName: "A\nB\u{7}C").contains("\n"))
        XCTAssertEqual(PlaceholderText.body(driveName: String(repeating: "x", count: 500)).count < Limits.placeholderMaxBytes, true)
        XCTAssertEqual(BannedPhrases.hits(in: PlaceholderText.body(driveName: "Outboard")), [])
    }
}
