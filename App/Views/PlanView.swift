import OutboardCore
import SwiftUI

// docs/DESIGN.md §6.5 (Plan), docs/MOTION.md §3.4. The home screen: the Storage Plan card as the one lifted object over the
// dusk wash, the headline figures beside it, then the ranked groups. Every number and word comes from the one model
// (`AppModel.plan`, Core `StoragePlanBuilder`, `StoragePlanText`); this file only lays it out. Written, not compiled.

struct PlanView: View {
    @EnvironmentObject private var model: AppModel
    /// The row whose "Move…" was pressed: the drive chooser is up for it. Choosing a drive opens the consent sheet.
    @State private var choosing: PlanItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                header
                if let plan = model.plan, let card = model.planCard {
                    PlanStage(card: card)
                    if model.hasRelocations { movedLine }
                    PlanGroups(plan: plan) { choosing = $0 }
                        .opacity(model.phase == .measuring ? 0.6 : 1)
                } else if model.phase == .measuring {
                    PlanNote(symbol: nil, title: "Measuring the big folders", detail: "Outboard reads sizes only. It opens no files.", busy: true)
                } else {
                    PlanNote(symbol: "square.grid.2x2", title: "Nothing measured yet",
                             detail: "Outboard looks first and changes nothing. Measuring reads the sizes of the folders it knows about.", busy: false) {
                        Button("Measure Now") { Task { await model.rescan() } }
                            .buttonStyle(MooringButtonStyle())
                            .disabled(model.isBusy)
                    }
                }
            }
            .padding(Space.xxl)
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background { Dusk(strength: 0.8) }
        .sheet(item: $choosing) { item in
            DrivePickerSheet(recipeID: item.recipeID) { drive in
                model.beginConsent(recipeID: item.recipeID, volumeID: drive.id)
            }
            .environmentObject(model)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text("Plan").font(.system(size: 28, weight: .semibold)).tracking(-0.5)
            Text("The big folders apps keep on this Mac, and what Outboard can do about each.")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// Moved folders live on the Drives screen, not here: the Plan is what is still to decide.
    private var movedLine: some View {
        HStack(spacing: Space.xs) {
            Text("Folders you moved are listed on the Drives screen.").font(.system(size: 13)).foregroundStyle(.secondary)
            Button("Show Drives") { model.screen = .drives }
                .buttonStyle(.borderless)
                .foregroundStyle(Brand.aquaInk)
        }
    }
}

// MARK: - The stage: the card and the headline figures

private struct PlanStage: View {
    let card: StoragePlanCard
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Side by side when the window is wide enough, stacked when it is not; the card never shrinks below 400pt.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Space.xxl) {
                column(width: 480)
                figures.frame(width: 200, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: Space.xl) {
                column(width: 400)
                figures
            }
        }
    }

    private func column(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            CardPreview(card: card, width: width).id(card.measuredAt)
            actions(width: width)
        }
        .frame(width: width, alignment: .leading)
    }

    /// Copy and save, only for a card worth sharing (not "Nothing big to move"), and Rescan.
    private func actions(width: CGFloat) -> some View {
        FlowLayout(spacing: Space.xs, lineSpacing: Space.xs) {
            if card.isShareable {
                Button { model.copyCardText() } label: { Text("Copy as Text") }
                    .buttonStyle(KeyCapStyle(compact: true))
                    .help("Copy the card as one line of text")
                Button { model.copyCardImage() } label: { Text("Copy as Image") }
                    .buttonStyle(KeyCapStyle(compact: true))
                    .help("Copy the card as a picture")
                Button { model.saveCardPNG() } label: { Text("Save PNG\u{2026}") }
                    .buttonStyle(KeyCapStyle(compact: true))
                    .help("Save the card as a picture")
            }
            Button { Task { await model.rescan() } } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                .buttonStyle(.bordered)
                .capsuleBorder()
                .disabled(model.isBusy)
                .help("Measure the folders again (Command-R)")
            if model.phase == .measuring {
                ProgressView().controlSize(.small).accessibilityLabel("Measuring")
            }
        }
        .frame(width: width, alignment: .leading)
    }

    /// The headline numbers. They come from the card's own total, so the figure here and the headline on the card cannot differ.
    private var figures: some View {
        let unmeasured = model.plan?.items.filter { $0.status == .notMeasured && $0.kind != .guided }.count ?? 0
        let headline = Self.headline(card, moved: model.movedBytes, unmeasured: unmeasured)
        let found = model.plan?.items.filter { item in item.scans.contains { $0.state == .measured || $0.state == .atLeast } }.count ?? 0
        return VStack(alignment: .leading, spacing: Space.l) {
            Metric(headline.label, headline.value, unit: headline.unit, size: 40)
            Metric("Measured", Format.number(found), unit: found == 1 ? "folder" : "folders")
            (Text("Measured at ") + Text(card.measuredAt, style: .time))
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .animation(Motion.standard(reduceMotion), value: card.totalBytes)
    }

    private static func headline(_ card: StoragePlanCard, moved: UInt64, unmeasured: Int) -> (label: String, value: String, unit: String) {
        switch card.variant {
        case .plan, .planWithGuided:
            return ("Could free up to", Format.number(Format.gigabytesRounded([card.totalBytes]).first ?? 0), "GB")
        case .partlyMeasured:
            // Unmeasured folders may hold more, so the figure is not an upper bound; with nothing measured there is no figure at all.
            if card.totalBytes == 0 { return ("Not measured", Format.number(unmeasured), unmeasured == 1 ? "folder" : "folders") }
            return ("Measured so far", Format.number(Format.gigabytesRounded([card.totalBytes]).first ?? 0), "GB")
        case .afterMoves:
            let f = byteFigure(moved)
            return ("Moved", f.value, f.unit)
        case .small, .nothingFound:
            let f = byteFigure(card.totalBytes)
            return ("Movable now", f.value, f.unit)
        }
    }
}

