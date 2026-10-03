import OutboardCore
import SwiftUI

// docs/DESIGN.md §6.5 (Consent sheet). What a move will change, in Core's words (`ConsentSheetText.sheet`), the live "Before you
// start" rows, every box the recipe and the drive ask for, and the three-line space ledger. Nothing is written until the person
// presses the move button; the sheet then hands `ConsentRecord` to `AppModel.startMove`, and the same sheet follows the phase
// into `MoveFlowView`. Named MoveConsentView because Core already has a `ConsentSheet` (the text). Written, not compiled.

struct MoveConsentView: View {
    let recipeID: RecipeID
    let volumeID: String
    @EnvironmentObject private var model: AppModel
    @State private var report: EligibilityReport?
    @State private var ticked: Set<String> = []
    @State private var starting = false
    @State private var showUnplug = false

    private var recipe: Recipe? { Catalogue.recipe(recipeID) }
    private var drive: DriveFacts? { model.drive(volumeID) }

    /// The text of the sheet, once the recipe, the folder, the drive and the drive's verdicts are all in hand.
    private var text: ConsentSheet? {
        guard let recipe, let drive, let scan = model.mergedScan(for: recipeID), let report else { return nil }
        let free = Eligibility.effectiveAvailable(drive)
        let volume = VolumeRef(uuid: drive.uuid ?? drive.id, name: drive.name, token: drive.markerToken ?? "")
        var sheet = ConsentSheetText.sheet(recipe: recipe, scan: scan, drive: volume, mountPoint: drive.mountPoint, report: report,
                                           free: free ?? 0, unverified: model.isUnverified(recipe))
        // Free space the drive did not report is left out of the note rather than shown as 0.
        if free == nil, !sheet.ledger.isEmpty { sheet.ledger[0].note = "" }
        return sheet
    }

    /// Why the sheet cannot be filled in, when it cannot (the drive went away, or the folder is no longer there).
    private var problem: String? {
        if recipe == nil { return "Outboard doesn't know this app." }
        if drive == nil { return "This drive isn't connected any more. Nothing was changed." }
        if model.mergedScan(for: recipeID) == nil { return "Outboard can't find this folder any more. Measure again. Nothing was changed." }
        return nil
    }

