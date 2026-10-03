import Foundation

/// A recipe's stable id: lowercase words and hyphens (`xcode-deriveddata`). Journaled, so it never changes once shipped.
public typealias RecipeID = String

/// How costly it is to lose the data if the drive never comes back (APP6 §4.2). The label is shown on the consent sheet, the
/// plan row and the export. It decides the consent defaults (Cancel is the default button for `.irreplaceable`) and how an
/// unknown eligibility signal is treated (refuse, instead of asking for a tick).
public enum RiskClass: String, Codable, CaseIterable, Sendable {
    case regenerable, expensive, irreplaceable

    public var displayName: String {
        switch self {
        case .regenerable: return "Rebuilds itself"
        case .expensive: return "Large to download again"
        case .irreplaceable: return "Can't be replaced"
        }
    }
}

/// Confidence that the *method* works for this app, as the research defines it. Not confidence in the size.
public enum Confidence: String, Codable, CaseIterable, Sendable {
    case high, medium, low

    public var displayName: String {
        switch self {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }
}

/// The rollout step in which a recipe may first ship (APP6 §4.1). Each step ships only after the previous one has a
/// `docs/VERIFY_LOG.md` entry from a named tester.
public enum BetaStage: Int, Codable, CaseIterable, Comparable, Sendable {
    case b0 = 0, b1, b2, b3, b4

    public static func < (a: BetaStage, b: BetaStage) -> Bool { a.rawValue < b.rawValue }
    public var displayName: String { "B\(rawValue)" }
}

/// What kind of move a recipe is. The label is what the user reads: vendor-documented settings are "Official", a link is a
/// "Community method", and guided cards are steps the user performs in the vendor's own app.
public enum MethodKind: String, Codable, CaseIterable, Sendable {
    case defaults, symlink, guided, never

    public var displayName: String {
        switch self {
        case .defaults: return "Official setting"
        case .symlink: return "Community method"
        case .guided: return "Guided"
        case .never: return "Not offered"
        }
    }

    /// Outboard itself copies, verifies, switches and guards (`defaults` and `symlink`).
    public var isAutomated: Bool { self == .defaults || self == .symlink }
}

public enum DefaultsValueType: String, Codable, Sendable {
    case string, int

    /// The `defaults write` type flag. Only `ProcessRunner` reads this.
    public var flag: String { self == .string ? "-string" : "-int" }
}

/// Where the value written to a `defaults` key comes from. Recipes are data: a Mac file cannot invent a value.
public enum DefaultsValueSource: Codable, Hashable, Sendable {
    /// The absolute path of the data folder on the drive.
    case destinationPath
    case int(Int)
    case string(String)
}

/// One key a recipe may write (the catalogue allowlist is the set of `(domain, name)` pairs over all recipes).
public struct DefaultsKeySpec: Codable, Hashable, Sendable {
    public var name: String
    public var type: DefaultsValueType
    /// What to write when the move is switched on.
    public var value: DefaultsValueSource
    /// What `DefaultsRestore.writeNeutral` writes for this key; nil leaves the key as it is (the path key stays: harmless
    /// once the mode key is neutral). A restore never deletes a key.
    public var neutral: DefaultsValueSource?
    /// False while the value (not the key name) is a research guess that CI experiment E1 or a tester must settle.
    public var valueVerified: Bool

    public init(name: String, type: DefaultsValueType, value: DefaultsValueSource, neutral: DefaultsValueSource? = nil, valueVerified: Bool = true) {
        self.name = name
        self.type = type
        self.value = value
        self.neutral = neutral
        self.valueVerified = valueVerified
    }
}

/// How the setting is put back when the drive goes missing (and on rollback). There is no delete.
public enum DefaultsRestore: String, Codable, Sendable {
    /// Write back the value read before the move; if there was none, apply `neutral` instead.
    case writePrior
    /// Write each key's `neutral` value.
    case writeNeutral
}

public enum RecipeMethod: Codable, Hashable, Sendable {
    /// Point the app's own setting at the copy with `/usr/bin/defaults write` (allowlisted keys only).
    case defaults(domain: String, keys: [DefaultsKeySpec], restore: DefaultsRestore)
    /// Replace the folder with a symbolic link to the copy (the "community method").
    case symlink
    /// Outboard moves nothing: it shows numbered vendor steps and an "Open <App>" button.
    case guided(steps: [String])
    /// A visible card that says why Outboard does not offer this.
    case never(reason: String)

