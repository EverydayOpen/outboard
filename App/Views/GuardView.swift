import OutboardCore
import SwiftUI

// docs/DESIGN.md §6.3 and §6.5: the guard's face. `GuardBannerStrip` says a drive is away, held or in conflict and offers the one
// action each banner needs; `GuardView` lists the moved folders with their Health, the actions on them, and the leftovers.
// Both read the one model (`AppModel.guardSnapshot`, `relocations`, `leftovers`). Written, not compiled.

// MARK: - What these screens may ask the system to do

/// Finder, System Settings, the browser and other apps are opened by `AppModel`/`Links`, the only files allowed to (grep G9).
/// The root hands these closures in with `.environment(\.systemActions, ...)`. A closure that is nil hides the control that
/// needs it, so no button here can do nothing. `reveal` takes a `~`-relative path, or an absolute one for a folder on a drive.
struct SystemActions {
    var reveal: ((_ path: String) -> Void)?
    var visit: ((_ url: URL) -> Void)?
    var launch: ((_ bundleID: String) -> Void)?
    var openPrivacySettings: (() -> Void)?
    var revealLog: (() -> Void)?

    init(reveal: ((_ path: String) -> Void)? = nil, visit: ((_ url: URL) -> Void)? = nil, launch: ((_ bundleID: String) -> Void)? = nil,
         openPrivacySettings: (() -> Void)? = nil, revealLog: (() -> Void)? = nil) {
        self.reveal = reveal
        self.visit = visit
        self.launch = launch
        self.openPrivacySettings = openPrivacySettings
        self.revealLog = revealLog
    }
}

private struct SystemActionsKey: EnvironmentKey {
    static let defaultValue = SystemActions()
}

extension EnvironmentValues {
    var systemActions: SystemActions {
        get { self[SystemActionsKey.self] }
        set { self[SystemActionsKey.self] = newValue }
    }
}

// MARK: - The banner strip

/// One strip at the top of every tab while `GuardSnapshot.banners` is not empty. The text is Core `BannerText`, exact. The strip
/// looks the same for "is back" and "was removed" (no colour, no slide, nothing shakes). A banner that has actions can be
/// answered; one that only describes a state stays until the state changes. "Leave it" answers hide a banner for this session.
struct GuardBannerStrip: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.systemActions) private var system
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dismissed: Set<String> = []
    @State private var request: RelocationActionRequest?

    var body: some View {
        let shown = model.guardSnapshot.banners.filter { !dismissed.contains($0.id) }
        VStack(spacing: Space.xs) {
            ForEach(shown) { banner in
                GuardBannerRow(banner: banner, busy: model.isBusy, actions: actions(of: banner)) { perform($0, banner) }
                    .transition(.opacity)
            }
        }
        .animation(Motion.standard(reduceMotion), value: shown.map(\.id))
        .sheet(item: $request) { RelocationActionSheet(request: $0) { request = nil } }
    }

    /// Only the answers this build can carry out. "Reconnect anyway" waits for an AppModel method (see the report).
    private func actions(of banner: Banner) -> [BannerAction] {
        banner.actions.filter { action in
            switch action {
            case .reconnectAnyway: return false
            case .showInFinder: return system.reveal != nil
            case .openPrivacySettings: return system.openPrivacySettings != nil
            default: return true
            }
        }
    }

    private func perform(_ action: BannerAction, _ banner: Banner) {
        switch action {
        case .checkAndReconnect:
            Task { for id in banner.moveIDs { await model.checkAndReconnect(moveID: id) } }
        case .setAsideAndReconnect:
            Task { for id in banner.moveIDs { await model.setAsideAndReconnect(moveID: id) } }
        case .forget:
            request = RelocationActionRequest(.forget, moveIDs: banner.moveIDs)
        case .showFiles:
            for id in banner.moveIDs {
                if let record = model.relocations.first(where: { $0.id == id }) { model.revealOnDrive(record) }
            }
        case .showInFinder:
            for id in banner.moveIDs {
                if let record = model.relocations.first(where: { $0.id == id }) { system.reveal?(record.macPath) }
            }
        case .openPrivacySettings:
            system.openPrivacySettings?()
        case .dismiss, .leaveAsIs, .leaveDisconnected:
            dismissed.insert(banner.id)
        case .reconnectAnyway:
            break
        }
    }
}