    var body: some View {
        MoveSheetFrame {
            VStack(alignment: .leading, spacing: Space.m) {
                if let text {
                    details(text)
                } else if let problem {
                    Text(problem).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: Space.xs) {
                        ProgressView().controlSize(.small)
                        Text("Checking this drive\u{2026}").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        } bar: {
            bar
        }
        .background(Dusk(strength: 0.5))
        .task(id: recipeID + "|" + volumeID) { report = await model.eligibility(volumeID: volumeID, recipeID: recipeID) }
        .sheet(isPresented: $showUnplug) { UnplugSheet() }
    }

    // MARK: - Page

    @ViewBuilder private func details(_ sheet: ConsentSheet) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(sheet.title).font(.system(size: 22, weight: .semibold)).tracking(-0.3).fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(sheet.subtitle).font(.system(size: 13, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
            if let line = sheet.unverifiedLine { Text(line).font(.system(size: 13)).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine)
        if let refusal = report?.firstRefusal {
            Text(refusal.message).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
        }
        if !sheet.whatChanges.isEmpty {
            plate("What changes") { Text(sheet.whatChanges).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true) }
        }
        if !sheet.whatToKnow.isEmpty {
            plate("What to know") {
                VStack(alignment: .leading, spacing: Space.xs) {
                    ForEach(Array(sheet.whatToKnow.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                            Circle().fill(Color.secondary.opacity(0.6)).frame(width: 6, height: 6).accessibilityHidden(true)
                            Text(line).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        MoveBlockerRows(recipeIDs: [recipeID])
        if let relaunch = sheet.relaunchNote {
            Text(relaunch).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if !sheet.checkboxes.isEmpty {
            VStack(alignment: .leading, spacing: Space.s) {
                ForEach(sheet.checkboxes) { box in
                    Toggle(isOn: binding(box.id)) {
                        Text(box.text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
        ForEach(Array(sheet.warnings.enumerated()), id: \.offset) { _, warning in
            Text(warning).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        MoveLedgerRows(lines: sheet.ledger)
        if let line = sheet.envLine { envLine(line) }
        Text(sheet.permissionNote).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Button(sheet.footerLink) { showUnplug = true }
            .buttonStyle(.borderless)
            .foregroundStyle(Brand.aquaInk)
    }

    private func plate<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title).font(.caption.weight(.semibold).smallCaps()).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(16)
    }

    /// Shown as text only: Outboard never edits a shell or login file.
    private func envLine(_ line: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Outboard won't edit your shell or login settings. Here is the line to copy.")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: Space.s) {
                Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Space.xs)
                CopyButton { copyToPasteboard(line) }
            }
            .padding(Space.s)
            .terminal()
        }
    }

    // MARK: - Bar and the move

    @ViewBuilder private var bar: some View {
        let sheet = text
        let cancelIsDefault = sheet?.cancelIsDefault ?? true
        HStack(spacing: Space.xs) {
            Spacer()
            if starting { ProgressView().controlSize(.small) }
            // Cancel is the default for a recipe that can't be replaced; the move button is then never the default.
            if cancelIsDefault {
                Button(sheet?.cancelButtonTitle ?? "Cancel", role: .cancel) { model.cancelConsent() }
                    .keyboardShortcut(.defaultAction).disabled(starting)
            } else {
                Button(sheet?.cancelButtonTitle ?? "Cancel", role: .cancel) { model.cancelConsent() }
                    .keyboardShortcut(.cancelAction).disabled(starting)
            }
            if let sheet {
                if cancelIsDefault {
                    Button(sheet.moveButtonTitle) { move(sheet) }.buttonStyle(MooringButtonStyle()).disabled(!ready(sheet))
                } else {
                    Button(sheet.moveButtonTitle) { move(sheet) }.buttonStyle(MooringButtonStyle()).keyboardShortcut(.defaultAction)
                        .disabled(!ready(sheet))
                }
            }
        }
        .padding(Space.xl)
    }

    /// Every box ticked, every app closed (an unreadable list blocks), the drive still allowed, nothing else in flight.
    private func ready(_ sheet: ConsentSheet) -> Bool {
        if starting || model.isBusy { return false }
        if report?.isAllowed != true { return false }
        if !ticked.isSuperset(of: sheet.checkboxes.map(\.id)) { return false }
        return model.blockers(for: recipeID).allSatisfy(\.isClear)
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { ticked.contains(id) },
                set: { on in
                    if on { ticked.insert(id) } else { ticked.remove(id) }
                })
    }

    /// The recipe's boxes are `tickedIDs`; the drive's acknowledgements (`ack-e16`) are `ackIDs`, as Core's planner reads them.
    private func move(_ sheet: ConsentSheet) {
        guard !starting, let recipe, ready(sheet) else { return }
        starting = true
        let ids = sheet.checkboxes.map(\.id)
        let consent = ConsentRecord(recipeVersion: recipe.version, tickedIDs: ids.filter { !$0.hasPrefix("ack-") },
                                    ackIDs: ids.filter { $0.hasPrefix("ack-") }, sawUnverifiedNote: sheet.unverifiedLine != nil)
        let model = self.model, recipeID = self.recipeID, volumeID = self.volumeID
        Task {
            await model.startMove(recipeID: recipeID, volumeID: volumeID, consent: consent)
            starting = false   // a refused start leaves the sheet up; a started move replaces it
        }
    }
}

/// "What happens if I unplug the drive?": the first-run card that says it, in the same words.
private struct UnplugSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let card = Education.cards.first { $0.id == "if-you-unplug" }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if let card {
                Text(card.title).font(.system(size: 22, weight: .semibold)).tracking(-0.3).accessibilityAddTraits(.isHeader)
                Text(card.body).font(.system(size: 15)).fixedSize(horizontal: false, vertical: true)
                if let emphasis = card.emphasis {
                    Text(emphasis).font(.system(size: 15)).bold().fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(Education.guardQuit).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(MooringButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.xl)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .background(Dusk(strength: 0.5))
    }
}
