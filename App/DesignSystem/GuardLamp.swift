import SwiftUI

// docs/DESIGN.md §6.3, docs/MOTION.md §3.3.

/// The lamp: the guard indicator on the Drives screen and in first-run card 5. Lit while every moved folder is Healthy, dimmed
/// ("parked") otherwise; the words beside it carry the state and VoiceOver reads them. A colour and opacity swap under
/// `Motion.pop`, shown under Reduce Motion too as a short fade (it is a state, not movement). It never pulses, breathes or
/// blinks, and it never turns red: a problem dims it.
///
///     GuardLamp(lit: model.guardLit, label: model.guardLabel)
struct GuardLamp: View {
    var lit: Bool
    /// "Guard on · drive attached" / "Guard on · drive away" / "Guard off".
    var label: String
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Space.xs) {
            ZStack {
                if contrast != .increased {
                    Circle().fill(RadialGradient(colors: [Brand.lamp.opacity(0.45), .clear], center: .center, startRadius: 0, endRadius: 18))
                        .frame(width: 36, height: 36)
                        .opacity(lit ? 1 : 0.22)
                }
                Circle().fill(Color.secondary.opacity(0.35)).frame(width: 8, height: 8)
                Circle().fill(Brand.lamp).frame(width: 8, height: 8).opacity(lit ? 1 : 0)
                Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5).frame(width: 8, height: 8)
            }
            .frame(width: 36, height: 36)
            .animation(reduceMotion ? Motion.standard(true) : Motion.pop, value: lit)
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}
