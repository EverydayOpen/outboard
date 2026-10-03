import SwiftUI

// docs/DESIGN.md §6.4, §7: the mark is a rounded square (the Mac) and a shorter rounded bar (the drive) joined by a line (the
// tether), with a dot above the square's top-left corner (the lamp). One drawing for the menu bar glyph, the card's back and
// anywhere the app shows itself small. Plain shapes, not a Canvas, so ImageRenderer draws it the same everywhere.

/// The mark, in a 16 x 16 grid scaled to `size`. A flat `color`; template-friendly (the menu bar glyph is this in black).
/// `attention` opens the tether (the line stops short of the drive) and hollows the lamp: the menu bar's variant while any
/// moved folder is Drive away or Held. No colour and no number carry that state; the item's accessibility label says it.
struct OutboardMark: View {
    var size: CGFloat = 16
    var color: Color = .primary
    var attention = false

    var body: some View {
        let k = size / 16
        ZStack(alignment: .topLeading) {
            // The Mac: outer box 8 x 10.5 at (0, 4), a 1.5 stroke, radius 2.75 on the outside.
            RoundedRectangle(cornerRadius: 2.75 * k, style: .continuous).strokeBorder(color, lineWidth: 1.5 * k)
                .frame(width: 8 * k, height: 10.5 * k).offset(x: 0, y: 4 * k)
            // The drive: outer box 5.5 x 7.5 at (10.5, 5.5).
            RoundedRectangle(cornerRadius: 2.25 * k, style: .continuous).strokeBorder(color, lineWidth: 1.5 * k)
                .frame(width: 5.5 * k, height: 7.5 * k).offset(x: 10.5 * k, y: 5.5 * k)
            // The tether, at mid height between them; open while attention is set.
            Rectangle().fill(color)
                .frame(width: (attention ? 1.75 : 4) * k, height: 1.5 * k).offset(x: 7.25 * k, y: 8.5 * k)
            // The lamp.
            if attention {
                Circle().strokeBorder(color, lineWidth: 1 * k).frame(width: 4 * k, height: 4 * k).offset(x: 0.5 * k, y: 0.5 * k)
            } else {
                Circle().fill(color).frame(width: 3 * k, height: 3 * k).offset(x: 1 * k, y: 1 * k)
            }
        }
        .frame(width: size, height: size, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}

/// The back of the Plan card preview while it is dealt (MOTION §3.4): the night sky, the lamp and the mark, no text, so there
/// is nothing to read or miss while it turns. Fixed night colours in both schemes. It fills whatever it is laid over.
struct CardBack: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Brand.cardTop, Brand.cardBottom], startPoint: .top, endPoint: .bottom)
            GeometryReader { g in
                RadialGradient(colors: [Brand.lamp.opacity(0.22), .clear], center: .center, startRadius: 0, endRadius: 64)
                    .frame(width: 128, height: 128)
                    .offset(x: 18 - 64, y: g.size.height - 22 - 64)
                Circle().fill(Brand.lamp.opacity(0.9)).frame(width: 6, height: 6)
                    .offset(x: 18 - 3, y: g.size.height - 22 - 3)
            }
            OutboardMark(size: 56, color: Brand.cardAccent)
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
    }
}
