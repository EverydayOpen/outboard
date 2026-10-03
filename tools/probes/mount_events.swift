// Probe (BUILD_PLAN section 6.4, VERIFY item 3): which NSWorkspace notifications arrive in a headless runner session when a volume is
// attached, renamed or detached, and what their userInfo holds. Usage: mount_events SECONDS. Prints READY, then one line per
// notification until SECONDS have passed. Run by tools/probes/volumes.sh; never part of the app.
// The rename notification is looked up by its documented raw name, so a missing symbol cannot stop the probe from compiling.
import AppKit
import Foundation

let args = CommandLine.arguments
let seconds = args.count > 1 ? Double(args[1]) ?? 30 : 30

let names: [(String, Notification.Name)] = [
    ("didMount", NSWorkspace.didMountNotification),
    ("willUnmount", NSWorkspace.willUnmountNotification),
    ("didUnmount", NSWorkspace.didUnmountNotification),
    ("didRenameVolume", Notification.Name("NSWorkspaceDidRenameVolumeNotification")),
    ("willSleep", NSWorkspace.willSleepNotification),
    ("didWake", NSWorkspace.didWakeNotification),
]

var tokens: [NSObjectProtocol] = []
for (label, name) in names {
    let token = NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: nil) { note in
        let info = (note.userInfo ?? [:]).map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "; ")
        print("\(Date().timeIntervalSince1970) \(label): \(info)")
        fflush(stdout)
    }
    tokens.append(token)
}

print("READY observing \(names.count) notifications for \(seconds) s")
fflush(stdout)
RunLoop.main.run(until: Date().addingTimeInterval(seconds))
print("done; observers: \(tokens.count)")
