import OutboardCore
import SwiftUI

// docs/DESIGN.md §6.6, BUILD_PLAN §8.1 "Storage Plan card". The card is an object, not a screen: the night quay in every colour
// scheme, flat, pure fills and strokes only (no material, blur, shadow or AppKit control inside the art), so the saved PNG looks
// the same everywhere and `ImageRenderer` can draw it. Every word and number comes from `StoragePlanCard` (Core
// `StoragePlanText`): measured sizes only, no paths, no file names, no drive names before a move.

/// The on-screen card: the 600pt art scaled to `width`, rounded, ready for `lifted()` and `HoverTilt` from the caller.
/// Export never renders this view (it measures itself with @State, which `ImageRenderer` does not wait for); it renders
/// `PlanCardArt`.
struct PlanCardView: View {
    /// The art is always drawn 600pt wide (1200 px at 2x) and at least 315pt tall (630 px). Long text makes it taller.
    static let artWidth: CGFloat = 600
    static let minHeight: CGFloat = 315

    let card: StoragePlanCard
    /// On-screen width. The art is drawn at 600pt and scaled, so the PNG never depends on this.
    var width: CGFloat = PlanCardView.artWidth
    @State private var artHeight = PlanCardView.minHeight

    var body: some View {
        let scale = width / Self.artWidth
        PlanCardArt(card: card)
            .fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { g in
                    Color.clear
                        .onAppear { measured(g.size.height) }
                        .onChange(of: g.size.height) { measured($0) }
                }
            }
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: width, height: artHeight * scale, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
    }

    /// Writes @State only when the height really changed, so a layout pass never loops.
    private func measured(_ height: CGFloat) {
        if abs(height - artHeight) > 0.5 { artHeight = height }
    }
}

/// The name BUILD_PLAN §7 and the file name use for the same view.
typealias StoragePlanCardView = PlanCardView

/// The card itself, 600pt wide. `Export` renders exactly this, so the preview and the PNG are one drawing.
struct PlanCardArt: View {
    let card: StoragePlanCard

