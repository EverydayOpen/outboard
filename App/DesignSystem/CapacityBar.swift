import OutboardCore
import SwiftUI

// docs/DESIGN.md §6.3. Lesson f: bars and labels are proportional and never truncate.

/// One proportional bar per drive (or per move): a segment per folder, width by bytes with a floor so small folders stay
/// legible, an aqua lit edge on segments that have been moved, a hatched outline for an original kept as `.before-move` (so
/// the Mac's bar shows an outline, never empty space, until the user confirms). Labels never live inside segments: the legend
/// under the bar carries name and size and wraps instead of truncating. Pure fills and strokes, so it draws the same in ImageRenderer.
///
///     CapacityBar(segments: [.init(id: "used", label: "In use", bytes: 158_000_000_000, fill: .used),
///                            .init(id: "kept", label: "Kept until you confirm", bytes: 87_000_000_000, fill: .kept),
///                            .init(id: "free", label: "Free", bytes: 9_000_000_000, fill: .free)])
///
/// `legend` replaces the generated legend (the Progress sheet writes "12.4 GB of 41.2 GB · 3 min 10 s elapsed": bytes and
/// elapsed time, never an estimate or a rate).
struct CapacityBar: View {
    enum Fill: Equatable { case used, moved, kept, free }

    struct Segment: Identifiable, Equatable {
        let id: String
        let label: String
        let bytes: UInt64
        let fill: Fill

        init(id: String, label: String, bytes: UInt64, fill: Fill) {
            self.id = id
            self.label = label
            self.bytes = bytes
            self.fill = fill
        }
    }

    let segments: [Segment]
    var height: CGFloat = 14
    var legend: String? = nil
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let total = max(1, segments.reduce(UInt64(0)) { $0 &+ $1.bytes })
        let dark = scheme == .dark
        VStack(alignment: .leading, spacing: Space.xs) {
            GeometryReader { g in
                let gap: CGFloat = 3, minW: CGFloat = 24
                let spare = max(0, g.size.width - gap * CGFloat(max(0, segments.count - 1)) - minW * CGFloat(segments.count))
                HStack(spacing: gap) {
                    ForEach(segments) { s in
                        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
                        ZStack {
                            switch s.fill {
                            case .free:
                                shape.strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5)
                            case .kept:
                                // The original, renamed and kept until the user confirms: an outline, not empty space.
                                Hatch().stroke(Brand.aquaInk.opacity(0.35), lineWidth: 1.5).clipShape(shape)
                                shape.strokeBorder(Brand.aquaInk.opacity(0.8), lineWidth: 1)
                            case .used, .moved:
                                shape.fill(contrast == .increased ? AnyShapeStyle(Color.primary.opacity(0.12))
                                           : AnyShapeStyle(LinearGradient(colors: dark ? [Color(red: 0.133, green: 0.188, blue: 0.227), Color(red: 0.090, green: 0.133, blue: 0.169)]
                                                                                        : [Color(red: 1, green: 1, blue: 1), Color(red: 0.933, green: 0.953, blue: 0.965)],
                                                                          startPoint: .top, endPoint: .bottom)))
                                    .overlay(alignment: .top) {
                                        // Increase Contrast has no lit edge: the stroke carries the state.
                                        if contrast != .increased {
                                            Capsule().fill(s.fill == .moved ? Brand.aqua : Color.white.opacity(dark ? 0.12 : 0.9))
                                                .frame(height: 2).padding(.horizontal, 4).padding(.top, 1)
                                        }
                                    }
                                    .overlay(shape.strokeBorder(Color.primary.opacity(contrast == .increased ? 1 : dark ? 0.10 : 0.08), lineWidth: contrast == .increased ? 1 : 0.5))
                            }
                        }
                        .frame(width: minW + spare * CGFloat(s.bytes) / CGFloat(total))
                        .animation(Motion.pop, value: s.fill)
                    }
                }
                // The widths follow the bytes, so only a rescan, a confirmed move or a polled progress value re-lays them out.
                .animation(Motion.spring(reduceMotion), value: segments.map(\.bytes))
            }
            .frame(height: height)
            // The legend: every segment named, so no segment needs a label it cannot fit.
            Text(legendText)
                .font(.caption).foregroundStyle(.secondary).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Capacity: " + words)
    }

    private var words: String {
        segments.map { "\($0.label) \(Format.bytes($0.bytes))" }.joined(separator: ", ")
    }

    private var legendText: String {
        legend ?? segments.map { "\($0.label) \(Format.bytes($0.bytes))" }.joined(separator: " \u{00B7} ")
    }
}

/// 45 degree hatching for a kept original. A `Shape`, so it draws in `ImageRenderer` too.
struct Hatch: Shape {
    var spacing: CGFloat = 6

    func path(in r: CGRect) -> Path {
        var p = Path()
        var x = r.minX - r.height
        while x < r.maxX {
            p.move(to: CGPoint(x: x, y: r.maxY))
            p.addLine(to: CGPoint(x: x + r.height, y: r.minY))
            x += spacing
        }
        return p
    }
}
