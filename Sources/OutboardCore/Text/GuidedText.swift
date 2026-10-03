import Foundation

/// A guided card: Outboard measures, checks the chosen drive, shows these numbered steps and an "Open <App>" button. It moves and
/// writes nothing; the journal records only "guide viewed".
public struct GuidedCard: Codable, Hashable, Sendable {
    public var recipeID: RecipeID
    public var title: String
    public var appName: String
    public var steps: [String]
    public var openButtonTitle: String
    public var bundleID: String?
    /// What the chosen drive's checks say for this app; nil when no drive is chosen.
    public var driveVerdict: String?
    public var driveIsRefused: Bool
    /// The vendor's own missing-drive behaviour, in one sentence.
    public var missingDriveSentence: String
    public var notes: [String]
    public var envLine: String?
    public var closingLine: String

    public init(recipeID: RecipeID, title: String, appName: String, steps: [String], openButtonTitle: String, bundleID: String?, driveVerdict: String?,
                driveIsRefused: Bool, missingDriveSentence: String, notes: [String], envLine: String?, closingLine: String) {
        self.recipeID = recipeID
        self.title = title
        self.appName = appName
        self.steps = steps
        self.openButtonTitle = openButtonTitle
        self.bundleID = bundleID
        self.driveVerdict = driveVerdict
        self.driveIsRefused = driveIsRefused
        self.missingDriveSentence = missingDriveSentence
        self.notes = notes
        self.envLine = envLine
        self.closingLine = closingLine
    }
}

public enum GuidedText {
    /// Vendor rules that go beside the steps. Facts are re-read against the vendor page before the copy ships (VERIFY item 16).
    static let notes: [RecipeID: [String]] = [
        "mas-large-apps": [
            "This applies to App Store apps over 1 GB that you download from now on. Apps already installed stay where they are.",
            "It needs macOS 15.1 or later.",
        ],
        "photos-library": [
            "The drive can't be your Time Machine disk, an SD card, a USB stick or a network location (Apple's rules).",
            "Keep your original library until you've used the new one for a while.",
        ],
        "music-media-folder": [
            "New music goes to the new folder. Songs you already have may stay where they are unless you consolidate.",
        ],
        "final-cut-library": [
            "The drive can't be your Time Machine disk, and exFAT or NTFS drives are not suitable.",
        ],
        "logic-sound-library": [
            "Don't rename the drive afterwards. Keep one copy of the library per Mac.",
            "The drive can't be your Time Machine disk.",
        ],
        "steam-library": [
            "Steam may need a restart after the drive returns.",
        ],
        "lmstudio-models": [
            "Outboard doesn't copy these files for you here. Keep the folder layout when you copy them.",
        ],
        "android-sdk": [
            "Emulators and the command-line tools read their own variables; the steps say which.",
        ],
    ]

    /// The line to copy (`{drive}`) is built from `mountPoint`, the drive's real mount point; without one it assumes `/Volumes/<driveName>`.
    /// Either way the path is single-quoted by `EnvLine`, so a drive's name can't add commands to a pasted line.
    public static func card(recipe: Recipe, drive: EligibilityReport?, driveName: String = "Outboard", mountPoint: String? = nil) -> GuidedCard {
        var steps: [String] = []
        if case .guided(let s) = recipe.method { steps = s }
        let app = RecipeNames.appName(recipe.id)
        var verdict: String?
        var refused = false
        if let drive {
            if let first = drive.firstRefusal {
                verdict = first.message
                refused = true
            } else if !drive.warnings.isEmpty {
                verdict = drive.warnings.map(\.message).joined(separator: " ")
            } else {
                verdict = "No problems found with this drive for \(app)."
            }
        }
        var env: String?
        var cardNotes = notes[recipe.id] ?? []
        if let line = recipe.envLine {
            env = EnvLine.render(line, mountPoint: mountPoint ?? "/Volumes/\(driveName)", recipeID: recipe.id)
            if env == nil { cardNotes.append(EnvLine.setYourself) }
        }
        return GuidedCard(recipeID: recipe.id, title: recipe.name, appName: app, steps: steps, openButtonTitle: "Open \(app)",
                          bundleID: recipe.launchBundleID, driveVerdict: verdict, driveIsRefused: refused,
                          missingDriveSentence: recipe.missingDriveEffect, notes: cardNotes, envLine: env,
                          closingLine: "Outboard can't see inside \(app). When you're done, open \(app) and check that it works.")
    }
}

/// The note file Outboard leaves where a folder was while its drive is away: a small read-only regular file named like the folder.
public enum PlaceholderText {
    /// The text of the note. The drive name is cleaned (no line breaks or control characters, at most 100 characters) so the note stays
    /// short and one paragraph.
    public static func body(driveName: String) -> String {
        var clean = String(driveName.unicodeScalars.map { $0.value < 32 || $0.value == 127 ? " " : Character($0) })
        clean = clean.trimmingCharacters(in: .whitespaces)
        if clean.count > 100 { clean = String(clean.prefix(100)) }
        return "Outboard moved this folder's contents to the drive \"\(clean)\". The drive isn't connected, so this note is here instead. Outboard puts things back when the drive returns, but only while Outboard is running, so open Outboard if it is closed. This note does not check the data on the drive."
    }
}