    public var kind: MethodKind {
        switch self {
        case .defaults: return .defaults
        case .symlink: return .symlink
        case .guided: return .guided
        case .never: return .never
        }
    }
}

/// What the guard does when the drive of an active relocation disappears.
public enum OnDriveMissing: String, Codable, CaseIterable, Sendable {
    /// Move the link aside and put a read-only note file where the folder was.
    case parkPlaceholder
    /// Write the prior (or neutral) value back, if the app is closed; otherwise the banner says what is pending.
    case revertSetting
    /// Do nothing but tell the user (a stale setting is harmless, a rewrite is not).
    case leaveAlone
    /// Guided and never cards.
    case none
}

/// The oldest macOS a recipe applies to (`mas-large-apps` is hidden below 15.1).
public struct MinOS: Codable, Hashable, Comparable, Sendable {
    public var major: Int
    public var minor: Int

    public init(_ major: Int, _ minor: Int = 0) {
        self.major = major
        self.minor = minor
    }

    public static func < (a: MinOS, b: MinOS) -> Bool { (a.major, a.minor) < (b.major, b.minor) }
    public var displayName: String { minor == 0 ? "macOS \(major)" : "macOS \(major).\(minor)" }
}

/// What a destination drive must be for this recipe. The universal rules (E1 network, E3 external, E6 writable, E7 Time Machine,
/// E8 identity, E12 space, E13 iCloud ...) apply to every recipe; these two differ for guided media moves where the vendor allows
/// a spinning disk or Mac OS Extended.
public struct DriveRequirement: Codable, Hashable, Sendable {
    public var allowsHFS: Bool
    public var requiresSolidState: Bool

    public init(allowsHFS: Bool, requiresSolidState: Bool) {
        self.allowsHFS = allowsHFS
        self.requiresSolidState = requiresSolidState
    }

    /// APFS and a solid-state drive (every automated recipe).
    public static let automated = DriveRequirement(allowsHFS: false, requiresSolidState: true)
    /// APFS or Mac OS Extended; a spinning disk gets a warning, not a refusal (Photos, Music, Final Cut, Logic).
    public static let media = DriveRequirement(allowsHFS: true, requiresSolidState: false)
    /// APFS only, spinning disk warned (Steam, LM Studio, Android SDK).
    public static let apfsOnlyGuided = DriveRequirement(allowsHFS: false, requiresSolidState: false)
}

/// One checkbox on a consent sheet. `id` is journaled (which boxes were ticked), so it is stable.
public struct ConsentCheckbox: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

/// The recipe's part of the consent sheet (APP6 §4.12 screen 3). The title ("Move <what> to <drive>?"), subtitle and the
/// space ledger are built by Core text from these fields, the measured size and the chosen drive.
public struct ConsentText: Codable, Hashable, Sendable {
    /// The noun phrase in the title: "Xcode's build data", "your Ollama models".
    public var what: String
    /// Two or three sentences: what is copied, where it lands, what link or setting changes.
    public var whatChanges: String
    /// Three or four bullets: if the drive is unplugged, the original is kept, how to undo, known breakages.
    public var whatToKnow: [String]
    /// Required boxes (all must be ticked): "I have quit Xcode ...", "I understand ...".
    public var checkboxes: [ConsentCheckbox]

