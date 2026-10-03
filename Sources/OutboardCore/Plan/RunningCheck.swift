import Foundation

/// Is the target app running? Pure over a `RunningSnapshot` the Mac layer read fresh. **Unreadable means unknown, and unknown blocks**
/// (fail closed). A positive match always wins: if we can see the app running, the snapshot being partial does not matter.
public enum RunningCheck {
    public static func state(recipe: Recipe, snapshot: RunningSnapshot) -> RunState {
        if recipe.bundleIDs.contains(where: { snapshot.bundleIDs.contains($0) }) { return .running }
        if recipe.processNames.contains(where: { name in snapshot.processNames.contains { sameProcess($0, name) } }) { return .running }
        if let holders = snapshot.openHandleHolders, !holders.isEmpty { return .running }
        return snapshot.readable ? .notRunning : .unknown
    }

    /// The rows of "Before you start": one per bundle id, process name and open-handle holder, nothing clickable.
    public static func blockers(recipe: Recipe, snapshot: RunningSnapshot) -> [Blocker] {
        var rows: [Blocker] = []
        var shownNames: Set<String> = []
        func rowState(_ running: Bool) -> RunState { running ? .running : (snapshot.readable ? .notRunning : .unknown) }

        for bundleID in recipe.bundleIDs {
            let name = displayName(bundleID)
            shownNames.insert(name.lowercased())
            rows.append(Blocker(id: "bundle:" + bundleID, name: name, bundleID: bundleID, state: rowState(snapshot.bundleIDs.contains(bundleID))))
        }
        for process in recipe.processNames {
            if shownNames.contains(process.lowercased()) { continue }
            shownNames.insert(process.lowercased())
            rows.append(Blocker(id: "process:" + process, name: process, processName: process,
                                state: rowState(snapshot.processNames.contains { sameProcess($0, process) })))
        }
        for holder in (snapshot.openHandleHolders ?? []).sorted() {
            rows.append(Blocker(id: "holder:" + holder, name: holder + " (has files open)", processName: holder, state: .running))
        }
        if rows.isEmpty {
            rows.append(Blocker(id: "processes", name: "Running apps and processes", state: snapshot.readable ? .notRunning : .unknown))
        }
        return rows
    }

    /// libproc names are cut at 16 characters and may differ in case: compare case-insensitively on the first 16.
    static func sameProcess(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased(), y = b.lowercased()
        if x == y { return true }
        let limit = 16
        if x.count >= limit || y.count >= limit { return String(x.prefix(limit)) == String(y.prefix(limit)) }
        return false
    }

    static func displayName(_ bundleID: String) -> String {
        switch bundleID {
        case "com.apple.dt.Xcode": return "Xcode"
        case "com.apple.iphonesimulator": return "Simulator"
        case "com.apple.dt.Instruments": return "Instruments"
        case "com.electron.ollama": return "Ollama"
        case "com.apple.Photos": return "Photos"
        case "com.apple.finder": return "Finder"
        default: return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        }
    }
}