private struct GuardBannerRow: View {
    let banner: Banner
    let busy: Bool
    let actions: [BannerAction]
    let perform: (BannerAction) -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
        HStack(alignment: .top, spacing: Space.s) {
            Image(systemName: banner.kind.symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 20).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(banner.text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                if !actions.isEmpty {
                    FlowLayout(spacing: Space.xs, lineSpacing: Space.xs) {
                        ForEach(actions, id: \.self) { action in
                            if action == .checkAndReconnect {
                                Button(Self.label(action)) { perform(action) }.buttonStyle(MooringButtonStyle())
                            } else {
                                Button(Self.label(action)) { perform(action) }.buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }
                    .disabled(busy)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5).allowsHitTesting(false))
        .accessibilityElement(children: .contain)
    }

    static func label(_ action: BannerAction) -> String {
        switch action {
        case .checkAndReconnect: return "Check and reconnect"
        case .showFiles: return "Show files"
        case .reconnectAnyway: return "Reconnect anyway"
        case .leaveDisconnected: return "Leave disconnected"
        case .showInFinder: return "Show in Finder"
        case .setAsideAndReconnect: return "Set it aside and reconnect"
        case .leaveAsIs: return "Leave as it is"
        case .openPrivacySettings: return "Open System Settings"
        case .forget: return "Forget\u{2026}"
        case .dismiss: return "Dismiss"
        }
    }
}

// MARK: - Moved folders and leftovers

/// The Drives screen's lower half: every active relocation as a row (outline and tether, name, size, Health word, state word),
/// the actions each one allows, then the leftovers Outboard created and did not delete. Health is derived from the snapshot,
/// never stored; the pill carries the word, colour never carries it alone.
struct GuardView: View {
    @EnvironmentObject private var model: AppModel
    @State private var request: RelocationActionRequest?
    @State private var pending: Leftover?

    var body: some View {
        let active = model.relocations.filter { $0.state.isActive }
        let health = Dictionary(model.guardSnapshot.relocations.map { ($0.moveID, $0) }, uniquingKeysWith: { first, _ in first })
        VStack(alignment: .leading, spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Moved folders").font(.caption.weight(.semibold).smallCaps()).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                if active.isEmpty {
                    Text("Nothing has been moved yet. A folder you move to a drive is listed here.")
                        .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(active.enumerated()), id: \.element.id) { index, record in
                            if index > 0 { Divider() }
                            RelocationRow(record: record, health: health[record.id]) { request = $0 }
                        }
                    }
                    .padding(.vertical, Space.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .surface(16)
                }
            }
            if !model.leftovers.isEmpty {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Leftovers").font(.caption.weight(.semibold).smallCaps()).foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    VStack(spacing: 0) {
                        ForEach(Array(model.leftovers.enumerated()), id: \.element.id) { index, leftover in
                            if index > 0 { Divider() }
                            LeftoverRow(leftover: leftover) { pending = leftover }
                        }
                    }
                    .padding(.vertical, Space.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .surface(16)
                    Text("Outboard made these and has not deleted them. Moving one to the Trash is your choice.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .sheet(item: $request) { RelocationActionSheet(request: $0) { request = nil } }
        .confirmationDialog("Move to the Trash?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible, presenting: pending) { leftover in
            Button("Move to Trash") { Task { await model.trashLeftover(leftover.id) } }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { leftover in
            Text(trashMessage(leftover))
        }
    }

    private func trashMessage(_ leftover: Leftover) -> String {
        if leftover.onDrive {
            return "\(LeftoverWording.title(leftover)) goes to the Trash on \(leftover.volume?.label ?? "the drive"). The space comes back when that Trash is emptied."
        }
        return "\(LeftoverWording.title(leftover)) goes to the Trash. The space comes back when you empty it."
    }
}

// MARK: - One relocation

private struct RelocationRow: View {
    let record: RelocationRecord
    let health: RelocationHealth?
    let ask: (RelocationActionRequest) -> Void
    @EnvironmentObject private var model: AppModel
    @Environment(\.systemActions) private var system

    /// Where the text column starts: the outline and tether (22 + 14), the symbol well (28) and the gaps between them.
    private static let textInset: CGFloat = 36 + Space.s + 28 + Space.s

    private var drive: DriveFacts? { model.volumes.first { $0.uuid == record.volume.uuid } }
    private var onDrivePath: String? { drive.map { $0.mountPoint + "/" + record.relativePath } }
    private var leaf: String { record.flowLeafName }
    private var busy: Bool { model.isBusy }

    var body: some View {
        let h = health?.health
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .center, spacing: Space.s) {
                TetheredOutline(drawn: h == .healthy ? 1 : 0)
                Image(systemName: record.recipeID.symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    .well(Color.secondary, size: 28).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.recipeName).font(.system(size: 13, weight: .semibold))
                    Text("\(Format.bytes(record.logicalBytes)) \u{00B7} \(Format.count(record.fileCount, "file")) \u{00B7} on \(record.volume.label)")
                        .font(.system(size: 12, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
                    Text(record.macPath).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: Space.xs)
                VStack(alignment: .trailing, spacing: 4) {
                    if let h { Tag(h.displayName, tint: h.tint) } else { Tag("Checking") }
                    Text(record.state.displayName).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                trailing
            }
            if let line = detail {
                Text(line).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Self.textInset)
            }
            if record.isParked {
                NoteCard(text: PlaceholderText.body(driveName: record.volume.name))
                    .padding(.leading, Self.textInset)
            }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(record.recipeName), \(Format.bytes(record.logicalBytes)), \(h?.displayName ?? "Checking"), \(record.state.displayName)")
    }

    /// The next step when there is one, and the menu of the rest.
    @ViewBuilder private var trailing: some View {
        HStack(spacing: Space.xs) {
            if record.canConfirm {
                Button("Confirm\u{2026}") { ask(RelocationActionRequest(.confirm, moveIDs: [record.id])) }
                    .buttonStyle(.bordered).controlSize(.small).disabled(busy)
                    .help("Use the move for good and move the original to the Trash")
            }
            if health?.held == .uncleanRemoval || (record.isParked && record.needsCheckBeforeReconnect) {
                Button("Check and reconnect") { Task { await model.checkAndReconnect(moveID: record.id) } }
                    .buttonStyle(.bordered).controlSize(.small).disabled(busy)
                    .help("Compare every file that has not changed since it was copied, then reconnect")
            }
            if hasMenu {
                Menu {
                    if let path = onDrivePath, let reveal = system.reveal { Button("Show on drive") { reveal(path) } }
                    if record.canRollBack { Button("Roll back\u{2026}") { ask(RelocationActionRequest(.rollback, moveIDs: [record.id])) } }
                    if record.canReturn { Button("Return to Mac\u{2026}") { ask(RelocationActionRequest(.returnToMac, moveIDs: [record.id])) } }
                    if canForget {
                        Divider()
                        Button("Forget\u{2026}") { ask(RelocationActionRequest(.forget, moveIDs: [record.id])) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(busy)
                .help("Actions for \(record.recipeName)")
                .accessibilityLabel("Actions for \(record.recipeName)")
            }
        }
    }

    private var canForget: Bool { record.state == .confirmed || record.state == .originalTrashed }
    private var hasMenu: Bool {
        (onDrivePath != nil && system.reveal != nil) || record.canRollBack || record.canReturn || canForget
    }

    /// One quiet line under the row: what is kept, or why the row is held. Plain words; the banner carries the exact copy.
    private var detail: String? {
        if record.safetyCopy == .kept {
            return "Your original is kept on this Mac as \(leaf)\(Names.beforeMoveSuffix) (\(Format.bytes(record.logicalBytes))) until you confirm."
        }
        if let held = health?.held { return Self.heldSentence(held, app: record.flowAppName) }
        return nil
    }

    static func heldSentence(_ held: HeldReason, app: String) -> String {
        switch held {
        case .uncleanRemoval: return "The drive was removed without ejecting. Check your files before reconnecting."
        case .appRunning: return "Quit \(app) and Outboard will reconnect."
        case .sampleMismatch: return "Some files differ from when they were copied. Nothing has been reconnected."
        case .wrongDrive: return "A different drive with the same name is connected. Nothing has been changed."
        case .quickCheckFailed: return "The files on the drive don't match what was copied. Nothing has been reconnected."
        case .needsPermission: return "macOS blocked access to the drive."
        case .readOnlyOrLocked: return "The drive is locked or read-only."
        }
    }
}

// MARK: - One leftover

private enum LeftoverWording {
    /// "Incomplete copy from 3 Oct, 38 GB"
    static func title(_ leftover: Leftover) -> String {
        let what: String
        switch leftover.kind {
        case .incompleteCopy: what = "Incomplete copy"
        case .rolledBackCopy: what = "Copy kept after a roll back"
        case .safetyCopy: what = "Original kept on this Mac"
        case .driveCopyAfterReturn: what = "Copy left on the drive after a return"
        case .setAsideForeign: what = "Item set aside"
        }
        return "\(what) from \(Format.shortDate(leftover.createdAt)), \(Format.bytes(leftover.bytes))"
    }
}

private struct LeftoverRow: View {
    let leftover: Leftover
    let trash: () -> Void
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: Space.s) {
            Image(systemName: leftover.onDrive ? "externaldrive" : "folder").font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary).well(Color.secondary, size: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(LeftoverWording.title(leftover)).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Text(leftover.onDrive ? "On \(leftover.volume?.label ?? "the drive")" : "On this Mac")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Text(leftover.path).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: Space.xs)
            Button("Move to Trash\u{2026}") { trash() }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(model.isBusy)
                .help("Move this to the Trash. Outboard never deletes it.")
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .accessibilityElement(children: .contain)
    }
}
