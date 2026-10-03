import OutboardCore
import SwiftUI

// docs/DESIGN.md §6.5 (Drives). Every mounted volume as one plate: its facts, a capacity bar, what Core's eligibility rules say
// (the first refusal as one line, every verdict behind "Details"), and the one thing the person can do with it. Used two ways:
// as the Drives list (`DrivePickerView()`) and as the chooser a move starts from (`DrivePickerSheet`). The rules are Core's;
// this file only shows them. A refused plate is set exactly like an allowed one: only the words differ. Written, not compiled.

struct DrivePickerView: View {
    /// With a recipe, each plate shows that recipe's verdicts (some rules depend on the recipe); without one, the general ones.
    var recipeID: RecipeID? = nil
    /// Set when this is a chooser: an allowed plate with the Outboard marker offers "Choose this drive".
    var onChoose: ((DriveFacts) -> Void)? = nil

    @EnvironmentObject private var model: AppModel
    @State private var reports: [String: EligibilityReport] = [:]
    @State private var settingUp = false
    @State private var using: String?

    private var volumes: [DriveFacts] {
        model.volumes.sorted { a, b in
            let ka = rank(a), kb = rank(b)
            return ka != kb ? ka < kb : a.name.localizedCompare(b.name) == .orderedAscending
        }
    }

    /// Allowed drives first, the ones that carry our marker before the ones that do not, then the refused.
    private func rank(_ v: DriveFacts) -> Int {
        guard let report = reports[v.id] else { return 1 }
        return report.isAllowed ? (v.hasOutboardMarker ? 0 : 1) : 2
    }

    private var loadKey: [String] { model.volumes.map { "\($0.id)|\($0.hasOutboardMarker)" } + [recipeID ?? ""] }

