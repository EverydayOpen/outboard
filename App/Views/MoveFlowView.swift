import OutboardCore
import SwiftUI

// docs/DESIGN.md §6.5 (Progress, Try it and confirm, Result) and docs/MOTION.md §3. The move's own pages, one sheet that follows
// `AppModel.phase`, plus the four decisions a person takes on a relocation afterwards: confirm (original to the Trash), roll back,
// return to Mac and forget. Every number comes from `MoveProgress`, `MoveOutcome` or the `RelocationRecord`; nothing is estimated.
// Written, not compiled.

// MARK: - The sheet that follows the phase

/// Presented by the root while `MoveFlowView.shows(model.phase)`. It never closes itself: "Done" and "Not yet" call
/// `AppModel.dismissResult()`. "Stop" (`AppModel.stopMove`) is offered only for a move that has not reached the switch.
struct MoveFlowView: View {
    @EnvironmentObject private var model: AppModel

    /// The phases this view draws. The root's sheet binding is `MoveFlowView.shows(model.phase)`.
    static func shows(_ phase: AppModel.Phase) -> Bool {
        switch phase {
        case .running, .tryAndConfirm, .result: return true
        default: return false
        }
    }

    var body: some View {
        switch model.phase {
        case .running(let progress): ProgressPage(progress: progress)
        case .tryAndConfirm(let moveID): TryItPage(moveID: moveID)
        case .result(let outcome): ResultPage(outcome: outcome)
        default: EmptyView()
        }
    }
}

/// A sheet that opens right as another closes can be dropped on macOS, so work that starts a new sheet waits for the old one to
/// leave. VERIFY on a Mac: the delay, and whether it is needed at all.
@MainActor func afterSheetCloses(_ work: @escaping @MainActor () async -> Void) {
    Task {
        try? await Task.sleep(nanoseconds: 350_000_000)
        await work()
    }
}

extension RelocationRecord {
    /// The name of the folder on the Mac: `DerivedData`.
    var flowLeafName: String { macPath.split(separator: "/").last.map(String.init) ?? macPath }
    /// The app the person opens to check the data: "Xcode", "Ollama", "Finder".
    var flowAppName: String {
        Catalogue.recipe(recipeID).map { GuidedText.card(recipe: $0, drive: nil).appName } ?? recipeName
    }
}

// MARK: - Shared pieces

/// The page and its action bar (also the consent sheet's). Sized to content: when the page is taller than the sheet's cap only the page scrolls and the bar
/// stays below it. No fixed height, so no dead space.
struct MoveSheetFrame<Page: View, Bar: View>: View {
    let page: Page
    let bar: Bar

    init(@ViewBuilder page: () -> Page, @ViewBuilder bar: () -> Bar) {
        self.page = page()
        self.bar = bar()
    }

    var body: some View {
        ViewThatFits(in: .vertical) {
            VStack(spacing: 0) {
                page
                bar
            }
            VStack(spacing: 0) {
                ScrollView { page }
                bar
            }
        }
        .frame(width: 520)
        .frame(maxHeight: 640)
    }
}

/// The three-line space ledger (`ConsentSheetText.ledger`): the label and the amount, the note beneath. Nothing truncates.
struct MoveLedgerRows: View {
    let lines: [LedgerLine]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                        Text(line.label).font(.system(size: 13))
                        Spacer(minLength: Space.xs)
                        Text(line.amount).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                    }
                    if !line.note.isEmpty {
                        Text(line.note).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(16)
    }
}

/// The ledger for a record. Free space the Mac layer could not read is left out of the note rather than shown as 0.
private func flowLedger(_ record: RelocationRecord, volumes: [DriveFacts], state: MoveState) -> [LedgerLine] {
    let free = volumes.first { $0.uuid == record.volume.uuid }.flatMap { Eligibility.effectiveAvailable($0) }
    var lines = ConsentSheetText.ledger(bytes: record.logicalBytes, drive: record.volume, free: free ?? 0, state: state, leaf: record.flowLeafName)
    if free == nil, !lines.isEmpty { lines[0].note = "" }
    return lines
}

