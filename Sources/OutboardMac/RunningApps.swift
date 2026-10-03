import AppKit
import OutboardCore

/// What is running right now: NSWorkspace for bundle IDs, libproc for process names and open handles. Read fresh on every
/// call, never cached (I6). The app never quits or signals anything; a running app only blocks its move.
enum RunningApps {
    /// `includeHandles` adds the same-user processes that hold a file open under the recipe's source (slower; used by the
    /// preflight and the swap, not by the live rows of the consent sheet).
    static func snapshot(for recipe: Recipe, home: String, includeHandles: Bool = true) -> RunningSnapshot {
        // VERIFY: NSWorkspace.runningApplications from a background thread, and in a headless CI session.
        let ids = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let names = Processes.names()
        var holders: [String]?
        if includeHandles, let source = recipe.absoluteSource(home: home) {
            holders = Processes.openHandleHolders(under: source)
        }
        return RunningSnapshot(readable: names != nil, bundleIDs: ids, processNames: names ?? [], openHandleHolders: holders)
    }

    /// The display name of a running app with this bundle ID, for "Quit Xcode" style messages.
    static func localizedName(bundleID: String) -> String? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }?.localizedName
    }
}
