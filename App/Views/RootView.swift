import AppKit
import OutboardCore
import SwiftUI

/// The window's content: one `NavigationSplitView` (Plan, Drives, Activity; About from the app menu) under one toolbar, the guard's
/// banner strip above every screen, a cover until the journal has been read and the guard has made its first pass, and every
/// sheet, one at a time and in one place. Hosting them here means they show on any screen.
///
/// The window keeps the scene's title ("Outboard"): no screen sets `navigationTitle`, because the demo recorder finds the window
/// by that title (App/Demo.swift).
struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One sheet at a time, in the order of `sheet`'s getter. The move sheet is one sheet for the consent, the progress, "The move is
    /// ready" and the result, so the content changes in place: a sheet that opens as another closes can be dropped on macOS.
    private enum ActiveSheet: Hashable, Identifiable {
        case firstRun, move, guided, report, preferences
        var id: Self { self }
    }

    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            VStack(spacing: 0) {
                // Appears and disappears with a fade; "is back" looks exactly like "was removed" (MOTION section 3.6).
                if !model.guardSnapshot.banners.isEmpty {
                    GuardBannerStrip()
                        .padding(.horizontal, Space.xl)
                        .padding(.top, Space.s)
                        .transition(.opacity)
                }
                screenView
            }
            .animation(Motion.standard(reduceMotion), value: model.guardSnapshot.banners.map(\.id))
        }
        .frame(minWidth: 820, minHeight: 600)
        .toolbar { toolbar }
        .noticePill(model)
        .overlay { startupCover }
        .animation(Motion.standard(reduceMotion), value: model.isReady)
        .sheet(item: sheet) { which in sheetContent(which).noticePill(model) }
        .environment(\.systemActions, systemActions)
        .task { await model.start() }
    }

    // MARK: - Sidebar and screens

    private var sidebar: some View {
        List(selection: selection) {
            Label("Plan", systemImage: "square.grid.2x2").tag(AppModel.Screen.plan)
            Label("Drives", systemImage: "externaldrive")
                .badge(model.attentionCount)
                .accessibilityValue(model.attentionCount == 0 ? "" : "\(model.attentionCount) need attention")
                .tag(AppModel.Screen.drives)
            Label("Activity", systemImage: "list.bullet.rectangle").tag(AppModel.Screen.activity)
        }
        .listStyle(.sidebar)
    }

    /// About is reached from the app menu and has no sidebar row, so nothing is selected there. The setter writes only a change.
    private var selection: Binding<AppModel.Screen?> {
        Binding(get: { model.screen == .about ? nil : model.screen },
                set: { next in
                    if let next, next != model.screen { model.screen = next }
                })
    }

    @ViewBuilder private var screenView: some View {
        switch model.screen {
        case .plan: PlanView()
        case .drives: DrivesView()
        case .activity: ActivityView()
        case .about: AboutView()
        }
    }

    // MARK: - Toolbar and cover

    /// The sample-data badge (demo launches only) and Preferences. Rescan lives on the Plan, next to the card.
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if model.isDemo { Tag("Sample data") }
            Button { model.showPreferences = true } label: { Label("Preferences", systemImage: "gearshape") }
                .disabled(model.isBusy)
                .help("Preferences")
        }
    }

    /// Until `start()` has read the journal and made the guard's first pass (recovery runs there): nothing to act on yet.
    @ViewBuilder private var startupCover: some View {
        if !model.isReady {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                VStack(spacing: Space.s) {
                    ProgressView().controlSize(.regular)
                    Text("Checking your drives\u{2026}").font(.callout).foregroundStyle(.secondary)
                }
            }
            .ignoresSafeArea()
            .transition(.opacity)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - What the screens may ask the system to do

    /// The only way the screens reach Finder, System Settings, the browser and other apps: through the model (safety_greps G9).
    private var systemActions: SystemActions {
        SystemActions(reveal: { model.reveal($0) },
                      visit: { model.openLink($0) },
                      launch: { model.openApp(bundleID: $0) },
                      openPrivacySettings: { model.openPrivacySettings() },
                      revealLog: { model.revealLog() })
    }

    // MARK: - Sheets

    /// In order: the first-run cards (until Done; reopened from Help they can be dismissed), the move (consent, progress, "ready to
    /// confirm", result), the guided card, the report, Preferences. Esc cancels a consent, closes a result or "ready to confirm"
    /// (the move then stays Ready to confirm) or closes a sheet; nothing closes the first run or a move in progress.
    private var sheet: Binding<ActiveSheet?> {
        Binding(
            get: {
                if !model.prefs.hasSeenFirstRun || model.showFirstRun { return .firstRun }
                switch model.phase {
                case .consenting, .running, .tryAndConfirm, .result: return .move
                case .idle, .measuring: break
                }
                if model.guideRecipeID != nil { return .guided }
                if model.showReport { return .report }
                if model.showPreferences { return .preferences }
                return nil
            },
            set: { next in
                guard next == nil, model.prefs.hasSeenFirstRun else { return }
                if model.showFirstRun {
                    model.showFirstRun = false
                    return
                }
                switch model.phase {
                case .consenting:
                    model.cancelConsent()
                    return
                case .tryAndConfirm, .result:
                    model.dismissResult()
                    return
                case .running:
                    return
                case .idle, .measuring:
                    break
                }
                if model.guideRecipeID != nil {
                    model.guideRecipeID = nil
                } else if model.showReport {
                    model.showReport = false
                } else if model.showPreferences {
                    model.showPreferences = false
                }
            })
    }

    @ViewBuilder private func sheetContent(_ which: ActiveSheet) -> some View {
        switch which {
        case .firstRun:
            FirstRunView().environmentObject(model).environment(\.systemActions, systemActions)
        case .move:
            Group {
                if case .consenting(let recipeID, let volumeID) = model.phase {
                    MoveConsentView(recipeID: recipeID, volumeID: volumeID)
                } else {
                    MoveFlowView()
                }
            }
            .environmentObject(model)
            .environment(\.systemActions, systemActions)
        case .guided:
            if let id = model.guideRecipeID {
                GuidedMoveSheet(recipeID: id).environmentObject(model).environment(\.systemActions, systemActions)
            }
        case .report:
            ReportSheet().environmentObject(model)
        case .preferences:
            PreferencesSheet().environmentObject(model).environment(\.systemActions, systemActions)
        }
    }
}

