import AppKit
import SwiftUI

// docs/DESIGN.md §6: the dusk wash, porcelain surfaces, wells, the lifted object, the layered plate, the note and the small
// display parts. Pure fills and strokes, so it draws the same in ImageRenderer. Aftertaste's recipes with the slate-black ink.

/// The dusk behind stage screens (Plan, Drives, the sheets, first run, About): the plain window plus the sky along the top
/// edge and the lamp's pool at the top left, as a static wash that never moves. Increase Contrast gets the plain window. Drawn
/// once per size. The lamp itself is `GuardLamp` on the Drives screen, never drawn in the wash (one key light per scene).
struct Dusk: View {
    var strength = 1.0
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let dark = scheme == .dark
        ZStack(alignment: .topLeading) {
            Color(nsColor: .windowBackgroundColor)
            if contrast != .increased {
                VStack(spacing: 0) {
                    // Slate to cyan, fading into the window: the sky at dusk, or by day at a fraction of the strength.
                    LinearGradient(colors: [Brand.skyTop.opacity((dark ? 0.9 : 0.12) * strength), Brand.skyLow.opacity((dark ? 0.7 : 0.14) * strength), .clear],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 220)
                    Spacer(minLength: 0)
                }
                // The lamp's pool: a soft radial at the top left.
                RadialGradient(colors: [Brand.lamp.opacity((dark ? 0.22 : 0.14) * strength), .clear], center: .center, startRadius: 0, endRadius: 260)
                    .frame(width: 520, height: 520)
                    .offset(x: -120, y: -200)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private let sidebarFill = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0.062, green: 0.082, blue: 0.098, alpha: 1)
        : NSColor(srgbRed: 0.906, green: 0.933, blue: 0.949, alpha: 1)
})

extension View {
    /// A symbol in a recessed, tinted squircle: the site's icon well. Pure fills, so it draws the same in ImageRenderer.
    func well(_ tint: Color, size: CGFloat = 44) -> some View {
        modifier(Well(tint: tint, size: size))
    }

    /// A raised object (the card preview; never a row): a tight contact shadow plus a wide soft one. compositingGroup so
    /// glyphs don't cast their own shadows (MOTION §1.4).
    func lifted() -> some View {
        compositingGroup()
            .shadow(color: .black.opacity(0.10), radius: 1.5, y: 1)
            .shadow(color: .black.opacity(0.20), radius: 24, y: 14)
    }

    /// One flat fill for the whole sidebar column, under the traffic lights too. Apply to the sidebar's List. Off by default:
    /// RootView keeps the system sidebar. VERIFY by eye on the CI capture, light and dark, before using it.
    func sidebarSurface() -> some View {
        scrollContentBackground(.hidden).background(sidebarFill)
    }

    /// Evidence lines (a command to copy): a recessed well. The text stays primary and selectable.
    func terminal() -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return background(Color.primary.opacity(0.04), in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    /// Porcelain surface: white (a 5.5% white lift in dark), a hairline rim, a tight contact shadow plus a wide soft one tinted
    /// with the brand ink. Concentric: pass the outer radius; content inside pads by radius - inner. Replaces grey grouped
    /// Form cells and `.quaternary` slabs. Never glass, never on a single row.
    func surface(_ radius: CGFloat = 16) -> some View { modifier(Surface(radius: radius)) }

    /// Layered depth for a plate: two faint rims offset under the surface, so a plate reads as a short stack of slabs (the
    /// quay and the boat). Static, pure strokes, no shadow on the layers themselves. Apply it after `.surface(Radius.plate)`.
    func moored() -> some View { modifier(Moored()) }
}

private struct Surface: ViewModifier {
    let radius: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let dark = scheme == .dark, strong = contrast == .increased
        // The shadows hang off the fill, not the content: glyphs never cast their own (MOTION §1.4), and AppKit-backed
        // controls inside need no compositing group. White, not `.background`, which is the window's grey on macOS.
        // Dark's 5.5% fill casts almost nothing, so there the rim draws the edge (DESIGN §1.1 rule 3).
        return content
            .background {
                shape.fill(dark ? Color.white.opacity(0.055) : Color.white)
                    .shadow(color: .black.opacity(dark ? 0.35 : 0.05), radius: 1, y: 1)
                    .shadow(color: Brand.ink.opacity(dark ? 0.5 : 0.10), radius: 16, y: 8)
            }
            .overlay {
                shape.strokeBorder(strong ? Color.primary.opacity(0.5) : Color.primary.opacity(dark ? 0.10 : 0.07), lineWidth: strong ? 1 : 0.5)
                    .allowsHitTesting(false)
            }
    }
}

