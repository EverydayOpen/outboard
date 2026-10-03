import Foundation
import XCTest
@testable import OutboardCore

final class CatalogueTests: XCTestCase {
    func testTheCatalogueHasSevenEightAndNineEntriesWithFrozenIDs() {
        XCTAssertEqual(Catalogue.automated.map(\.id), ["xcode-deriveddata", "huggingface-hub-cache", "ollama-models", "llamacpp-cache", "npm-cache", "ios-device-backups", "xcode-archives"])
        XCTAssertEqual(Catalogue.guided.map(\.id), ["mas-large-apps", "photos-library", "music-media-folder", "final-cut-library", "logic-sound-library", "steam-library", "lmstudio-models", "android-sdk"])
        XCTAssertEqual(Catalogue.never.map(\.id), ["never-containers", "never-apple-data", "never-homebrew", "never-caches-home", "never-icloud", "never-app-bundles", "never-simulator-runtimes", "never-docker-orbstack", "never-pnpm-uv"])
        XCTAssertEqual(Catalogue.all.count, 24)
        XCTAssertTrue(Catalogue.automated.allSatisfy(\.isAutomated))
        XCTAssertTrue(Catalogue.guided.allSatisfy { $0.kind == .guided })
        XCTAssertTrue(Catalogue.never.allSatisfy { $0.kind == .never })
        XCTAssertEqual(Catalogue.recipe("ollama-models")?.name, "Ollama models")
        XCTAssertNil(Catalogue.recipe("nope"))
    }

    func testTheRealCatalogueHasNoValidatorProblems() {
        XCTAssertEqual(RecipeValidator.problems(in: Catalogue.all), [])
    }

    func testEveryRecipeStartsALineSoTheMarkerGrepCountsIt() throws {
        let dir = repoRoot.appendingPathComponent("Sources/OutboardCore/Recipes")
        var starts = 0
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasSuffix(".swift") {
            let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            starts += text.split(separator: "\n").filter { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return t.hasPrefix("Recipe(id:") || (t.hasPrefix("static let ") && t.contains("= Recipe(id:"))
            }.count
        }
        XCTAssertEqual(starts, Catalogue.all.count)
    }

    func testNoRecipeIsVerifiedYetAndNoTextCarriesTheUnverifiedLine() {
        for r in Catalogue.all {
            XCTAssertFalse(r.verifiedOnRealMac, r.id)
            let texts = [r.name, r.missingDriveEffect] + (r.consent.map { [$0.what, $0.whatChanges] + $0.whatToKnow + $0.checkboxes.map(\.text) } ?? [])
            for t in texts { XCTAssertFalse(t.contains(Names.notTriedMarker), "\(r.id): the line is added by the sheet from the flag") }
            XCTAssertFalse(texts.joined().contains("Overflow"), r.id)
        }
    }

    func testTheDefaultsAllowlistIsExactlyTheXcodeKeys() {
        XCTAssertTrue(Catalogue.allowsDefaults("com.apple.dt.Xcode", "IDECustomDerivedDataLocation"))
        XCTAssertTrue(Catalogue.allowsDefaults("com.apple.dt.Xcode", "IDEDerivedDataPathMode"))
        XCTAssertTrue(Catalogue.allowsDefaults("com.apple.dt.Xcode", "IDECustomDistributionArchivesLocation"))
        XCTAssertFalse(Catalogue.allowsDefaults("com.apple.dt.Xcode", "IDEBuildLocationStyle"))
        XCTAssertFalse(Catalogue.allowsDefaults("com.apple.finder", "IDECustomDerivedDataLocation"))
        XCTAssertFalse(Catalogue.allowsDefaults("", ""))
        // The validator's fixed list and the catalogue's derived list agree.
        for (domain, keys) in RecipeValidator.permittedDefaults {
            for key in keys { XCTAssertTrue(Catalogue.allowsDefaults(domain, key), key) }
        }
    }

    func testDerivedDataUsesTheOfficialSettingWithAWriteBackAndNoDelete() {
        guard case .defaults(let domain, let keys, let restore) = T.recipe("xcode-deriveddata").method else { return XCTFail() }
        XCTAssertEqual(domain, "com.apple.dt.Xcode")
        XCTAssertEqual(restore, .writePrior)
        XCTAssertEqual(keys.map(\.name), ["IDECustomDerivedDataLocation", "IDEDerivedDataPathMode"])
        XCTAssertEqual(keys[0].value, .destinationPath)
        XCTAssertFalse(keys[1].valueVerified, "the mode value is a research guess until CI experiment E1 settles it")
        XCTAssertEqual(T.recipe("xcode-deriveddata").onDriveMissing, .revertSetting)
        XCTAssertEqual(T.recipe("xcode-archives").onDriveMissing, .leaveAlone)
    }

