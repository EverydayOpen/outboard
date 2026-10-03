import AppKit
import OutboardCore
import SwiftUI

// docs/DESIGN.md §6.5 (First run), docs/MOTION.md §3.4. The five `Education.cards` as pages of one sheet, sized to the tallest
// card so the sheet never jumps. Nothing is measured before the last card's Done (the model measures then), and the only
// thing Done can do besides closing is answer the login-item question on card 5. Written, not compiled.

struct FirstRunView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0
    @State private var risen = false
    /// "Keep Outboard running at login": on unless the person said otherwise before. Applied by Done.
    @State private var keepAtLogin = true

    private let cards = Education.cards

    var body: some View {
        VStack(spacing: Space.m) {
            // Every card is laid out, so the sheet is as tall as the tallest and a page change is only a crossfade.
            ZStack(alignment: .topLeading) {
                ForEach(Array(cards.enumerated()), id: \.offset) { index, card in
                    cardView(card, isFirst: index == 0)
                        .opacity(index == page ? 1 : 0)
                        .allowsHitTesting(index == page)
                        .disabled(index != page)
                        .accessibilityHidden(index != page)
                }
            }
            .padding(Space.l)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .surface(16)
            dots
            bar
        }
        .padding(Space.xxl)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .background(Dusk(strength: 0.5))
        .animation(Motion.standard(reduceMotion), value: page)
        .onAppear { keepAtLogin = model.prefs.startAtLogin }
        .task {
            // The icon rises 24pt and fades in once; Reduce Motion gets the fade alone.
            guard !risen else { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
            withAnimation(reduceMotion ? Motion.standard(true) : Motion.hero) { risen = true }
        }
    }

    // MARK: - One card

    private func cardView(_ card: EducationCard, isFirst: Bool) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if isFirst {
                OnFloor(height: 112) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 112, height: 112)
                }
                .modifier(HoverTilt(max: 8, glare: true))
                .offset(y: risen || reduceMotion ? 0 : 24)
                .opacity(risen ? 1 : 0)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
            }
            Text(card.title).font(.system(size: 22, weight: .semibold)).tracking(-0.3).accessibilityAddTraits(.isHeader)
            Text(card.body).font(.system(size: 15)).fixedSize(horizontal: false, vertical: true)
            if let emphasis = card.emphasis {
                Text(emphasis).font(.system(size: 15)).bold().fixedSize(horizontal: false, vertical: true)
            }
            if card.buttonTitle != nil { guardPart(card) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Card 5: the lamp, the login-item question, and the note an app finds where its folder was.
    private func guardPart(_ card: EducationCard) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            GuardLamp(lit: true, label: "Guard on while Outboard is running")
            VStack(alignment: .leading, spacing: 2) {
                Toggle(card.buttonTitle ?? "", isOn: $keepAtLogin).toggleStyle(.checkbox).font(.system(size: 13))
                if let note = card.buttonNote {
                    Text(note).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 20)
                }
            }
            NoteCard(text: PlaceholderText.body(driveName: "Outboard"))
        }
    }

    // MARK: - Pages

    private var dots: some View {
        HStack(spacing: Space.xs) {
            ForEach(cards.indices, id: \.self) { index in
                Circle().fill(index == page ? Brand.aquaInk : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Card \(page + 1) of \(cards.count)")
    }

    private var bar: some View {
        HStack(spacing: Space.xs) {
            if page > 0 {
                Button("Back") { page -= 1 }.buttonStyle(.bordered)
            }
            Spacer()
            if page < cards.count - 1 {
                Button("Continue") { page += 1 }.buttonStyle(MooringButtonStyle()).keyboardShortcut(.defaultAction)
            } else {
                Button("Done") { finish() }.buttonStyle(MooringButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
    }

    /// The login item is registered only when the person leaves the box ticked here (or ticks it), and asked about once.
    private func finish() {
        if !model.prefs.hasAnsweredLoginItem || keepAtLogin != model.prefs.startAtLogin { model.setLoginItem(keepAtLogin) }
        model.finishFirstRun()
    }
}