/// "3.1 GB" -> ("3.1", "GB"); "999 bytes" -> ("999", "bytes"). Also the Drives screen's Moved figure.
func byteFigure(_ bytes: UInt64) -> (value: String, unit: String) {
    let parts = Format.bytes(bytes).split(separator: " ", maxSplits: 1).map(String.init)
    return parts.count == 2 ? (parts[0], parts[1]) : (Format.bytes(bytes), "")
}

/// The card on screen: the art scaled to `width`, dealt once per measurement (it turns over into place), then tilting a few
/// degrees toward the pointer. Flat and still under Reduce Motion. `.id(card.measuredAt)` at the call site makes a new
/// measurement a new deal. One of the three views in the app that tilt (MOTION §3.5).
private struct CardPreview: View {
    let card: StoragePlanCard
    let width: CGFloat
    @State private var dealt = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PlanCardView(card: card, width: width)
            .modifier(FlipFaces(angle: dealt || reduceMotion ? 0 : 180, back: CardBack()))
            .modifier(HoverTilt(max: 4, glare: true))
            .lifted()
            .animation(Motion.spring(reduceMotion), value: dealt)
            .task {
                try? await Task.sleep(nanoseconds: 100_000_000)
                dealt = true
            }
    }
}

// MARK: - Empty and measuring states

/// A quiet centred note with an optional action: measuring, or nothing measured yet. No illustration.
private struct PlanNote<Action: View>: View {
    let symbol: String?
    let title: String
    let detail: String
    let busy: Bool
    let action: Action

    init(symbol: String?, title: String, detail: String, busy: Bool, @ViewBuilder action: () -> Action) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.busy = busy
        self.action = action()
    }

    var body: some View {
        VStack(spacing: Space.s) {
            if busy { ProgressView().controlSize(.regular) }
            if let symbol { Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(.secondary).accessibilityHidden(true) }
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            action
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.xxxl)
        .accessibilityElement(children: .contain)
    }
}

extension PlanNote where Action == EmptyView {
    init(symbol: String?, title: String, detail: String, busy: Bool) {
        self.init(symbol: symbol, title: title, detail: detail, busy: busy) { EmptyView() }
    }
}

// MARK: - The ranked groups

/// Movable, then the fixed line about System Data, guided, not measured, hidden until tried, also checked, never. Rows keep the
/// order `StoragePlanBuilder` gave them (movable by bytes, largest first).
private struct PlanGroups: View {
    let plan: StoragePlan
    let choose: (PlanItem) -> Void
    @EnvironmentObject private var model: AppModel

