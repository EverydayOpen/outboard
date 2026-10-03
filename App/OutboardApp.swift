import AppKit
import OutboardMac
import SwiftUI

/// A regular window app (Dock icon): Plan, Drives, Activity. The menu bar item exists once a moved folder is watched, and only
/// reopens the window and says in words how the guard stands. Closing the window keeps Outboard running while a moved folder is
/// watched and the preference is on (the guard runs while the app does); otherwise it quits. No helper, no root, no network
/// (BUILD_PLAN §1).
@main
struct OutboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Created lazily by SwiftUI after `init()` below has run, so materialization is already off when the model exists.
    @StateObject private var model = AppModel()

    // First thing at launch: a dataless iCloud file then fails with EDEADLK instead of being downloaded by a measurement
    // (BUILD_PLAN section 3; safety_greps.sh pins this call).
    init() { _ = Materialization.disableForProcess() }

    var body: some Scene {
        // The window first, so a demo launch always shows it.
        Window("Outboard", id: "main") {
            RootView().environmentObject(model)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1000, height: 700)
        .commands { OutboardCommands(model: model) }

        // Present once a moved folder is watched. `isInserted` reads derived state and never writes a value back: a plain
        // binding to a @Published value is written back on every scene update, which re-rendered Aftertaste without end.
        MenuBarExtra(isInserted: Binding(get: { model.hasRelocations }, set: { _ in })) {
            GuardMenu(model: model)
        } label: {
            Image(nsImage: model.guardSnapshot.showsAttentionDot ? MenuBarIcon.attention : MenuBarIcon.moored)
                .accessibilityLabel(model.menuStatus)
        }
    }
}

/// The menu bar item's menu: how the guard stands, in words, and the way back to the window. Nothing here moves or changes a thing.
private struct GuardMenu: View {
    @ObservedObject var model: AppModel
    // VERIFY on macOS 13: openWindow(id:) reopens a closed Window scene from a MenuBarExtra menu.
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.menuStatus)
        Divider()
        Button("Open Outboard") {
            openWindow(id: "main")
            activateApp()
        }
        Divider()
        Button("Quit Outboard") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Menus. The Edit menu stays whole (never replace `.pasteboard` or `.textEditing`: tools/repo_checks.sh). Preferences is a sheet
/// in the main window, so the commands open the window first. Every item here is a view change or a read; a move only ever
/// starts from the buttons in the window, behind the consent sheet.
@MainActor private struct OutboardCommands: Commands {
    @ObservedObject var model: AppModel
    // VERIFY on macOS 13: the environment reaches Commands, so openWindow works from a menu item.
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Outboard") {
                show()
                model.screen = .about
            }
            Button("Check for Updates\u{2026}") { model.openReleases() }
        }
        CommandGroup(replacing: .appSettings) {
            Button("Preferences\u{2026}") {
                show()
                model.showPreferences = true
            }
            .keyboardShortcut(",")
            .disabled(model.isBusy || model.sheetOpen)
        }
        CommandGroup(replacing: .newItem) {
            Button("Export Report\u{2026}") {
                show()
                model.showReport = true
            }
            .keyboardShortcut("e")
            .disabled(model.isBusy || model.sheetOpen)
        }
        CommandGroup(after: .toolbar) {
            Button("Plan") { go(.plan) }
                .keyboardShortcut("1")
                .disabled(model.sheetOpen)
            Button("Drives") { go(.drives) }
                .keyboardShortcut("2")
                .disabled(model.sheetOpen)
            Button("Activity") { go(.activity) }
                .keyboardShortcut("3")
                .disabled(model.sheetOpen)
            Divider()
            Button("Rescan") {
                show()
                model.screen = .plan
                Task { await model.rescan() }
            }
            .keyboardShortcut("r")
            .disabled(model.isBusy || model.sheetOpen)
        }
        // No help book (its default item only says "Help isn't available"): the website instead.
        CommandGroup(replacing: .help) {
            Button("Outboard Help") { model.openWebsite() }
            Button("First-run Cards") {
                show()
                model.showFirstRun = true
            }
            .disabled(model.sheetOpen)
            Divider()
            // For testers: eligibility signals per drive and an errno matrix per measured folder, no file names.
            Button("Copy Diagnostics") { Task { await model.copyDiagnostics() } }
            Button("Report a Problem\u{2026}") { model.openIssues() }
        }
    }

    private func show() {
        openWindow(id: "main")
        activateApp()
    }

    private func go(_ screen: AppModel.Screen) {
        show()
        if model.screen != screen { model.screen = screen }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Mirrors "a moved folder is watched and Keep the guard running is on" (set by `AppModel`): closing the window then keeps
    /// the app alive so the menu bar item can reopen it.
    static var keepRunning = false
    /// Set by `AppModel` while a step runs that must not be cut in two (the switch, a confirm, a roll back, a forget): Command-Q
    /// and a closed window wait for it, and the user can quit again after. Copying and comparing are not such steps: the journal
    /// makes a quit there recoverable and the original is untouched until the switch.
    static var busy = false
    /// What to tell the person when a quit was held back (set by `AppModel`).
    static var onQuitBlocked: (@MainActor () -> Void)?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before SwiftUI creates the window; didFinish would be too late to drop the Tab menu items.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard Self.busy else { return .terminateNow }
        NSSound.beep()
        Self.onQuitBlocked?()
        return .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !Self.keepRunning }
}