    func testVisibility() {
        let release = Policy.release
        let off = Preferences()
        var on = Preferences()
        on.showUnverifiedMoves = true
        let mac13 = MinOS(13), mac15_1 = MinOS(15, 1), mac15 = MinOS(15, 0)
        XCTAssertEqual(Catalogue.visibility(of: T.recipe("ollama-models"), prefs: off, policy: release, macOS: mac13), .hiddenUntilVerified)
        XCTAssertEqual(Catalogue.visibility(of: T.recipe("ollama-models"), prefs: on, policy: release, macOS: mac13), .offered)
        XCTAssertEqual(Catalogue.visibility(of: T.recipe("photos-library"), prefs: off, policy: release, macOS: mac13), .guided)
        XCTAssertEqual(Catalogue.visibility(of: T.recipe("never-homebrew"), prefs: on, policy: release, macOS: mac13), .never)
        XCTAssertEqual(Catalogue.visibility(of: T.recipe("mas-large-apps"), prefs: off, policy: release, macOS: mac15), .needsNewerMacOS)
        XCTAssertEqual(Catalogue.visibility(of: T.recipe("mas-large-apps"), prefs: off, policy: release, macOS: mac15_1), .guided)
        #if DEBUG
        XCTAssertEqual(Catalogue.visibility(of: T.recipe("ollama-models"), prefs: off, policy: .testing, macOS: mac13), .offered)
        XCTAssertFalse(Catalogue.isUnverified(T.recipe("ollama-models"), policy: .testing))
        #endif
        XCTAssertTrue(Catalogue.isUnverified(T.recipe("ollama-models"), policy: release))
        XCTAssertFalse(Catalogue.isUnverified(T.recipe("photos-library"), policy: release), "a guided card moves nothing")
    }

    func testSomeRecipeFactsFromTheResearch() {
        XCTAssertEqual(T.recipe("ollama-models").bundleIDs, ["com.electron.ollama"])
        XCTAssertTrue(T.recipe("ollama-models").mayRelaunch)
        XCTAssertEqual(T.recipe("huggingface-hub-cache").source, "~/.cache/huggingface/hub")
        XCTAssertEqual(T.recipe("huggingface-hub-cache").companionSources, ["~/.cache/huggingface/xet"])
        XCTAssertTrue(T.recipe("ios-device-backups").needsFDA)
        XCTAssertTrue(T.recipe("ios-device-backups").sensitive)
        XCTAssertEqual(T.recipe("ios-device-backups").riskClass, .irreplaceable)
        XCTAssertEqual(T.recipe("xcode-archives").riskClass, .irreplaceable)
        XCTAssertEqual(T.recipe("npm-cache").riskClass, .regenerable)
        XCTAssertEqual(T.recipe("mas-large-apps").minMacOS, MinOS(15, 1))
        XCTAssertEqual(T.recipe("photos-library").drive, .media)
        XCTAssertEqual(T.recipe("steam-library").drive, .apfsOnlyGuided)
        XCTAssertEqual(T.recipe("ollama-models").drive, .automated)
        for r in Catalogue.automated { XCTAssertEqual(r.beta, [.b1, .b2, .b2, .b2, .b2, .b3, .b4][Catalogue.automated.firstIndex { $0.id == r.id }!], r.id) }
    }

    func testIrreplaceableRecipesCarryTheTimeMachineSentenceAndEveryAutomatedOneSaysTheOriginalStays() {
        for r in Catalogue.automated {
            let bullets = r.consent?.whatToKnow ?? []
            XCTAssertTrue(bullets.contains { $0.contains(Names.beforeMoveSuffix) }, r.id)
            if r.riskClass == .irreplaceable { XCTAssertTrue(bullets.contains { $0.contains("Time Machine") }, r.id) }
            XCTAssertFalse(r.consent?.checkboxes.isEmpty ?? true, r.id)
        }
    }