    public init(what: String, whatChanges: String, whatToKnow: [String], checkboxes: [ConsentCheckbox]) {
        self.what = what
        self.whatChanges = whatChanges
        self.whatToKnow = whatToKnow
        self.checkboxes = checkboxes
    }
}

/// One catalogue entry. **Recipes are data** (Core `Recipes/`, one `Recipe(...)` per entry): they decide which folder is
/// renamed, so a validator (`tools/check_recipes.py`, also a Core test), CODEOWNERS and a `docs/VERIFY_LOG.md` entry per
/// `verifiedOnRealMac: true` gate every change. A Mac file cannot invent a restore verb (grep G20).
public struct Recipe: Codable, Hashable, Sendable, Identifiable {
    public var id: RecipeID
    /// Bumped when the method, source or keys change; journaled as `<id>@<version>`.
    public var version: Int
    /// "Xcode build data", "iPhone and iPad backups", "Ollama models".
    public var name: String
    /// Bundle IDs of the app and its helpers, for the running check. Mostly unverified (Ollama's is `com.electron.ollama`).
    public var bundleIDs: [String]
    /// Process names for the libproc check (`ollama`, `xcodebuild`).
    public var processNames: [String]
    /// `~/`-relative, no `..`, never under a never-list root. nil on never cards that name no single folder.
    public var source: String?
    /// More folders moved together when present (Hugging Face's `~/.cache/huggingface/xet`). Same rules as `source`.
    public var companionSources: [String]
    public var method: RecipeMethod
    public var riskClass: RiskClass
    public var onDriveMissing: OnDriveMissing
    /// The link or the sizing needs Full Disk Access (iOS backups). Never required for the product as a whole.
    public var needsFDA: Bool
    /// The data is sensitive: an unencrypted destination needs an acknowledgement (E16).
    public var sensitive: Bool
    public var minMacOS: MinOS?
    public var confidence: Confidence
    public var beta: BetaStage
    /// False until a named tester closes this recipe's VERIFY items in `docs/VERIFY_LOG.md`.
    public var verifiedOnRealMac: Bool
    public var drive: DriveRequirement
    /// nil for guided and never cards.
    public var consent: ConsentText?
    /// One plain sentence: what the user sees if the drive is unplugged ("Ollama won't find its models ...").
    public var missingDriveEffect: String
    /// A line to copy, shown as text only (Outboard never edits shell files): `export OLLAMA_MODELS={drive}/models`.
    /// `{drive}` is replaced by the single-quoted data folder on the chosen drive (`EnvLine`), so the template never carries quotes.
    public var envLine: String?
    /// The app may relaunch itself right after being quit (Ollama's menu-bar app): the sheet says to quit it from its menu.
    public var mayRelaunch: Bool
    /// Source URLs (vendor docs, source code) for the claims above. At least one.
    public var sources: [String]
    /// What a real Mac must still confirm before `verifiedOnRealMac` can become true.
    public var verify: [String]

    public init(id: RecipeID, version: Int = 1, name: String, bundleIDs: [String] = [], processNames: [String] = [], source: String?,
                companionSources: [String] = [], method: RecipeMethod, riskClass: RiskClass, onDriveMissing: OnDriveMissing,
                needsFDA: Bool = false, sensitive: Bool = false, minMacOS: MinOS? = nil, confidence: Confidence,
                beta: BetaStage, verifiedOnRealMac: Bool = false, drive: DriveRequirement? = nil, consent: ConsentText? = nil,
                missingDriveEffect: String, envLine: String? = nil, mayRelaunch: Bool = false, sources: [String], verify: [String] = []) {
        self.id = id
        self.version = version
        self.name = name
        self.bundleIDs = bundleIDs
        self.processNames = processNames
        self.source = source
        self.companionSources = companionSources
        self.method = method
        self.riskClass = riskClass
        self.onDriveMissing = onDriveMissing
        self.needsFDA = needsFDA
        self.sensitive = sensitive
        self.minMacOS = minMacOS
        self.confidence = confidence
        self.beta = beta
        self.verifiedOnRealMac = verifiedOnRealMac
        self.drive = drive ?? (method.kind.isAutomated ? .automated : .media)
        self.consent = consent
        self.missingDriveEffect = missingDriveEffect
        self.envLine = envLine
        self.mayRelaunch = mayRelaunch
        self.sources = sources
        self.verify = verify
    }

    public var kind: MethodKind { method.kind }
    public var isAutomated: Bool { kind.isAutomated }
    /// `xcode-deriveddata@1`, as written in journal lines.
    public var versionedID: String { "\(id)@\(version)" }
    /// The app the "Open <App>" button launches (first bundle ID), if any.
    public var launchBundleID: String? { bundleIDs.first }

    /// `~/Library/x` -> `<home>/Library/x`. nil when there is no source.
    public func absoluteSource(home: String) -> String? {
        guard let source else { return nil }
        let h = home.hasSuffix("/") && home.count > 1 ? String(home.dropLast()) : home
        return source.hasPrefix("~/") ? h + "/" + source.dropFirst(2) : source
    }
}