    /// Fixed, not the design system's adaptive colours: the card looks the same in light and dark (DESIGN §6.6).
    private enum Palette {
        static let skyTop = Color(red: 0.043, green: 0.086, blue: 0.125)       // #0B1620
        static let skyBottom = Color(red: 0.059, green: 0.106, blue: 0.141)    // #0F1B24
        static let text = Color(red: 0.918, green: 0.949, blue: 0.961)         // #EAF2F5
        static let muted = Color(red: 0.616, green: 0.690, blue: 0.729)        // #9DB0BA
        static let accent = Color(red: 0.494, green: 0.925, blue: 0.894)       // #7EECE4
        static let lamp = Color(red: 0.373, green: 0.910, blue: 0.863)         // #5FE8DC
        static let track = Color.white.opacity(0.07)
    }
    private static let inset: CGFloat = 36
    /// Room under the content for the footnote and the address, which sit in an overlay pinned to the bottom edge.
    private static let footerReserve: CGFloat = 68
    /// The lamp's centre, from the left and bottom edges. It sits on the address line.
    private static let lampX: CGFloat = 18
    private static let lampY: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topRow
            if !card.headline.isEmpty { headline.padding(.top, 8) }
            if !card.rows.isEmpty { rows.padding(.top, 12) }
            if card.moreLine != nil || !card.guidedLines.isEmpty { extras.padding(.top, 10) }
            Text(card.measuredLine)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
        .padding(.horizontal, Self.inset)
        .padding(.top, 22)
        .padding(.bottom, Self.footerReserve)
        .frame(width: PlanCardView.artWidth, alignment: .topLeading)
        .frame(minHeight: PlanCardView.minHeight, alignment: .topLeading)
        .background { backdrop }
        .overlay(alignment: .bottomLeading) { footer }
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.label(card))
    }

    // MARK: - Backdrop

    /// The sky and the lamp: a 6pt dot with a faint pool, at the bottom left. Offsets only, so nothing here takes part in layout.
    private var backdrop: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [Palette.skyTop, Palette.skyBottom], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Palette.lamp.opacity(0.22), .clear], center: .center, startRadius: 0, endRadius: 64)
                .frame(width: 128, height: 128)
                .offset(x: Self.lampX - 64, y: 64 - Self.lampY)
            Circle().fill(Palette.lamp.opacity(0.9))
                .frame(width: 6, height: 6)
                .offset(x: Self.lampX - 3, y: 3 - Self.lampY)
        }
    }

    // MARK: - Top row

    /// The mark and the wordmark on the left, the "Sample data" watermark on the right (demo mode only).
    private var topRow: some View {
        HStack(spacing: 8) {
            CardMark(color: Palette.accent)
            Text("OUTBOARD").font(.system(size: 11, weight: .semibold)).tracking(2.2).foregroundStyle(Palette.muted)
            Spacer(minLength: 12)
            if card.isSample {
                HStack(spacing: 6) {
                    Circle().fill(Palette.accent).frame(width: 7, height: 7)
                    Text("Sample data").font(.system(size: 12, weight: .semibold)).tracking(0.3).foregroundStyle(Palette.accent)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .background(Capsule().fill(Palette.accent.opacity(0.16)))
                .overlay(Capsule().strokeBorder(Palette.accent.opacity(0.55), lineWidth: 1))
            }
        }
        .lineLimit(1)
        .frame(height: 22)
    }

    // MARK: - Headline

    /// "Your Mac could free up to 87 GB" with the figure in aqua. A longer headline is set smaller and may take a second line;
    /// it is never cut.
    private var headline: some View {
        Self.headlineText(card.headline)
            .font(.system(size: Self.headlineSize(card.headline.count), weight: .semibold))
            .tracking(-0.6)
            .foregroundStyle(Palette.text)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static func headlineSize(_ characters: Int) -> CGFloat {
        characters <= 31 ? 32 : characters <= 40 ? 29 : 26
    }

    /// The first figure with a unit ("87 GB", "1,204 GB") in aqua, the rest in the card's text colour.
    private static func headlineText(_ line: String) -> Text {
        var out = AttributedString(line)
        if let figure = line.range(of: "[0-9][0-9,]*[.]?[0-9]* (KB|MB|GB|TB)", options: .regularExpression),
           let run = out.range(of: String(line[figure])) {
            out[run].foregroundColor = Palette.accent   // VERIFY on macOS 13: colour runs inside ImageRenderer
        }
        return Text(out)
    }

    // MARK: - Rows

    /// One row per folder: label, a bar proportional to the unrounded bytes, the rounded size. A row that was not measured has
    /// no bar and says so in words. Label and size columns are sized from the text, and a label wraps rather than truncates.
    private var rows: some View {
        let labelWidth = Self.columnWidth(card.rows.map(\.label.count), perCharacter: 8, minimum: 96, maximum: 220)
        let sizeWidth = Self.columnWidth(card.rows.filter { $0.bytes > 0 }.map(\.text.count), perCharacter: 9, minimum: 56, maximum: 120)
        return VStack(alignment: .leading, spacing: 9) {
            ForEach(card.rows) { row in
                HStack(alignment: .center, spacing: 12) {
                    Text(row.label)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Palette.text)
                        .frame(width: labelWidth, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if row.bytes > 0 {
                        RowBar(fraction: row.fraction, fill: Palette.accent, track: Palette.track)
                        Text(row.text)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Palette.text)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(width: sizeWidth, alignment: .trailing)
                    } else {
                        Text(Self.notMeasured(row))
                            .font(.system(size: 14))
                            .foregroundStyle(Palette.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private static func columnWidth(_ lengths: [Int], perCharacter: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        min(max(CGFloat(lengths.max() ?? 0) * perCharacter + 6, minimum), maximum)
    }

    /// "not measured (needs Full Disk Access)".
    private static func notMeasured(_ row: CardRow) -> String {
        row.text + (row.note.map { " (\($0))" } ?? "")
    }

    // MARK: - Extras and footer

    /// "and 2 more (3 GB)" and the muted guided lines, which are not in the total.
    private var extras: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let more = card.moreLine {
                Text(more).font(.system(size: 14)).foregroundStyle(Palette.muted)
            }
            ForEach(card.guidedLines, id: \.self) { line in
                Text(line).font(.system(size: 13)).foregroundStyle(Palette.muted)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The footnote, and the address under it, bottom right. Pinned to the bottom edge, so a short card keeps it at the foot.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(card.footnote)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Text(card.website).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(Palette.muted)
            }
        }
        .padding(.horizontal, Self.inset)
        .padding(.bottom, 14)
    }

    // MARK: - VoiceOver

    /// The whole card as one spoken description (the picture has no text of its own to read).
    static func label(_ card: StoragePlanCard) -> String {
        var parts = ["Outboard Storage Plan card."]
        if !card.headline.isEmpty { parts.append(sentence(card.headline)) }
        for row in card.rows {
            parts.append(sentence(row.bytes > 0 ? "\(row.label), \(row.text)" : "\(row.label), \(notMeasured(row))"))
        }
        if let more = card.moreLine { parts.append(sentence(more)) }
        parts += card.guidedLines.map(sentence)
        parts.append(sentence(card.measuredLine))
        if card.isSample { parts.append("Sample data.") }
        return parts.joined(separator: " ")
    }

    private static func sentence(_ text: String) -> String { text.hasSuffix(".") ? text : text + "." }
}

/// One proportional bar: a faint track and a fill of `fraction` of its width (a floor of 4pt so a small folder still shows).
/// Pure shapes; no shadow.
private struct RowBar: View {
    let fraction: Double
    let fill: Color
    let track: Color

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(fill).frame(width: max(4, g.size.width * CGFloat(min(max(fraction, 0), 1))))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

/// The product's mark, drawn: the Mac (a rounded square) and the drive (a shorter rounded bar) joined by the tether, with the
/// lamp above the square's top-left corner. Shapes only, so `ImageRenderer` draws it the same everywhere.
private struct CardMark: View {
    let color: Color

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(color, lineWidth: 1.5)
                .frame(width: 11, height: 11).offset(x: 0, y: 6)
            RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(color, lineWidth: 1.5)
                .frame(width: 6.5, height: 8).offset(x: 13.5, y: 7.5)
            Rectangle().fill(color).frame(width: 2.5, height: 1.5).offset(x: 11, y: 10.75)
            Circle().fill(color).frame(width: 3.5, height: 3.5).offset(x: 1, y: 0.5)
        }
        .frame(width: 20, height: 20, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}