    private var movable: [PlanItem] { plan.items.filter { $0.status == .movable } }
    private var guided: [PlanItem] { plan.items.filter { $0.status == .guided } }
    private var notMeasured: [PlanItem] { plan.items.filter { $0.status == .notMeasured } }
    private var hidden: [PlanItem] { plan.items.filter { $0.status == .hiddenUntilVerified } }
    private var never: [PlanItem] { plan.items.filter { $0.status == .neverMove } }
    private var checked: [PlanItem] {
        plan.items.filter { $0.status == .belowThreshold || $0.status == .alreadyMoved || $0.status == .needsNewerMacOS }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            if !movable.isEmpty {
                PlanSection(title: "Movable folders", note: "Pressing Move shows what will change, and nothing changes until you agree.") {
                    rows(movable) { PlanRow(item: $0, accessory: .move, act: choose) }
                }
            }
            // The fixed line between what can move and what cannot; with nothing movable it would be an orphan under the card.
            if !movable.isEmpty {
                Text(Education.somethingNotMovable).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            if !guided.isEmpty {
                PlanSection(title: "Guided by the app", note: "These apps move their own data. Outboard shows the steps and checks the drive.") {
                    rows(guided) { PlanRow(item: $0, accessory: .steps, act: choose) }
                }
            }
            if !notMeasured.isEmpty {
                PlanSection(title: "Not measured") {
                    rows(notMeasured) { NotMeasuredRow(item: $0) }
                }
            }
            if !hidden.isEmpty { hiddenNote }
            if !checked.isEmpty {
                PlanSection(title: "Also checked") {
                    rows(checked) { CheckedRow(item: $0) }
                }
            }
            if !never.isEmpty {
                PlanSection(title: "Never moved", note: "Moving these can break an app or lock you out, so Outboard won't touch them.") {
                    rows(never) { NeverRow(item: $0) }
                }
            }
        }
    }

    /// Rows with a hairline between them, inset past the symbol well.
    private func rows<Row: View>(_ items: [PlanItem], @ViewBuilder row: @escaping (PlanItem) -> Row) -> some View {
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            if index > 0 { Divider().padding(.leading, Space.m + 32 + Space.s) }
            row(item)
        }
    }

    /// Every automated move is hidden until a named tester has tried it on a real Mac (BUILD_PLAN section 2). Say so, and say how
    /// to see them, so an empty list never looks like a Mac with nothing to move.
    private var hiddenNote: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(Names.notTriedMarker).font(.system(size: 15, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Text("\(hidden.count == 1 ? "This move is" : "These moves are") hidden: \(hidden.map(\.name).joined(separator: ", ")). Turn on Show moves not yet tried on a real Mac in Preferences to see \(hidden.count == 1 ? "it" : "them").")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Open Preferences") { model.showPreferences = true }
                .buttonStyle(.bordered)
                .disabled(model.isBusy)
        }
        .padding(.horizontal, Space.xs)
        .accessibilityElement(children: .contain)
    }
}

/// One group: a title and a line under it, then the rows on one porcelain plate with the layered rims.
private struct PlanSection<Content: View>: View {
    let title: String
    let note: String?
    let content: Content

    init(title: String, note: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.note = note
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold)).accessibilityAddTraits(.isHeader)
                if let note {
                    Text(note).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, Space.xs)
            VStack(spacing: 0) { content }
                .padding(.vertical, Space.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .surface(Radius.plate)
                .moored()
        }
    }
}

// MARK: - Rows

/// What a row says about its size: the figure, "at least" the figure when the walk was cut short, "not measured", or nothing
/// when the folder is not on this Mac.
private func sizeText(_ item: PlanItem) -> String? {
    if item.status == .notMeasured { return "not measured" }
    let present = item.scans.filter { $0.state != .absent }
    if present.isEmpty { return nil }
    return Format.size(item.allocatedBytes, atLeast: item.isLowerBound)
}

/// The folder as the plan shows it: `~`-relative, the first part that is on this Mac.
private func pathText(_ item: PlanItem) -> String? {
    item.scans.first { $0.state != .absent }?.path
}

/// A movable or a guided row: the symbol in a neutral well, the name, the folder, the size, the method and risk chips (words
/// only; a "Community method" row is set exactly like an "Official setting" one), what happens if the drive goes away, and the one
/// button the row offers. VoiceOver reads "Name, size, method, risk" and finds the button separately.
private struct PlanRow: View {
    enum Accessory { case move, steps }