/// "Before you start": the apps that must be closed, read fresh. Nothing here quits anything. A row Outboard can't read blocks.
struct MoveBlockerRows: View {
    let recipeIDs: [RecipeID]
    @EnvironmentObject private var model: AppModel

    var body: some View {
        var seen: Set<String> = []
        let blockers = recipeIDs.flatMap { model.blockers(for: $0) }.filter { seen.insert($0.id).inserted }
        if !blockers.isEmpty {
            VStack(alignment: .leading, spacing: Space.s) {
                Text("Before you start").font(.caption.weight(.semibold).smallCaps()).foregroundStyle(.secondary)
                ForEach(blockers) { blocker in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(blocker.name).font(.system(size: 13, weight: .semibold))
                            Spacer(minLength: Space.xs)
                            Text(Self.word(blocker.state)).font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                        if let line = Self.line(blocker) {
                            Text(line).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(16)
        }
    }

    static func word(_ state: RunState) -> String {
        switch state {
        case .running: return "Running"
        case .notRunning: return "Not running"
        case .unknown: return "Can't tell"
        }
    }

    static func line(_ blocker: Blocker) -> String? {
        switch blocker.state {
        case .running: return "Quit \(blocker.name) to continue."
        case .notRunning: return nil
        case .unknown: return "Outboard can't tell whether \(blocker.name) is running, so it waits."
        }
    }
}

private func flowElapsed(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.rounded()))
    if s < 60 { return "\(s) s" }
    if s < 3600 {
        let m = s / 60, r = s % 60
        return r == 0 ? "\(m) min" : "\(m) min \(r) s"
    }
    let h = s / 3600, m = (s % 3600) / 60
    return m == 0 ? "\(h) h" : "\(h) h \(m) min"
}

// MARK: - Progress

/// Copying by bytes and elapsed time, comparing by files; no estimate and no rate anywhere. The bar moves only when
/// `MoveProgress` changes (the backend polls every 500 ms); the system spinner covers the phases that have no count.
private struct ProgressPage: View {
    let progress: MoveProgress
    @EnvironmentObject private var model: AppModel
    @State private var stopping = false

    private var record: RelocationRecord? { model.relocations.first { $0.id == progress.moveID } }
    private var name: String { record?.recipeName ?? "your folder" }
    private var action: MoveActionKind { model.activeAction }

    private var determinate: Bool {
        (progress.phase == .copying && progress.bytesTotal > 0) || (progress.phase == .verifying && progress.filesTotal > 0)
    }

    /// Stop is offered only for a move, and only before the switch. `AppModel.stopMove` cancels the task that runs the move, so a
    /// return or a check (which have no such task) offers nothing to press.
    private var canStop: Bool {
        guard action == .move else { return false }
        return progress.phase == .preflight || progress.phase == .copying || progress.phase == .verifying
    }

    private var title: String {
        switch (action, progress.phase) {
        case (.returnToMac, .copying): return "Returning \(name) to this Mac"
        case (.returnToMac, .swapping), (.returnToMac, .finishing): return "Putting \(name) back on this Mac"
        case (.checkAndReconnect, .swapping), (.checkAndReconnect, .finishing): return "Reconnecting \(name)"
        case (_, .preflight): return "Checking \(name)"
        case (_, .copying): return "Copying \(name)"
        case (_, .verifying): return "Comparing \(name)"
        case (_, .swapping): return "Switching to the copy"
        case (_, .finishing): return "Finishing"
        }
    }

    private var detail: String {
        let elapsed = "\(flowElapsed(progress.elapsedSeconds)) elapsed"
        switch progress.phase {
        case .copying: return "\(Format.bytes(progress.bytesDone)) of \(Format.bytes(progress.bytesTotal)) \u{00B7} \(elapsed)"
        case .verifying: return "\(Format.number(progress.filesDone)) of \(Format.count(progress.filesTotal, "file")) compared \u{00B7} \(elapsed)"
        default: return elapsed
        }
    }

