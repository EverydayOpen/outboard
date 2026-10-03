import AppKit
import SwiftUI

// The only file with `if #available` and the only place for macOS 14 and later APIs (BUILD_PLAN §10; safety_greps G12). On
// macOS 13 each helper does nothing or draws the pre-26 look, which is the full design. macOS 14 adds the check bounce and the
// capsule border; macOS 26 adds glass on the controls layer.

extension View {
    /// Liquid Glass on macOS 26; a material with a hairline before. The controls layer only (the consent sheet's action bar,
    /// the progress bar, the banner strip, the notice), never content. Materials and glass handle Reduce Transparency
    /// themselves. `radius` is the strip's corner radius: 18 for a bar, larger than half its height for a one-line pill.
    @ViewBuilder func barSurface(radius: CGFloat = Radius.plate) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if #available(macOS 26, *) {
            glassEffect(.regular, in: shape)   // VERIFY by eye on the CI capture (signature checked in Apple's docs)
        } else {
            // The shadow hangs off the shape, not the labels, so glyphs cast none (MOTION §1.4).
            background { shape.fill(.regularMaterial).shadow(color: .black.opacity(0.14), radius: 18, y: 8) }
                .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5).allowsHitTesting(false))
        }
    }

    /// A capsule `.bordered` button ("Rescan"). `ButtonBorderShape.capsule` is macOS 14; macOS 13 keeps the system's rounded
    /// rectangle.
    @ViewBuilder func capsuleBorder() -> some View {
        if #available(macOS 14, *) {
            buttonBorderShape(.capsule)
        } else {
            self
        }
    }

    /// Bounces the SF Symbols inside once each time `value` changes (macOS 14 symbol effects). Used for the one all-matched
    /// check on the result sheet and the Healthy check; nothing on 13, nothing under Reduce Motion.
    @ViewBuilder func bounce(on value: some Equatable, reduceMotion: Bool) -> some View {
        if #available(macOS 14, *), !reduceMotion {
            symbolEffect(.bounce, value: value)
        } else {
            self
        }
    }
}

/// Brings the app forward after `openWindow(id:)` (the menu bar item's "Open Outboard", a command that needs the window).
/// `NSApp.activate()` is macOS 14; 13 uses the older form.
@MainActor func activateApp() {
    if #available(macOS 14, *) {
        NSApp.activate()
    } else {
        NSApp.activate(ignoringOtherApps: true)
    }
}
