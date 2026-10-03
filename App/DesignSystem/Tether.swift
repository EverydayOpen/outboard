import SwiftUI

// docs/DESIGN.md §6.3 and docs/MOTION.md §3.2, §3.3: the signature object and the one signature animation, and the lamp.

/// The tether: the line from a folder's outline on the Mac to its copy on the drive, drawn once when a move reaches Swapped and
/// withdrawn when the drive is away. One animatable `progress` (0 = not drawn, 1 = drawn).
struct Tether: Shape {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX + r.width * progress, y: r.midY))
        return p
    }
}

/// A relocation row's leading object: the dashed outline (where the folder stood) in aqua, with a short tether to the right.
/// `drawn` is 1 when the relocation is Healthy and 0 when the drive is away or the relocation is held. It is a state change,
/// animated only when the value changes: a spring on the line's length, or, under Reduce Motion, a short fade with the line
/// always at full length (no movement). On the Try-it-and-confirm sheet pass 0 and set 1 in `onAppear` after 0.1 s to draw it once.
struct TetheredOutline: View {
    var drawn: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                .strokeBorder(Brand.aquaInk, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .frame(width: 22, height: 16)
            Tether(progress: reduceMotion ? 1 : drawn)
                .stroke(Brand.aquaInk, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .opacity(reduceMotion ? drawn : 1)
                .frame(width: 14, height: 16)
        }
        .opacity(0.9)
        .animation(reduceMotion ? Motion.standard(true) : Motion.spring(false), value: drawn)
        .accessibilityHidden(true)
    }
}