// MARK: - The notice

/// A one-line message ("Diagnostics copied."): a pill on the controls layer that clears itself. Applied to the window and to every
/// sheet, because a sheet covers the window's pill and feedback posted while one is up would not be seen.
private struct NoticePill: ViewModifier {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) { pill }
            .animation(Motion.standard(reduceMotion), value: model.notice)
    }

    @ViewBuilder private var pill: some View {
        if let text = model.notice {
            HStack(spacing: Space.s) {
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
                Button { model.notice = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.xs)
            .barSurface(radius: Radius.plate)
            .padding(.top, Space.s)
            .transition(.opacity)
        }
    }
}

extension View {
    func noticePill(_ model: AppModel) -> some View { modifier(NoticePill(model: model)) }
}

/// File > Export Report (Command-E): the report as it would be saved, Markdown or JSON, with the one choice that changes it. It is
/// made from the records and the journal on this Mac, goes through a save panel and is never uploaded. The Activity screen's
/// Export menu saves the same report without the preview.
private struct ReportSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var format = ExportFormat.markdown

    var body: some View {
        let document = model.reportDocument(hidePaths: model.prefs.hideFolderPathsInExports)
        let text = format == .json ? ReportText.json(document) : ReportText.markdown(document)
        VStack(alignment: .leading, spacing: Space.m) {
            SheetHeader(symbol: "doc.text", title: "Export Report", detail: "What Outboard did and checked, as a file you keep. It is made on this Mac and saved where you choose.")
            Picker("Format", selection: $format) {
                Text("Markdown").tag(ExportFormat.markdown)
                Text("JSON").tag(ExportFormat.json)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Toggle("Hide folder paths", isOn: $model.prefs.hideFolderPathsInExports)
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.s)
            }
            .frame(height: 220)
            .terminal()
            HStack {
                Spacer()
                Button("Done", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save\u{2026}") { model.exportReport(format: format) }
                    .buttonStyle(MooringButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.xl)
        .frame(width: 520)
        .background(Dusk(strength: 0.5))
    }
}