    let item: PlanItem
    let accessory: Accessory
    let act: (PlanItem) -> Void
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            Image(systemName: item.recipeID.symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                .well(Color.secondary, size: 32).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text(item.name).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Space.xs)
                    if let size = sizeText(item) {
                        Text(size).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit().fixedSize()
                    }
                }
                if let path = pathText(item) {
                    Text(path).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                FlowLayout(spacing: 6, lineSpacing: 4) {
                    Tag(item.kind.displayName)
                    Tag(item.risk.displayName)
                }
                .padding(.vertical, 2)
                Text(effectLine)
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if showsNotTried {
                    Text(Names.notTriedMarker).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            VStack {
                switch accessory {
                case .move:
                    Button("Move\u{2026}") { act(item) }
                        .buttonStyle(.bordered)
                        .disabled(model.isBusy)
                        .help("Choose a drive for \(item.name)")
                case .steps:
                    Button("Show Steps") { model.showGuide(recipeID: item.recipeID) }
                        .buttonStyle(.bordered)
                        .help("Steps for \(item.name), and what the chosen drive's checks say")
                }
            }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .accessibilityElement(children: .contain)
    }

    private var effectLine: String {
        accessory == .steps ? "The app moves this itself. Outboard shows the steps." : item.missingDriveEffect
    }

    private var showsNotTried: Bool { item.isUnverified && accessory == .move }

    /// "Name, size, method, risk", then what a sighted person reads before pressing the button: what happens if the drive goes
    /// away, and the not-tried note.
    private var label: String {
        var parts: [String?] = [item.name, sizeText(item), item.kind.displayName, item.risk.displayName, effectLine]
        if showsNotTried { parts.append(Names.notTriedMarker) }
        return parts.compactMap { $0 }.joined(separator: ", ")
    }
}

/// A folder macOS would not let Outboard read, or that could not be read: said in words, with the steps behind a disclosure and a
/// button that opens System Settings. Never nagged: the row appears only when there is such a folder.
private struct NotMeasuredRow: View {
    let item: PlanItem
    @EnvironmentObject private var model: AppModel

    private var needsAccess: Bool { item.notMeasuredReason == .needsFullDiskAccess }

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            Image(systemName: item.recipeID.symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                .well(Color.secondary, size: 32).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.name).font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: Space.xs)
                    Text("not measured").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                }
                Text(reason).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if needsAccess {
                    DisclosureGroup("How to allow it") {
                        Text(Education.fullDiskAccessSteps).font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).padding(.top, Space.xxs)
                    }
                    .font(.system(size: 12))
                    Button("Open System Settings") { model.openFullDiskAccessSettings() }
                        .buttonStyle(.bordered)
                        .help("Opens Privacy & Security in System Settings")
                }
            }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .accessibilityElement(children: .contain)
    }

    private var reason: String {
        switch item.notMeasuredReason {
        case .needsFullDiskAccess: return "Needs Full Disk Access to be measured."
        case .denied: return "macOS didn't let Outboard read this folder."
        case .failed: return "This folder couldn't be read."
        case .alreadyRedirected, nil: return "This folder couldn't be measured."
        }
    }
}

/// A line for something that was looked at and is not offered: under the threshold, already moved, or needs a newer macOS.
private struct CheckedRow: View {
    let item: PlanItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Image(systemName: item.recipeID.symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 32).accessibilityHidden(true)
            Text(sentence).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.xs)
        .accessibilityElement(children: .combine)
    }

    private var sentence: String {
        switch item.status {
        case .belowThreshold: return "\(item.name): \(Format.bytes(item.allocatedBytes)), under the \(Format.bytes(Limits.minOfferBytes)) Outboard offers."
        case .alreadyMoved: return "\(item.name): already moved."
        case .needsNewerMacOS:
            let needs = Catalogue.recipe(item.recipeID)?.minMacOS?.displayName ?? "a newer macOS"
            return "\(item.name): needs \(needs) or later."
        default: return item.name
        }
    }
}

/// A "never" card: the hand symbol, the name and the reason in the catalogue's words. No button.
private struct NeverRow: View {
    let item: PlanItem

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            Image(systemName: "hand.raised").font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                .well(Color.secondary, size: 32).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.system(size: 13, weight: .semibold))
                if let reason = item.neverReason {
                    Text(reason).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .accessibilityElement(children: .combine)
    }
}