    /// What is true while this runs. A move changes nothing on the Mac until the comparison has passed.
    private var reassurance: String? {
        switch action {
        case .move:
            if progress.phase == .swapping || progress.phase == .finishing { return "Your original is kept on this Mac until you confirm." }
            return "Your folder on this Mac isn't changed until the copy has been compared."
        case .returnToMac:
            return record.map { "The copy on \($0.volume.label) stays where it is." }
        case .checkAndReconnect:
            return "Outboard reconnects \(name) only if the files match."
        default:
            return nil
        }
    }

    var body: some View {
        MoveSheetFrame {
            VStack(alignment: .leading, spacing: Space.m) {
                HStack(spacing: Space.s) {
                    if !determinate { ProgressView().controlSize(.small) }
                    Text(title).font(.system(size: 22, weight: .semibold)).tracking(-0.3).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: Space.xs) {
                    if determinate { FlowBar(fraction: progress.fraction) }
                    Text(detail).font(.system(size: 13, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityValue(detail)
                if let note = progress.note {
                    Text(note).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let reassurance {
                    Text(reassurance).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        } bar: {
            if canStop {
                HStack {
                    Spacer()
                    if stopping {
                        Text("Stopping\u{2026}").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Button("Stop") {
                        stopping = true
                        model.stopMove()
                    }
                    .buttonStyle(.bordered)
                    .disabled(stopping)
                    .help("Stop this move. Your folder on this Mac is not changed before the switch.")
                }
                .padding(Space.xl)
            }
        }
        .interactiveDismissDisabled()
    }
}

/// A capsule filled in proportion to `fraction`: pure shapes, so nothing animates unless the number changes.
private struct FlowBar: View {
    let fraction: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let increased = contrast == .increased
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(increased ? Color.primary : Brand.aqua).frame(width: g.size.width * min(max(fraction, 0), 1))
            }
            .overlay(Capsule().strokeBorder(Color.primary.opacity(increased ? 0.6 : 0.1), lineWidth: increased ? 1 : 0.5))
        }
        .frame(height: 10)
        .animation(Motion.standard(reduceMotion), value: fraction)
    }
}

// MARK: - Try it and confirm

/// "The move is ready. Open Xcode and check your data." The tether draws once. The original is still on the Mac, renamed; the
/// ledger says so, and nothing here is final until the person confirms.
private struct TryItPage: View {
    let moveID: String
    @EnvironmentObject private var model: AppModel
    @Environment(\.systemActions) private var system
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = 0.0

    private var record: RelocationRecord? { model.relocations.first { $0.id == moveID } }

    var body: some View {
        Group {
            if let record {
                if model.showConfirmDialog {
                    RelocationActionPage(kind: .confirm, records: [record], sheetMode: false) { model.showConfirmDialog = false }
                } else {
                    page(record)
                }
            } else {
                MoveSheetFrame {
                    VStack(alignment: .leading, spacing: Space.m) {
                        Text("The move is ready.").font(.system(size: 22, weight: .semibold)).tracking(-0.3)
                        Text("Open the app and check your data. You can confirm or roll back from the Drives tab.")
                            .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(Space.xl)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } bar: {
                    HStack {
                        Spacer()
                        Button("Done") { model.dismissResult() }.buttonStyle(MooringButtonStyle()).keyboardShortcut(.defaultAction)
                    }
                    .padding(Space.xl)
                }
            }
        }
        .background(Dusk())
    }

    @ViewBuilder private func page(_ record: RelocationRecord) -> some View {
        let app = record.flowAppName
        let health = model.guardSnapshot.relocations.first { $0.moveID == moveID }?.health
        MoveSheetFrame {
            VStack(alignment: .leading, spacing: Space.m) {
                Text("The move is ready. Open \(app) and check your data.")
                    .font(.system(size: 22, weight: .semibold)).tracking(-0.3).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: Space.s) {
                    TetheredOutline(drawn: drawn)
                    Image(systemName: record.recipeID.symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        .well(Color.secondary, size: 28).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.recipeName).font(.system(size: 13, weight: .semibold))
                        Text("\(Format.bytes(record.logicalBytes)) \u{00B7} \(Format.count(record.fileCount, "file")) \u{00B7} on \(record.volume.label)")
                            .font(.system(size: 12, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Spacer(minLength: Space.xs)
                    if let health { Tag(health.displayName, tint: health.tint) }
                }
                .padding(Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .surface(16)
                MoveLedgerRows(lines: flowLedger(record, volumes: model.volumes, state: record.state))
                Text("Not sure yet? Choose Not yet. You can confirm or roll back later from the Drives tab.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        } bar: {
            HStack(spacing: Space.xs) {
                if let launch = system.launch, let bundleID = Catalogue.recipe(record.recipeID)?.launchBundleID {
                    Button("Open \(app)") { launch(bundleID) }.buttonStyle(.bordered)
                }
                Button("Not yet", role: .cancel) { model.dismissResult() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Confirm and move to Trash\u{2026}") { model.showConfirmDialog = true }.buttonStyle(MooringButtonStyle())
            }
            .padding(Space.xl)
        }
        .task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            withAnimation(Motion.spring(reduceMotion)) { drawn = 1 }
        }
    }
}

// MARK: - Result

/// What an action ended with, in the backend's own words: a verification line (compared, differences), an aborted move's first
/// differences, the failing preflight checks, and the fixed line when nothing on the Mac was changed.
private struct ResultPage: View {
    let outcome: MoveOutcome
    @EnvironmentObject private var model: AppModel
    @Environment(\.systemActions) private var system
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bounced = 0

    private var record: RelocationRecord? { model.relocations.first { $0.id == outcome.moveID } }
    private var mountPoint: String? { record.flatMap { r in model.volumes.first { $0.uuid == r.volume.uuid }?.mountPoint } }

    private var title: String {
        if outcome.ok {
            switch outcome.action {
            case .move:
                guard let record else { return "Moved to your drive" }
                return "Moved \(Format.bytes(record.logicalBytes)) to \(record.volume.label)"
            case .confirm: return "Moved your original to the Trash"
            case .rollback: return "Rolled back"
            case .returnToMac: return "Returned to this Mac"
            case .forget: return "Forgotten"
            case .checkAndReconnect: return "Checked and reconnected"
            case .setAsideAndReconnect: return "Set aside and reconnected"
            case .trashLeftover: return "Moved to the Trash"
            case .recover: return "Recovered"
            }
        }
        switch outcome.action {
        case .move: return "The move stopped"
        case .confirm: return "Confirm stopped"
        case .rollback: return "Roll back stopped"
        case .returnToMac: return "Return to Mac stopped"
        case .forget: return "Forget stopped"
        case .checkAndReconnect: return "The check stopped"
        case .setAsideAndReconnect: return "Set aside stopped"
        case .trashLeftover: return "Move to Trash stopped"
        case .recover: return "Recovery stopped"
        }
    }

    /// The fixed lines: true by construction (an aborted move changed nothing on the Mac; the Trash returns space when emptied).
    private var fixedLine: String? {
        if !outcome.ok && outcome.state == .aborted { return "Nothing on your Mac was changed." }
        if outcome.ok && outcome.action == .confirm { return "Your Mac gets the space back when you empty the Trash." }
        return nil
    }

    var body: some View {
        MoveSheetFrame {
            VStack(alignment: .leading, spacing: Space.m) {
                Text(title).font(.system(size: 22, weight: .semibold)).tracking(-0.3).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if !outcome.message.isEmpty {
                    Text(outcome.message).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let v = outcome.verification { verification(v) }
                if let preflight = outcome.preflight, !preflight.passed { checks(preflight) }
                if !outcome.differences.isEmpty { differences }
                if let fixedLine, !outcome.message.contains(fixedLine) {
                    Text(fixedLine).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        } bar: {
            HStack(spacing: Space.xs) {
                Button("Open Activity") {
                    model.screen = .activity
                    model.dismissResult()
                }
                .buttonStyle(.bordered)
                if let record, let mountPoint, let reveal = system.reveal {
                    Button("Show on drive") { reveal(mountPoint + "/" + record.relativePath) }.buttonStyle(.bordered)
                }
                Spacer()
                Button("Done") { model.dismissResult() }.buttonStyle(MooringButtonStyle()).keyboardShortcut(.defaultAction)
            }
            .padding(Space.xl)
        }
        .background(Dusk())
        .onAppear { bounced = 1 }
    }

    private func verification(_ v: VerificationSummary) -> some View {
        let status: StepStatus = v.differences == 0 ? .ok : .mismatch
        let count = v.differences == 1 ? "1 difference" : "\(Format.number(v.differences)) differences"
        return VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                Image(systemName: status.symbol).foregroundStyle(status.tint)
                    .bounce(on: status == .ok ? bounced : 0, reduceMotion: reduceMotion).accessibilityHidden(true)
                Text("Compared \(Format.count(v.filesCompared, "file")) by size and \(v.algorithm): \(count).")
                    .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            }
            if v.hardLinkedCopiedSeparately > 0 {
                Text("\(Format.count(v.hardLinkedCopiedSeparately, "hard-linked file")) \(v.hardLinkedCopiedSeparately == 1 ? "was" : "were") copied as separate \(v.hardLinkedCopiedSeparately == 1 ? "file" : "files").")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(16)
        .accessibilityElement(children: .combine)
    }

    private func checks(_ report: PreflightReport) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("\(report.passedCount) of \(report.checks.count) checks passed.").font(.system(size: 13, weight: .semibold))
            ForEach(report.checks.filter { !$0.passed }) { check in
                HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                    Text(check.check.rawValue).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    Text(check.detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(16)
    }

    private var differences: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("First differences").font(.caption.weight(.semibold).smallCaps()).foregroundStyle(.secondary)
            ForEach(outcome.differences) { difference in
                HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                    Image(systemName: StepStatus.mismatch.symbol).foregroundStyle(StepStatus.mismatch.tint).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Self.word(difference.kind)).font(.system(size: 12, weight: .semibold))
                        Text(difference.path).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(16)
        .transition(.opacity)
    }

    static func word(_ kind: DifferenceKind) -> String {
        switch kind {
        case .missingOnDrive: return "Missing on the drive"
        case .extraOnDrive: return "Only on the drive"
        case .typeDiffers: return "Different kind of item"
        case .sizeDiffers: return "Different size"
        case .hashDiffers: return "Different contents"
        case .modeDiffers: return "Different permissions"
        case .symlinkTargetDiffers: return "Different link target"
        case .xattrDiffers: return "Different extended attributes"
        case .unreadable: return "Couldn't be read"
        case .changedDuringCopy: return "Changed while copying"
        }
    }
}

// MARK: - Decisions on a relocation: confirm, roll back, return, forget

/// What a row or a banner asks for. `moveIDs` has one id except for "Forget" from a banner that covers several relocations.
struct RelocationActionRequest: Identifiable {
    enum Kind: String { case confirm, rollback, returnToMac, forget }

    let kind: Kind
    let moveIDs: [String]
    var id: String { kind.rawValue + ":" + moveIDs.joined(separator: ",") }

    init(_ kind: Kind, moveIDs: [String]) {
        self.kind = kind
        self.moveIDs = moveIDs
    }
}

/// The sheet for a decision started from a row or a banner. It closes first, waits for itself to leave, then asks `AppModel`
/// to act; the move's own sheet (`MoveFlowView`) then follows the phase.
struct RelocationActionSheet: View {
    let request: RelocationActionRequest
    let onClose: () -> Void
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let records = request.moveIDs.compactMap { id in model.relocations.first { $0.id == id } }
        RelocationActionPage(kind: request.kind, records: records, sheetMode: true, onClose: onClose)
    }
}

private struct RelocationActionPage: View {
    let kind: RelocationActionRequest.Kind
    let records: [RelocationRecord]
    /// True when this is a sheet of its own (close it, wait, then act); false inside the try-it sheet (act in place).
    let sheetMode: Bool
    let onClose: () -> Void
    @EnvironmentObject private var model: AppModel
    @State private var ticked = false
    @State private var step = 1
    @State private var working = false

    private var first: RelocationRecord? { records.first }
    private var recipeIDs: [RecipeID] {
        var seen: Set<RecipeID> = []
        return records.map(\.recipeID).filter { seen.insert($0).inserted }
    }

    /// Who the decision can be carried out for. A forget needs a confirmed move; the original of a swapped one is still here.
    private var eligible: [RelocationRecord] {
        switch kind {
        case .confirm: return records.filter(\.canConfirm)
        case .rollback: return records.filter(\.canRollBack)
        case .returnToMac: return records.filter(\.canReturn)
        case .forget: return records.filter { $0.state == .confirmed || $0.state == .originalTrashed }
        }
    }

    private var driveIsHere: Bool {
        guard let first else { return false }
        return model.volumes.contains { $0.uuid == first.volume.uuid }
    }

    /// Confirm only moves the original to the Trash and needs the app open (the person has just been checking their data in it);
    /// a roll back, a return and a forget touch the redirect, so the app has to be closed first.
    private var needsAppClosed: Bool { kind != .confirm }
    private var blockersClear: Bool { !needsAppClosed || recipeIDs.allSatisfy { model.blockers(for: $0).allSatisfy(\.isClear) } }

    private var names: String { Self.join(eligible.map(\.recipeName)) }
    private var drives: String { Self.join(Self.unique(eligible.map { $0.volume.label })) }

    private static func unique(_ items: [String]) -> [String] {
        var seen: Set<String> = []
        return items.filter { seen.insert($0).inserted }
    }

    /// "A", "A and B", "A, B and C".
    private static func join(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }

    // What the page says, by kind.
    private var title: String {
        switch kind {
        case .confirm: return first.map { ConsentSheetText.confirmDialog(record: $0).title } ?? "Use the move for good?"
        case .rollback: return "Roll back to your original?"
        case .returnToMac: return "Return \(first?.recipeName ?? "this folder") to this Mac?"
        case .forget:
            if eligible.isEmpty { return "Forget this move?" }
            if step == 2 { return "Forget \(names) for good?" }
            return eligible.count == 1 ? "Forget this move?" : "Forget these moves?"
        }
    }

    private var paragraphs: [String] {
        guard let r = first else { return [] }
        let drive = r.volume.label, leaf = r.flowLeafName
        switch kind {
        case .confirm:
            return [ConsentSheetText.confirmDialog(record: r).body]
        case .rollback:
            if !r.canRollBack { return ["Rolling back is no longer possible: the original isn't kept on this Mac any more."] }
            return [ConsentSheetText.rollbackNote(record: r, changedFiles: 0),
                    "\(leaf)\(Names.beforeMoveSuffix) goes back to \(leaf), and \(r.flowAppName) uses it again. The copy on \(drive) stays there until you move it to the Trash. Anything written to \(drive) since the move stays there and is not copied back."]
        case .returnToMac:
            if !r.canReturn { return ["This move can't be returned: it has to be confirmed first."] }
            var lines = ["Outboard copies it from \(drive) back to your Mac and compares every file. The copy on \(drive) stays there until you move it to the Trash."]
            if !driveIsHere { lines.append("\(drive) isn't connected. Plug it in first.") }
            return lines
        case .forget:
            if eligible.isEmpty {
                return ["Only a move you have confirmed can be forgotten. If the original is still on this Mac, roll back instead."]
            }
            if step == 2 { return [ConsentSheetText.forgetWarning] }
            return ["Use this only if \(drives) is gone for good.",
                    "Outboard stops watching \(names) and takes the link or note away (or puts the setting back) so \(eligible.count == 1 ? eligible[0].flowAppName : "those apps") can make its own folder. Nothing on the drive is touched.",
                    ConsentSheetText.forgetWarning]
        }
    }

    private var checkbox: String? {
        switch kind {
        case .confirm: return first.map { ConsentSheetText.confirmDialog(record: $0).checkboxText }
        case .forget: return step == 2 && !eligible.isEmpty ? "I understand Outboard can't get this data back without the drive." : nil
        default: return nil
        }
    }

    private var primaryTitle: String {
        switch kind {
        case .confirm: return first.map { ConsentSheetText.confirmDialog(record: $0).confirmTitle } ?? "Confirm and move to Trash"
        case .rollback: return "Roll back"
        case .returnToMac: return "Return to Mac"
        case .forget: return step == 1 ? "Continue" : "Forget"
        }
    }

    private var cancelTitle: String {
        if eligible.isEmpty { return "Done" }   // an information-only page has nothing to cancel
        switch kind {
        case .confirm: return first.map { ConsentSheetText.confirmDialog(record: $0).cancelTitle } ?? "Not yet"
        default: return "Cancel"
        }
    }

    /// Cancel is the default for a recipe that can't be replaced, and always for Forget. The primary is otherwise the default,
    /// except Forget and Continue, which are never the default.
    private var primaryIsDefault: Bool {
        guard let r = first else { return false }
        switch kind {
        case .confirm: return ConsentSheetText.confirmDialog(record: r).confirmIsDefault
        case .rollback, .returnToMac: return r.risk != .irreplaceable
        case .forget: return false
        }
    }

    private var ready: Bool {
        if working || eligible.isEmpty { return false }
        if kind == .returnToMac && !driveIsHere { return false }
        if checkbox != nil, !ticked { return false }
        return blockersClear
    }

    var body: some View {
        MoveSheetFrame {
            VStack(alignment: .leading, spacing: Space.m) {
                Text(title).font(.system(size: 22, weight: .semibold)).tracking(-0.3).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if kind == .confirm, let r = first {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("After you confirm").font(.caption.weight(.semibold).smallCaps()).foregroundStyle(.secondary)
                        MoveLedgerRows(lines: flowLedger(r, volumes: model.volumes, state: .confirmed))
                    }
                }
                if !eligible.isEmpty, needsAppClosed { MoveBlockerRows(recipeIDs: recipeIDs) }
                if let checkbox {
                    Toggle(checkbox, isOn: $ticked).toggleStyle(.checkbox).font(.system(size: 13))
                }
            }
            .padding(Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        } bar: {
            HStack(spacing: Space.xs) {
                Spacer()
                if working { ProgressView().controlSize(.small) }
                // With no primary button (information only) Done is the default, so Return closes the page.
                if primaryIsDefault && !eligible.isEmpty {
                    Button(cancelTitle, role: .cancel) { onClose() }.keyboardShortcut(.cancelAction).disabled(working)
                } else {
                    Button(cancelTitle, role: .cancel) { onClose() }.keyboardShortcut(.defaultAction).disabled(working)
                }
                if !eligible.isEmpty {
                    if primaryIsDefault {
                        Button(primaryTitle) { go() }.buttonStyle(MooringButtonStyle()).keyboardShortcut(.defaultAction).disabled(!ready)
                    } else {
                        Button(primaryTitle) { go() }.buttonStyle(MooringButtonStyle()).disabled(!ready)
                    }
                }
            }
            .padding(Space.xl)
        }
    }

    private func go() {
        if kind == .forget && step == 1 {
            step = 2
            ticked = false
            return
        }
        guard !working else { return }
        working = true
        let kind = self.kind, ids = eligible.map(\.id), model = self.model
        if sheetMode {
            onClose()
            afterSheetCloses { await Self.run(kind, ids, model) }
        } else {
            Task {
                await Self.run(kind, ids, model)
                working = false
            }
        }
    }

    /// One at a time, in order: one mutation in flight (invariant I5).
    @MainActor private static func run(_ kind: RelocationActionRequest.Kind, _ ids: [String], _ model: AppModel) async {
        for id in ids {
            switch kind {
            case .confirm: await model.confirm(moveID: id)
            case .rollback: await model.rollback(moveID: id)
            case .returnToMac: await model.returnToMac(moveID: id)
            case .forget: await model.forget(moveID: id)
            }
        }
    }
}