    func testEveryRecipeThatActsOnUnplugSaysItActsOnlyWhileOutboardRuns() {
        for r in Catalogue.automated where r.onDriveMissing == .parkPlaceholder || r.onDriveMissing == .revertSetting {
            XCTAssertTrue((r.consent?.whatToKnow ?? []).contains { $0.contains(ConsentSheetText.whileRunningPhrase) }, r.id)
        }
        // a recipe that drops the phrase (and so promises the note or the setting change unconditionally) is refused
        let silent = ollama { $0.consent?.whatToKnow = ["Your original stays as models.before-move until you confirm."] }
        XCTAssertTrue(problems(silent).contains("While Outboard is running"), problems(silent))
        // a recipe that does nothing on unplug does not need it
        let archives = T.recipe("xcode-archives")
        XCTAssertEqual(archives.onDriveMissing, .leaveAlone)
        XCTAssertFalse(problems(archives).contains("While Outboard is running"))
    }

    // MARK: validator, adversarial

    private func ollama(_ mutate: (inout Recipe) -> Void) -> Recipe {
        var r = T.recipe("ollama-models")
        mutate(&r)
        return r
    }

    private func problems(_ r: Recipe) -> String { RecipeValidator.problems(in: r).joined(separator: "\n") }

    func testTheValidatorRefusesBadSources() {
        for bad in ["~/Documents/Models", "~/Desktop/x", "~/Library/Containers/com.x/Data", "~/Library/Mail", "~/Library/Caches", "~/Library/Mobile Documents/x",
                    "~/Library/CloudStorage/Dropbox", "/opt/homebrew/Cellar", "~/../etc", "~/a/../b", "/Users/jane/x", "relative/path", "~/Applications/Foo.app"] {
            XCTAssertFalse(problems(ollama { $0.source = bad }).isEmpty, bad)
        }
        XCTAssertFalse(problems(ollama { $0.companionSources = ["~/Documents"] }).isEmpty)
        XCTAssertFalse(problems(ollama { $0.source = "~/Library/Application Support/Outboard/x" }).isEmpty)
        XCTAssertFalse(problems(ollama { $0.source = nil }).isEmpty, "an automated recipe needs a source")
    }

    func testTheValidatorRefusesBadDefaultsRecipes() {
        func derived(_ mutate: (inout Recipe) -> Void) -> Recipe {
            var r = T.recipe("xcode-deriveddata")
            mutate(&r)
            return r
        }
        func withKey(_ name: String, domain: String = "com.apple.dt.Xcode") -> Recipe {
            derived { $0.method = .defaults(domain: domain, keys: [DefaultsKeySpec(name: name, type: .string, value: .destinationPath)], restore: .writePrior) }
        }
        XCTAssertFalse(problems(withKey("IDEBuildLocationStyle")).isEmpty, "a key off the allowlist")
        XCTAssertFalse(problems(withKey("IDECustomDerivedDataLocation", domain: "com.apple.finder")).isEmpty, "a domain off the allowlist")
        XCTAssertFalse(problems(derived { $0.method = .defaults(domain: "com.apple.dt.Xcode", keys: [], restore: .writePrior) }).isEmpty)
        XCTAssertFalse(problems(derived { $0.method = .defaults(domain: "com.apple.dt.Xcode", keys: [DefaultsKeySpec(name: "IDEDerivedDataPathMode", type: .int, value: .int(1))], restore: .writePrior) }).isEmpty, "no key receives the path")
        XCTAssertFalse(problems(derived { $0.method = .defaults(domain: "com.apple.dt.Xcode", keys: [DefaultsKeySpec(name: "IDECustomDerivedDataLocation", type: .int, value: .destinationPath)], restore: .writePrior) }).isEmpty)
        XCTAssertFalse(problems(derived { $0.onDriveMissing = .parkPlaceholder }).isEmpty)
        XCTAssertFalse(problems(derived { $0.verifiedOnRealMac = true }).isEmpty, "an unverified value cannot be verified")
        XCTAssertFalse(problems(derived { $0.needsFDA = true }).isEmpty)
    }