private struct Moored: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.plate, style: .continuous)
        let dark = scheme == .dark
        return content.background {
            if contrast != .increased {
                ZStack {
                    shape.fill(dark ? Color.white.opacity(0.03) : Color.white.opacity(0.6))
                        .overlay(shape.strokeBorder(Color.primary.opacity(dark ? 0.08 : 0.06), lineWidth: 0.5))
                        .padding(.horizontal, 12).offset(y: 6)
                    shape.fill(dark ? Color.white.opacity(0.04) : Color.white.opacity(0.8))
                        .overlay(shape.strokeBorder(Color.primary.opacity(dark ? 0.09 : 0.07), lineWidth: 0.5))
                        .padding(.horizontal, 6).offset(y: 3)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}

/// Increase Contrast draws a 1pt primary edge.
private struct Well: ViewModifier {
    let tint: Color
    let size: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        let increased = contrast == .increased
        return content
            .frame(width: size, height: size)
            // The inner shadow is what makes it read as recessed (ShapeStyle.shadow is macOS 13).
            .background(shape.fill(tint.opacity(0.16).gradient.shadow(.inner(color: .black.opacity(0.22), radius: 1.5, y: 1))))
            .overlay(shape.strokeBorder(increased ? Color.primary : tint.opacity(0.24), lineWidth: increased ? 1 : 0.5))
    }
}

/// An object standing on a glossy floor: the view, its mirror fading out over 45% of its height, and a still contact shadow
/// at its base. Drawn once. Pass a stateless view: it is drawn twice. No mirror under Reduce Transparency.
struct OnFloor<Content: View>: View {
    var height: CGFloat
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let mirror = reduceTransparency ? 0 : height * 0.45
        VStack(spacing: 2) {
            content
                .background(alignment: .bottom) {
                    Ellipse().fill(.black.opacity(0.16)).frame(width: height * 0.7, height: height * 0.08).blur(radius: 6)
                        .offset(y: height * 0.04)   // centred on the base line. VERIFY by eye under an app icon
                        .accessibilityHidden(true)
                }
            if !reduceTransparency {
                content
                    .scaleEffect(x: 1, y: -1)
                    .frame(height: mirror, alignment: .top).clipped()
                    .mask { LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom) }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        // Pinned: on CI the mirror collapsed to 0pt in a sibling app and a negative padding pulled the next view over the base.
        .frame(height: height + 2 + mirror, alignment: .top)
    }
}

/// The key light under a lifted object: a pool of light and a thin bright line. Static; drawn once per size. `soft`: the
/// bloom. A hard line with a tight spill when false. Decorative, hidden from VoiceOver. The line runs through the middle of
/// the view's height.
struct Horizon: View {
    var tint: Color
    var width: CGFloat = 420
    var soft = true
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            if contrast != .increased {
                // Elliptical, so the pool fades out inside its wide, short frame instead of being cut at the edges.
                EllipticalGradient(colors: [tint.opacity(soft ? 0.42 : 0.22), tint.opacity(soft ? 0.10 : 0), .clear],
                                   center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5)
            }
            LinearGradient(colors: [.clear, tint, .white.opacity(0.9), tint, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: width * 0.86, height: 1)
        }
        .frame(width: width, height: width * (soft ? 0.32 : 0.14))   // the same with or without the pool
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A small-caps label over a big number. One VoiceOver element. Sizes and counts are rounded; mono is for paths only.
/// `.contentTransition(.numericText())` counts to a new value when the caller animates the change (macOS 13).
struct Metric: View {
    let label: String
    let value: String
    var unit: String? = nil
    var dot: Color? = nil
    var design: Font.Design = .rounded
    var size: CGFloat = 26

    init(label: String, value: String, unit: String? = nil, dot: Color? = nil, design: Font.Design = .rounded, size: CGFloat = 26) {
        self.label = label
        self.value = value
        self.unit = unit
        self.dot = dot
        self.design = design
        self.size = size
    }

    /// `Metric("Could free up to", "87", unit: "GB", size: 40)`.
    init(_ label: String, _ value: String, unit: String? = nil, dot: Color? = nil, design: Font.Design = .rounded, size: CGFloat = 26) {
        self.init(label: label, value: value, unit: unit, dot: dot, design: design, size: size)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption.weight(.semibold).smallCaps()).foregroundStyle(.secondary)   // VERIFY small caps with SF
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let dot { Circle().fill(dot).frame(width: 6, height: 6).accessibilityHidden(true) }
                Text(value).font(.system(size: size, weight: .semibold, design: design)).monospacedDigit()
                    .contentTransition(.numericText())
                if let unit { Text(unit).font(.callout.weight(.medium)).foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A count or a word in a tinted capsule. Colour sits in the dot and the fill; the text stays primary, so it always has full
/// contrast ("only symbols carry colour"). Increase Contrast adds a stroke. The Health pill is
/// `Tag(health.displayName, tint: health.tint)`; the method and risk chips are `Tag(item.kind.displayName)` and
/// `Tag(item.risk.displayName)` in the neutral tint (the word carries the meaning).
struct Tag: View {
    let text: String
    var tint: Color = .secondary
    /// Tighter padding and dot, so several chips fit one line.
    var compact = false
    @Environment(\.colorSchemeContrast) private var contrast

    init(text: String, tint: Color = .secondary, compact: Bool = false) {
        self.text = text
        self.tint = tint
        self.compact = compact
    }

    init(_ text: String, tint: Color = .secondary, compact: Bool = false) {
        self.init(text: text, tint: tint, compact: compact)
    }

    var body: some View {
        HStack(spacing: compact ? 4 : 5) {
            Circle().fill(tint).frame(width: compact ? 5 : 6, height: compact ? 5 : 6).accessibilityHidden(true)
            Text(text).font(.caption.weight(.semibold)).monospacedDigit().lineLimit(1)
        }
        .fixedSize()
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 2 : 3)
        .background(tint.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(contrast == .increased ? Color.primary.opacity(0.4) : tint.opacity(0.3), lineWidth: contrast == .increased ? 1 : 0.5))
    }
}

/// Wraps its children onto as many lines as the offered width needs, left to right. Unlike `ViewThatFits` over an HStack and
/// a VStack it fills a line before starting the next, so two chips take one line or two, never a clipped one. With no width
/// offered it lays everything on one line.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let origins = arrange(bounds.width, subviews).origins
        for (subview, origin) in zip(subviews, origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), anchor: .topLeading, proposal: .unspecified)
        }
    }

    private func arrange(_ width: CGFloat?, _ subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        let limit = width ?? .infinity
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > limit {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return (CGSize(width: widest, height: subviews.isEmpty ? 0 : y + lineHeight), origins)
    }
}

/// A sheet's first lines: the action's symbol in an aqua well, the title, one sentence.
struct SheetHeader: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            Image(systemName: symbol).font(.system(size: 22, weight: .semibold)).foregroundStyle(Brand.aquaInk)
                .well(Brand.aqua, size: 48).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title).font(.title2.weight(.semibold))
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The parked note as an object (the Drives screen's Drive-away row, first-run card 5, the edge states): a small sheet with a
/// small-caps "Note" label and the note's first sentence, a hairline, no shadow (it is a file).
struct NoteCard: View {
    /// `PlaceholderText.body(driveName:)` or its first sentence.
    var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text("Note").font(.caption.weight(.semibold).smallCaps()).foregroundStyle(.secondary)
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}