    var body: some View {
        let list = volumes
        let firstAllowed = list.first { reports[$0.id]?.isAllowed == true }?.id
        let candidates = list.filter { reports[$0.id]?.isAllowed == true && !$0.hasOutboardMarker }
        VStack(alignment: .leading, spacing: Space.m) {
            if !list.contains(where: { $0.isInternal != .yes }) {
                Text("No external drive found. Plug one in and it appears here.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(list) { volume in
                DrivePlate(volume: volume, report: reports[volume.id], moved: movedBytes(on: volume),
                           showsSleepNote: volume.id == firstAllowed, isOnlyCandidate: candidates.count == 1 && candidates.first?.id == volume.id,
                           using: using == volume.id, chooser: onChoose != nil,
                           use: { use(volume) }, choose: { onChoose?(volume) })
            }
            // Also in the chooser: a person with no drive, or a wrongly formatted one, would otherwise reach a dead end. The setup
            // sheet stacks on the chooser. VERIFY on a Mac; if that misbehaves, dismiss the chooser first (`afterSheetCloses`).
            Button { settingUp = true } label: {
                Label("Set up a drive\u{2026}", systemImage: "externaldrive.badge.plus").font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(KeyCapStyle())
            .frame(maxWidth: 320)
            .help("Steps for giving Outboard its own volume on a drive")
        }
        .task(id: loadKey) { await load() }
        .sheet(isPresented: $settingUp) { DriveSetupSheet(volumes: model.volumes).environmentObject(model) }
    }

    /// Bytes Outboard has moved onto this drive, from the one model (the active relocations), not from a scan of the drive.
    private func movedBytes(on volume: DriveFacts) -> UInt64 {
        guard let uuid = volume.uuid else { return 0 }
        return model.relocations.filter { $0.state.isActive && $0.direction == .toDrive && $0.volume.uuid == uuid }
            .reduce(0) { $0 + $1.logicalBytes }
    }

    @MainActor private func load() async {
        var next: [String: EligibilityReport] = [:]
        for volume in model.volumes {
            if Task.isCancelled { return }
            next[volume.id] = await model.eligibility(volumeID: volume.id, recipeID: recipeID)
        }
        reports = next
    }

    private func use(_ volume: DriveFacts) {
        guard using == nil else { return }
        using = volume.id
        Task {
            await model.useDrive(volume.id)
            using = nil
        }
    }
}

// MARK: - One drive

private struct DrivePlate: View {
    let volume: DriveFacts
    let report: EligibilityReport?
    let moved: UInt64
    let showsSleepNote: Bool
    let isOnlyCandidate: Bool
    let using: Bool
    let chooser: Bool
    let use: () -> Void
    let choose: () -> Void

    private var allowed: Bool { report?.isAllowed == true }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .top, spacing: Space.s) {
                Image(systemName: volume.isInternal == .yes ? "internaldrive" : "externaldrive")
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
                    .well(Color.secondary, size: 32).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(volume.name).font(.system(size: 17, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    Text(Eligibility.summary(volume)).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Space.xs)
                if volume.hasOutboardMarker { Tag("Your Outboard drive", tint: Brand.aqua) }
            }
            if let bar = capacity { CapacityBar(segments: bar) }
            verdict
            if let report, !report.verdicts.isEmpty { details(report) }
            action
            if showsSleepNote {
                Text(Education.sleepAndHubs).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(18)
        .accessibilityElement(children: .contain)
    }

    // MARK: Capacity

    /// Other files, what Outboard moved here, and free space. Left out when the drive did not report its size or its free space.
    private var capacity: [CapacityBar.Segment]? {
        guard volume.capacityBytes > 0, let free = Eligibility.effectiveAvailable(volume) else { return nil }
        let freeBytes = min(free, volume.capacityBytes)
        let movedBytes = min(moved, volume.capacityBytes - freeBytes)
        let other = volume.capacityBytes - freeBytes - movedBytes
        var segments: [CapacityBar.Segment] = []
        if other > 0 { segments.append(CapacityBar.Segment(id: "other", label: "Other files", bytes: other, fill: .used)) }
        if movedBytes > 0 { segments.append(CapacityBar.Segment(id: "moved", label: "Moved by Outboard", bytes: movedBytes, fill: .moved)) }
        if freeBytes > 0 { segments.append(CapacityBar.Segment(id: "free", label: "Free", bytes: freeBytes, fill: .free)) }
        return segments.isEmpty ? nil : segments
    }

    // MARK: Verdict

    /// The first refusal as one line; otherwise our own marker; otherwise plain "no problems". The other verdicts follow quietly.
    @ViewBuilder private var verdict: some View {
        if let report {
            VStack(alignment: .leading, spacing: Space.xxs) {
                if let refusal = report.firstRefusal {
                    Text(refusal.message).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                } else if volume.hasOutboardMarker {
                    Text("Your Outboard drive.").font(.system(size: 13))
                } else if report.acks.isEmpty && report.warnings.isEmpty {
                    Text("Outboard found no problems with this drive.").font(.system(size: 13))
                }
                ForEach(report.warnings + report.acks) { v in
                    Text(v.message).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            HStack(spacing: Space.xs) {
                ProgressView().controlSize(.small)
                Text("Checking this drive\u{2026}").font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
    }

    /// Every verdict with its rule id. Checks that passed are not listed: the list is what the rules found.
    private func details(_ report: EligibilityReport) -> some View {
        DisclosureGroup("Details") {
            VStack(alignment: .leading, spacing: Space.xs) {
                ForEach(report.verdicts) { v in
                    HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                        Text(v.rule.rawValue).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            .frame(width: 32, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(v.message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                            Text(Self.word(v.outcome)).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top, Space.xs)
        }
        .font(.system(size: 12))
    }

    private static func word(_ outcome: EligibilityOutcome) -> String {
        switch outcome {
        case .refuse: return "Not allowed"
        case .ack: return "Needs your OK in the next step"
        case .warn: return "Warning"
        case .info: return "Information"
        }
    }

    // MARK: Action

    @ViewBuilder private var action: some View {
        if allowed && !volume.hasOutboardMarker {
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(spacing: Space.xs) {
                    if isOnlyCandidate {
                        Button("Use this drive") { use() }.buttonStyle(MooringButtonStyle()).disabled(using)
                    } else {
                        Button("Use this drive") { use() }.buttonStyle(.bordered).disabled(using)
                    }
                    if using { ProgressView().controlSize(.small) }
                }
                Text(Education.useDriveNote).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        } else if allowed && chooser {
            Button("Choose this drive") { choose() }.buttonStyle(MooringButtonStyle())
        }
    }
}

// MARK: - The chooser a move starts from

/// "Choose a drive for Xcode build data": the same plates with that recipe's verdicts. Choosing closes the sheet, waits for it to
/// leave, then calls `onChoose` (which starts the consent sheet). Cancel changes nothing.
struct DrivePickerSheet: View {
    let recipeID: RecipeID
    let onChoose: (DriveFacts) -> Void
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var name: String { Catalogue.recipe(recipeID)?.name ?? "this folder" }

    var body: some View {
        let content = VStack(alignment: .leading, spacing: Space.m) {
            Text("Choose a drive for \(name)").font(.system(size: 22, weight: .semibold)).tracking(-0.3)
                .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
            DrivePickerView(recipeID: recipeID) { volume in
                dismiss()
                afterSheetCloses { onChoose(volume) }
            }
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        VStack(spacing: 0) {
            ViewThatFits(in: .vertical) {
                content
                ScrollView { content }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(Space.xl)
        }
        .frame(width: 560)
        .frame(maxHeight: 680)
        .noticePill(model)   // "Use this drive" posts its result here, and a sheet covers the window's pill
    }
}

// MARK: - Setting up a drive

/// Outboard never formats or erases anything. For a drive with other data it recommends a separate APFS volume and lists the
/// Disk Utility steps (`Education.driveSteps`; menu names are VERIFY on macOS 15 and 26). A drive in a bad format gets the plain
/// sentence first.
private struct DriveSetupSheet: View {
    let volumes: [DriveFacts]
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// External, local drives in a format apps can't use (exFAT, FAT, NTFS): the format sentence names each.
    private var badFormats: [DriveFacts] {
        volumes.filter { v in
            v.isInternal != .yes && v.isLocal && v.bus != .diskImage && v.bus != .network
                && (v.fileSystem == .exfat || v.fileSystem == .fat || v.fileSystem == .ntfs)
        }
    }

    var body: some View {
        let page = VStack(alignment: .leading, spacing: Space.m) {
            SheetHeader(symbol: "externaldrive.badge.plus", title: "Set up a drive", detail: Education.driveStepsTitle)
            ForEach(badFormats) { v in
                VStack(alignment: .leading, spacing: 2) {
                    Text(v.name).font(.system(size: 13, weight: .semibold))
                    Text(Education.badFormat(v.fileSystem.displayName)).font(.system(size: 13)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
            VStack(alignment: .leading, spacing: Space.s) {
                ForEach(Array(Education.driveSteps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                        Text("\(index + 1)").font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(.secondary).frame(width: 16, alignment: .trailing)
                        Text(step).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(16)
            Text(Education.useDriveNote).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        VStack(spacing: 0) {
            ViewThatFits(in: .vertical) {
                page
                ScrollView { page }
            }
            HStack(spacing: Space.xs) {
                Button("Open Disk Utility") { model.openDiskUtility() }.buttonStyle(.bordered)
                Button("Apple's guide") { model.openDiskUtilityGuide() }.buttonStyle(.bordered)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(MooringButtonStyle()).keyboardShortcut(.defaultAction)
            }
            .padding(Space.xl)
        }
        .frame(width: 520)
        .frame(maxHeight: 680)
        .noticePill(model)
    }
}