    func testTheValidatorRefusesMissingOrBadTextAndMetadata() {
        XCTAssertFalse(problems(ollama { $0.consent = nil }).isEmpty)
        XCTAssertFalse(problems(ollama { $0.consent?.checkboxes = [] }).isEmpty)
        XCTAssertFalse(problems(ollama { $0.consent?.whatToKnow = ["Nothing is lost."] }).isEmpty, "no before-move bullet")
        XCTAssertFalse(problems(ollama { $0.consent?.whatChanges = "This is safe and risk-free." }).isEmpty, "banned phrase")
        XCTAssertFalse(problems(ollama { $0.missingDriveEffect = "It is faster on an SSD." }).isEmpty)
        XCTAssertFalse(problems(ollama { $0.missingDriveEffect = "" }).isEmpty)
        XCTAssertFalse(problems(ollama { $0.sources = [] }).isEmpty)
        XCTAssertFalse(problems(ollama { $0.sources = ["http://example.com"] }).isEmpty)
        XCTAssertFalse(problems(ollama { $0.id = "Ollama Models" }).isEmpty)
        XCTAssertFalse(problems(ollama { $0.bundleIDs = ["com.*.ollama"] }).isEmpty)
        XCTAssertFalse(problems(ollama { $0.processNames = ["oll*"] }).isEmpty)
        XCTAssertFalse(problems(ollama { $0.onDriveMissing = .revertSetting }).isEmpty)
        XCTAssertFalse(problems(ollama { $0.envLine = "export X=1" }).isEmpty, "the line must use {drive}")
        XCTAssertFalse(problems(ollama { $0.envLine = "export X=\"{drive}/x\"" }).isEmpty, "Outboard quotes the path, the recipe must not")
        XCTAssertFalse(problems(ollama { $0.minMacOS = MinOS(12) }).isEmpty)
        var icloudish = T.recipe("ios-device-backups")
        if var consent = icloudish.consent {
            consent.whatToKnow = consent.whatToKnow.filter { !$0.contains("Time Machine") }
            icloudish.consent = consent
        }
        XCTAssertFalse(problems(icloudish).isEmpty, "irreplaceable without the Time Machine sentence")
        let dup = RecipeValidator.problems(in: [T.recipe("npm-cache"), T.recipe("npm-cache")])
        XCTAssertTrue(dup.contains { $0.contains("more than once") })
        var guided = T.recipe("photos-library")
        guided.consent = T.recipe("npm-cache").consent
        XCTAssertFalse(problems(guided).isEmpty)
        var emptyGuide = T.recipe("photos-library")
        emptyGuide.method = .guided(steps: [])
        XCTAssertFalse(problems(emptyGuide).isEmpty)
        var neverWithSource = T.recipe("never-homebrew")
        neverWithSource.source = "~/x"
        XCTAssertFalse(problems(neverWithSource).isEmpty)
    }

    func testAGuidedCardsStepsLeadToTheFolderItsLineNames() {
        let android = T.recipe("android-sdk")
        XCTAssertEqual(problems(android), "")
        XCTAssertEqual(EnvLine.render(android.envLine ?? "", mountPoint: "/Volumes/Outboard", recipeID: android.id),
                       "export ANDROID_HOME='/Volumes/Outboard/Outboard/android-sdk/sdk'")
        guard case .guided(let steps) = android.method else { return XCTFail("a guided card") }
        XCTAssertTrue(steps.contains { $0.contains("folder named android-sdk inside the Outboard folder, then copy the sdk folder into it") }, "the steps build the path the line prints")
        var vague = android
        vague.method = .guided(steps: ["In Finder, copy the Android sdk folder to your Outboard drive."])
        XCTAssertTrue(problems(vague).contains("the steps must name the folder"), problems(vague))
        for r in Catalogue.all where r.kind == .guided && r.envLine != nil { XCTAssertEqual(problems(r), "", r.id) }
    }

    func testTheGoldenFileIsCurrentAndShapedForTheReaders() throws {
        let json = Catalogue.exportJSON()
        golden("export", "recipes.json", json)
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        XCTAssertEqual(obj?["schema"] as? Int, 1)
        let recipes = obj?["recipes"] as? [[String: Any]]
        XCTAssertEqual(recipes?.count, 24)
        let first = recipes?.first
        for key in ["id", "version", "name", "kind", "source", "companionSources", "defaults", "steps", "neverReason", "riskClass", "onDriveMissing", "needsFDA",
                    "sensitive", "minMacOS", "confidence", "beta", "verifiedOnRealMac", "drive", "consent", "missingDriveEffect", "envLine", "sources", "verify"] {
            XCTAssertNotNil(first?[key], key)   // present, possibly null
        }
        XCTAssertTrue(json.hasSuffix("}\n"))
        XCTAssertEqual(json, Catalogue.exportJSON(), "deterministic")
    }
}
