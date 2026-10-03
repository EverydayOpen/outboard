import SwiftUI

// docs/MOTION.md §1.2, §1.8 and §3: the curves, the pointer tilt and the card flip. macOS 13 APIs only.

/// docs/MOTION.md §1.2, spelled for macOS 13: the duration-and-bounce springs are macOS 14, these are the same curves.
enum Motion {
    /// `.smooth` is macOS 14. Under Reduce Motion callers also drop movement and keep only the fade.
    static func standard(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? .linear(duration: 0.15) : .easeInOut(duration: 0.28)
    }
    /// Surfaces: flips, deal-ins, a tilt settling back, the tether, the bar widening after a rescan.
    static func spring(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? .linear(duration: 0.15) : .spring(response: 0.45, dampingFraction: 0.78)
    }
    static let hero = Animation.spring(response: 0.9, dampingFraction: 0.8)
    static let pop = Animation.spring(response: 0.32, dampingFraction: 0.62)
    static let follow = Animation.interactiveSpring(response: 0.25, dampingFraction: 0.86)
    /// Stagger between rows whose health changes together (MOTION §3.2).
    static let stagger = 0.045
    /// The delay of the i-th row, capped at index 8 so a long list never trickles.
    static func delay(_ index: Int, _ reduceMotion: Bool) -> Double { reduceMotion ? 0 : Double(min(max(index, 0), 8)) * stagger }
}

/// Turns a surface to face the pointer (the edge under it recedes), at most `max` degrees, with an optional glare masked to
/// the content's own shape. Flat under Reduce Motion or with `max: 0`. The pointer is read in the layout frame, so the tilt
/// never moves hit areas. Used on exactly three views (MOTION §3.5): the Plan card preview, the first-run icon, the About
/// icon. Never on rows, plates, bars or banners. Apply it with `.modifier(HoverTilt(max: 4, glare: true))`.
struct HoverTilt: ViewModifier {
    var max = 7.0
    var glare = false
    @State private var size = CGSize.zero
    @State private var p = CGPoint.zero          // -1...1 from the center
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                if glare && hovering {
                    RadialGradient(colors: [Color.white.opacity(0.28), .clear], center: .center,
                                   startRadius: 0, endRadius: size.width * 0.6)
                        .offset(x: p.x * size.width / 2, y: p.y * size.height / 2)
                        .mask { content }            // VERIFY: content drawn twice; fine for an icon and one card
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            // VERIFY on a Mac: the edge under the pointer should recede; negate both angles if it rises instead.
            .rotation3DEffect(.degrees(-p.y * max), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
            .rotation3DEffect(.degrees(p.x * max), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .background {
                GeometryReader { g in
                    Color.clear.onAppear { size = g.size }.onChange(of: g.size) { size = $0 }
                }
            }
            .onContinuousHover { phase in
                guard !reduceMotion, max > 0, size.width > 0, size.height > 0 else { return }
                switch phase {
                case .active(let at):
                    withAnimation(Motion.follow) {
                        hovering = true
                        p = CGPoint(x: at.x / size.width * 2 - 1, y: at.y / size.height * 2 - 1)
                    }
                case .ended:
                    withAnimation(Motion.spring(false)) {
                        hovering = false
                        p = .zero
                    }
                }
            }
    }
}

extension AnyTransition {
    /// A card arriving: turns down into place from the top edge like a split-flap card, and leaves by fading, so old and new
    /// never overlap mid-turn. Opacity only under Reduce Motion.
    static func flip(_ reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .modifier(active: FlipDown(angle: 70, opacity: 0), identity: FlipDown(angle: 0, opacity: 1)),
            removal: .opacity)
    }
}

private struct FlipDown: ViewModifier {
    let angle: Double
    let opacity: Double

    func body(content: Content) -> some View {
        content   // VERIFY sign on a Mac: the bottom edge should start toward the viewer
            .rotation3DEffect(.degrees(angle), axis: (x: 1, y: 0, z: 0), anchor: .top, perspective: 0.6)
            .opacity(opacity)
    }
}

/// Shows the content until the turn passes 90°, then `back`: a card turning over. `angle` animates. The Plan card preview is
/// dealt once with `FlipFaces(angle: dealt ? 0 : 180, back: CardBack())` (MOTION §3.4). Apply it with `.modifier(...)`.
struct FlipFaces<Back: View>: ViewModifier, Animatable {
    var angle: Double
    let back: Back
    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    func body(content: Content) -> some View {
        content
            .opacity(angle < 90 ? 1 : 0)
            .overlay {
                back.rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                    .opacity(angle < 90 ? 0 : 1)
                    .accessibilityHidden(true)
            }
            .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
    }
}
