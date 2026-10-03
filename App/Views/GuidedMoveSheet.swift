import OutboardCore
import SwiftUI

// docs/DESIGN.md §6.5 (Guided card). For Photos, Music, Final Cut Pro, Steam and the other apps that move their own data:
// numbered steps, what the chosen drive's checks say for this app, the vendor's own behaviour when the drive is away, and a
// button that opens the app. Outboard moves nothing here and writes nothing; opening the app is the one journal line
// ("guide viewed", written by `AppModel.openGuide`). Written, not compiled.

struct GuidedMoveSheet: View {
    let recipeID: RecipeID
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var report: EligibilityReport?

    private var recipe: Recipe? { Catalogue.recipe(recipeID) }
    private var item: PlanItem? { model.plan?.items.first { $0.recipeID == recipeID } }

    /// The drive the person last chose with "Use this drive", else one that carries our marker. nil = none chosen yet.
    private var chosen: DriveFacts? {
        if let uuid = model.prefs.preferredVolumeUUID, let v = model.volumes.first(where: { $0.uuid == uuid }) { return v }
        return model.volumes.first { $0.hasOutboardMarker }
    }

    var body: some View {
        Group {
            if let recipe {
                content(recipe, card: GuidedText.card(recipe: recipe, drive: report, driveName: chosen?.name ?? "Outboard"))
            } else {
                missing
            }
        }
        .background(Dusk(strength: 0.5))
        .task(id: chosen?.id) {
            guard let chosen else {
                report = nil
                return
            }
            report = await model.eligibility(volumeID: chosen.id, recipeID: recipeID)
        }
    }

    private var missing: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("Outboard doesn't know this app.").font(.system(size: 22, weight: .semibold)).tracking(-0.3)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(MooringButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.xl)
        .frame(width: 520)
    }

    private func content(_ recipe: Recipe, card: GuidedCard) -> some View {
        let page = VStack(alignment: .leading, spacing: Space.m) {
            header(card)
            steps(card.steps)
            if !card.notes.isEmpty { notes(card.notes) }
            if let line = card.envLine { envLine(line) }
            driveRow(card)
            awayNote(card.missingDriveSentence)
            Text(card.closingLine).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        return VStack(spacing: 0) {
            ViewThatFits(in: .vertical) {
                page
                ScrollView { page }
            }
            HStack(spacing: Space.xs) {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(card.openButtonTitle) { model.openGuide(recipeID: recipeID) }
                    .buttonStyle(MooringButtonStyle()).keyboardShortcut(.defaultAction)
            }
            .padding(Space.xl)
        }
        .frame(width: 520)
        .frame(maxHeight: 700)
    }

    // MARK: Parts

    private func header(_ card: GuidedCard) -> some View {
        var parts: [String] = []
        if let item, item.allocatedBytes > 0 { parts.append(Format.size(item.allocatedBytes, atLeast: item.isLowerBound)) }
        parts.append(MethodKind.guided.displayName)
        return HStack(alignment: .center, spacing: Space.s) {
            Image(systemName: recipeID.symbol).font(.system(size: 20, weight: .medium)).foregroundStyle(.secondary)
                .well(Color.secondary, size: 44).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title).font(.system(size: 22, weight: .semibold)).tracking(-0.3).fixedSize(horizontal: false, vertical: true)
                Text(parts.joined(separator: " \u{00B7} ")).font(.system(size: 13, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func steps(_ steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
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
    }

    private func notes(_ notes: [String]) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Circle().fill(Color.secondary).frame(width: 5, height: 5).accessibilityHidden(true)
                    Text(note).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
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

    /// What the chosen drive's checks say for this app, in Core's words. No drive chosen yet: say where to choose one.
    private func driveRow(_ card: GuidedCard) -> some View {
        let name = chosen.map { Eligibility.driveLabel($0) } ?? "No drive chosen"
        let line: String
        if chosen == nil {
            line = "Choose a drive on the Drives tab and Outboard will check it for \(card.appName)."
        } else if let verdict = card.driveVerdict {
            line = verdict
        } else {
            line = "Checking this drive\u{2026}"
        }
        return HStack(alignment: .top, spacing: Space.s) {
            Image(systemName: card.driveIsRefused ? "hand.raised" : "externaldrive").font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary).frame(width: 20).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 13, weight: .semibold))
                Text(line).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The vendor's own behaviour, labelled like the note Outboard leaves for its own moves.
    private func awayNote(_ sentence: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
        return VStack(alignment: .leading, spacing: Space.xxs) {
            Text("If the drive is away").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(sentence).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}
