import Foundation

/// What the Plan screen does with a catalogue entry in this build.
public enum RecipeVisibility: Equatable, Sendable {
    /// Automated, enabled: the Move button is there.
    case offered
    /// Automated but not yet tried on a real Mac and the preference is off: the mover is hidden.
    case hiddenUntilVerified
    case needsNewerMacOS
    case guided
    case never
}

/// The recipe catalogue: 7 automated, 8 guided and 9 never cards, as Swift data (BUILD_PLAN §4.2). Recipes are bundled and never
/// fetched. `exportJSON()` is the golden file `tools/check_recipes.py` and the site builder read.
public enum Catalogue {
    public static let automated: [Recipe] = [
        AutomatedRecipes.xcodeDerivedData,
        AutomatedRecipes.huggingFaceHub,
        AutomatedRecipes.ollamaModels,
        AutomatedRecipes.llamaCppCache,
        AutomatedRecipes.npmCache,
        AutomatedRecipes.iosDeviceBackups,
        AutomatedRecipes.xcodeArchives,
    ]

    public static let guided: [Recipe] = [
        GuidedRecipes.macAppStoreLargeApps,
        GuidedRecipes.photosLibrary,
        GuidedRecipes.musicMediaFolder,
        GuidedRecipes.finalCutLibrary,
        GuidedRecipes.logicSoundLibrary,
        GuidedRecipes.steamLibrary,
        GuidedRecipes.lmStudioModels,
        GuidedRecipes.androidSdk,
    ]

    public static let never: [Recipe] = [
        NeverRecipes.containers,
        NeverRecipes.appleData,
        NeverRecipes.homebrew,
        NeverRecipes.cachesAndHome,
        NeverRecipes.icloud,
        NeverRecipes.appBundles,
        NeverRecipes.simulators,
        NeverRecipes.dockerOrbstack,
        NeverRecipes.pnpmUv,
    ]

    /// Display order: automated, then guided, then never.
    public static let all: [Recipe] = automated + guided + never

    public static func recipe(_ id: RecipeID) -> Recipe? {
        all.first { $0.id == id }
    }

    /// The `(domain, key)` pairs `/usr/bin/defaults` may be run for: those of the automated recipes' `.defaults` methods and nothing else.
    private static let defaultsAllowlist: Set<String> = {
        var set: Set<String> = []
        for recipe in automated {
            if case .defaults(let domain, let keys, _) = recipe.method {
                for key in keys { set.insert(domain + "\u{1F}" + key.name) }
            }
        }
        return set
    }()

    public static func allowsDefaults(_ domain: String, _ key: String) -> Bool {
        defaultsAllowlist.contains(domain + "\u{1F}" + key)
    }

    /// An automated recipe is enabled in this build when it has been tried on a real Mac, when the policy treats all as tried
    /// (tests, demo), or when the user turned on "Show moves not yet tried on a real Mac".
    public static func isEnabled(_ r: Recipe, prefs: Preferences, policy: Policy) -> Bool {
        guard r.isAutomated else { return false }
        return r.verifiedOnRealMac || policy.treatsAllRecipesAsVerified || prefs.showUnverifiedMoves
    }

    /// Not yet tried on a real Mac: the consent sheet then carries `Names.notTriedMarker` (the sheet adds it from this flag).
    public static func isUnverified(_ r: Recipe, policy: Policy) -> Bool {
        r.isAutomated && !(r.verifiedOnRealMac || policy.treatsAllRecipesAsVerified)
    }

    public static func visibility(of r: Recipe, prefs: Preferences, policy: Policy, macOS: MinOS) -> RecipeVisibility {
        if r.kind == .never { return .never }
        if let minimum = r.minMacOS, macOS < minimum { return .needsNewerMacOS }
        if r.kind == .guided { return .guided }
        return isEnabled(r, prefs: prefs, policy: policy) ? .offered : .hiddenUntilVerified
    }

    // MARK: - The golden file

    /// Sorted keys, two-space indent, LF. Every key is always present (`null` when empty), so a reader never guesses.
    public static func exportJSON() -> String {
        JSONValue.object([
            "schema": .num(1),
            "recipes": .array(all.map(jsonValue)),
        ]).render() + "\n"
    }

    static func jsonValue(_ r: Recipe) -> JSONValue {
        var defaults: JSONValue = .null
        var steps: [String] = []
        var neverReason: JSONValue = .null
        switch r.method {
        case .defaults(let domain, let keys, let restore):
            defaults = .object([
                "domain": .string(domain),
                "restore": .string(restore.rawValue),
                "keys": .array(keys.map { key in
                    .object([
                        "name": .string(key.name),
                        "type": .string(key.type.rawValue),
                        "value": valueJSON(key.value),
                        "neutral": key.neutral.map(valueJSON) ?? .null,
                        "valueVerified": .bool(key.valueVerified),
                    ])
                }),
            ])
        case .symlink: break
        case .guided(let s): steps = s
        case .never(let reason): neverReason = .string(reason)
        }
        var consent: JSONValue = .null
        if let c = r.consent {
            consent = .object([
                "what": .string(c.what),
                "whatChanges": .string(c.whatChanges),
                "whatToKnow": .strings(c.whatToKnow),
                "checkboxes": .array(c.checkboxes.map { .object(["id": .string($0.id), "text": .string($0.text)]) }),
            ])
        }
        return .object([
            "id": .string(r.id),
            "version": .num(r.version),
            "name": .string(r.name),
            "kind": .string(r.kind.rawValue),
            "methodLabel": .string(r.kind.displayName),
            "bundleIDs": .strings(r.bundleIDs),
            "processNames": .strings(r.processNames),
            "source": .optional(r.source),
            "companionSources": .strings(r.companionSources),
            "defaults": defaults,
            "steps": .strings(steps),
            "neverReason": neverReason,
            "riskClass": .string(r.riskClass.rawValue),
            "riskLabel": .string(r.riskClass.displayName),
            "onDriveMissing": .string(r.onDriveMissing.rawValue),
            "needsFDA": .bool(r.needsFDA),
            "sensitive": .bool(r.sensitive),
            "minMacOS": r.minMacOS.map { .string($0.minor == 0 ? "\($0.major)" : "\($0.major).\($0.minor)") } ?? .null,
            "confidence": .string(r.confidence.rawValue),
            "beta": .string(r.beta.displayName),
            "verifiedOnRealMac": .bool(r.verifiedOnRealMac),
            "drive": .object([
                "allowsHFS": .bool(r.drive.allowsHFS),
                "requiresSolidState": .bool(r.drive.requiresSolidState),
            ]),
            "consent": consent,
            "missingDriveEffect": .string(r.missingDriveEffect),
            "envLine": .optional(r.envLine),
            "mayRelaunch": .bool(r.mayRelaunch),
            "sources": .strings(r.sources),
            "verify": .strings(r.verify),
        ])
    }

    private static func valueJSON(_ v: DefaultsValueSource) -> JSONValue {
        switch v {
        case .destinationPath: return .object(["kind": .string("destinationPath"), "value": .null])
        case .int(let n): return .object(["kind": .string("int"), "value": .num(n)])
        case .string(let s): return .object(["kind": .string("string"), "value": .string(s)])
        }
    }
}
