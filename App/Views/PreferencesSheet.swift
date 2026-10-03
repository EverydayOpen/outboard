import OutboardCore
import SwiftUI

// docs/DESIGN.md §6.5 (Preferences). A stock grouped Form in a sheet, as tall as its content and scrolling only past the cap.
// Every switch is `model.prefs`, which the model stores; none of them can make Outboard do more than its rules allow. Written,
// not compiled.

struct PreferencesSheet: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        // The first layout is the form at its own height; when that is taller than the cap, the second scrolls it.
        // VERIFY on a Mac that a grouped Form with scrolling off reports its content height on macOS 13.
        ViewThatFits(in: .vertical) {
            VStack(spacing: 0) {
                form.scrollDisabled(true).fixedSize(horizontal: false, vertical: true)
                bar
            }
            VStack(spacing: 0) {
                form
                bar
            }
        }
        .frame(width: 480)
        .frame(maxHeight: 560)
    }

    private var form: some View {
        Form {
            Section {
                Toggle(isOn: loginItem) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Start Outboard at login")
                        Text(Self.word(model.loginItem)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if model.loginItem == .requiresApproval {
                    Text(Education.loginItemNeedsApproval).font(.caption).foregroundStyle(.secondary)
                    Button("Open Login Items") { model.openLoginItemsSettings() }
                }
                Toggle("Keep the guard running when the window closes", isOn: $model.prefs.keepGuardRunning)
            } footer: {
                Text("While Outboard runs it watches your drives. \(Education.guardQuit)")
            }
            Section {
                Toggle("Show moves not yet tried on a real Mac", isOn: $model.prefs.showUnverifiedMoves)
            } footer: {
                Text("\(Names.notTriedMarker) Those moves stay hidden unless this is on, and their sheets say so.")
            }
            Section {
                Toggle("Hide folder paths in exports", isOn: $model.prefs.hideFolderPathsInExports)
                Toggle("Show app names on the card", isOn: $model.prefs.showAppNamesOnCard)
            } footer: {
                Text("Exports are made on this Mac and saved where you choose. The card never shows a drive's name.")
            }
            Section {
                LabeledContent("Updates") { Button("Check for Updates\u{2026}") { model.openReleases() } }
            } footer: {
                Text("Outboard makes no connections of its own. This opens the releases page in your browser.")
            }
        }
        .formStyle(.grouped)
    }

    private var bar: some View {
        HStack {
            Spacer()
            Button("Done") { model.showPreferences = false }
                .buttonStyle(MooringButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
        .padding(Space.m)
    }

    /// On while registered (including waiting for the person's OK in System Settings). Writes only when the person changes it.
    private var loginItem: Binding<Bool> {
        Binding(get: { model.loginItem == .enabled || model.loginItem == .requiresApproval },
                set: { on in model.setLoginItem(on) })
    }

    private static func word(_ state: LoginItemState) -> String {
        switch state {
        case .enabled: return "On"
        case .notRegistered: return "Off"
        case .requiresApproval: return "Waiting for your OK"
        case .notFound: return "Not found. Turn it on again to register it."
        case .unavailable: return "macOS didn't allow it"
        }
    }
}
