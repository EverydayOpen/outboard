import Foundation

/// The few things the user can change. Named `Preferences` so it never collides with SwiftUI's `Settings` scene. Stored as one
/// JSON blob in UserDefaults (`App/AppModel.swift` is the only file that touches UserDefaults). Nothing here can make Outboard
/// do more than the rules allow: the toggle only *shows* moves that are not yet tried on a real Mac, with a warning on the sheet.
public struct Preferences: Codable, Hashable, Sendable {
    /// "Show moves not yet tried on a real Mac" (default off): until a tester closes a recipe's VERIFY items, the release
    /// build hides its mover. With this on, the consent sheet carries "Not yet tried on a real Mac."
    public var showUnverifiedMoves: Bool
    /// Replace folder paths with recipe names in Markdown and JSON exports.
    public var hideFolderPathsInExports: Bool
    /// "Show app names" on the Storage Plan card; off turns rows into "3 folders".
    public var showAppNamesOnCard: Bool
    /// "Start Outboard at login" (offered on the first move; default on; registered only after the user says yes there).
    public var startAtLogin: Bool
    /// Closing the window does not quit while any relocation exists (the guard keeps running from the menu bar).
    public var keepGuardRunning: Bool
    public var hasSeenFirstRun: Bool
    /// The login-item question was asked (so it is asked once).
    public var hasAnsweredLoginItem: Bool
    /// The drive the user last chose with "Use this drive".
    public var preferredVolumeUUID: String?
    /// Moves whose 14-day safety-copy reminder was dismissed.
    public var dismissedReminders: [String]

    public init(showUnverifiedMoves: Bool = false, hideFolderPathsInExports: Bool = false, showAppNamesOnCard: Bool = true,
                startAtLogin: Bool = true, keepGuardRunning: Bool = true, hasSeenFirstRun: Bool = false,
                hasAnsweredLoginItem: Bool = false, preferredVolumeUUID: String? = nil, dismissedReminders: [String] = []) {
        self.showUnverifiedMoves = showUnverifiedMoves
        self.hideFolderPathsInExports = hideFolderPathsInExports
        self.showAppNamesOnCard = showAppNamesOnCard
        self.startAtLogin = startAtLogin
        self.keepGuardRunning = keepGuardRunning
        self.hasSeenFirstRun = hasSeenFirstRun
        self.hasAnsweredLoginItem = hasAnsweredLoginItem
        self.preferredVolumeUUID = preferredVolumeUUID
        self.dismissedReminders = dismissedReminders
    }

    /// Every field is optional in a stored blob, so adding one later never wipes the user's choices.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let def = Preferences()
        showUnverifiedMoves = try c.decodeIfPresent(Bool.self, forKey: .showUnverifiedMoves) ?? def.showUnverifiedMoves
        hideFolderPathsInExports = try c.decodeIfPresent(Bool.self, forKey: .hideFolderPathsInExports) ?? def.hideFolderPathsInExports
        showAppNamesOnCard = try c.decodeIfPresent(Bool.self, forKey: .showAppNamesOnCard) ?? def.showAppNamesOnCard
        startAtLogin = try c.decodeIfPresent(Bool.self, forKey: .startAtLogin) ?? def.startAtLogin
        keepGuardRunning = try c.decodeIfPresent(Bool.self, forKey: .keepGuardRunning) ?? def.keepGuardRunning
        hasSeenFirstRun = try c.decodeIfPresent(Bool.self, forKey: .hasSeenFirstRun) ?? def.hasSeenFirstRun
        hasAnsweredLoginItem = try c.decodeIfPresent(Bool.self, forKey: .hasAnsweredLoginItem) ?? def.hasAnsweredLoginItem
        preferredVolumeUUID = try c.decodeIfPresent(String.self, forKey: .preferredVolumeUUID) ?? def.preferredVolumeUUID
        dismissedReminders = try c.decodeIfPresent([String].self, forKey: .dismissedReminders) ?? def.dismissedReminders
    }

    public static let `default` = Preferences()
}
