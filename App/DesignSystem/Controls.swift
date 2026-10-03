import SwiftUI

// docs/DESIGN.md §6.1: the one prominent button, the key-cap choices and the copy button.

/// The one prominent button per screen (Move 41 GB, Confirm and move to Trash, Check and reconnect, Continue): a mooring
/// key-cap with near-black text, a lit top edge and a slate lip; a press sinks 1pt. No glow: the light comes from the lamp, not
/// the button. `.keyboardShortcut(.defaultAction)` still works where BUILD_PLAN §8 allows it (never for the primary button of
/// an irreplaceable recipe). Replaces .borderedProminent there.
struct MooringButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Plate(configuration: configuration) }

    // Not `Body`: that is ButtonStyle's associated type.
    private struct Plate: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            let down = configuration.isPressed && !reduceMotion
            configuration.label
                .font(.body.weight(.semibold))
                .foregroundStyle(Brand.onAqua)
                .padding(.horizontal, 18)
                .frame(minHeight: 30)
                .background(shape.fill(Brand.aqua).overlay(shape.fill(LinearGradient(colors: [.clear, Color.black.opacity(0.12)], startPoint: .top, endPoint: .bottom))))
                .overlay(shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.5), Color.black.opacity(0.22)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
                .background(shape.fill(Color(red: 0.11, green: 0.42, blue: 0.40)).offset(y: down ? 0.5 : 1.5))   // the lip; its bottom stays put
                .contentShape(shape)
                .opacity(enabled ? 1 : 0.4)
                .offset(y: down ? 1 : 0)
                .animation(Motion.pop, value: configuration.isPressed)
        }
    }
}

/// A real key-cap (the Plan card's Copy and Save, the drive setup's choices): a face lighter at the top with a lit rim, on a
/// side wall that shrinks from 3pt to 1pt as the face sinks 2pt. The rim turns aqua under the pointer (a colour, not motion).
/// No tilt: HoverTilt is used on exactly three views (MOTION §3.5). `compact` is for a row of small actions: it hugs its label
/// instead of filling the width.
struct KeyCapStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View { Cap(configuration: configuration, compact: compact) }

    private struct Cap: View {
        let configuration: ButtonStyleConfiguration
        let compact: Bool
        @State private var hovering = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.colorScheme) private var scheme
        @Environment(\.colorSchemeContrast) private var contrast
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: compact ? Radius.row : Radius.tile, style: .continuous)
            let dark = scheme == .dark, down = configuration.isPressed && !reduceMotion
            let face = dark ? [Color(red: 0.133, green: 0.188, blue: 0.227), Color(red: 0.090, green: 0.133, blue: 0.169)]   // #22303A → #17222B
                            : [Color.white, Color(red: 0.933, green: 0.953, blue: 0.965)]                                      // #FFFFFF → #EEF3F6
            let wall = dark ? Color(red: 0.020, green: 0.035, blue: 0.047) : Color(red: 0.788, green: 0.839, blue: 0.871)      // #05090C / #C9D6DE
            configuration.label
                .frame(maxWidth: compact ? nil : CGFloat.infinity)
                .padding(compact ? EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12) : EdgeInsets(top: Space.m, leading: Space.m, bottom: Space.m, trailing: Space.m))
                .background {
                    if contrast == .increased {
                        shape.fill(.quaternary).overlay(shape.strokeBorder(Color.primary, lineWidth: 1))
                    } else {
                        ZStack {
                            // The side wall. In dark its rim keeps it apart from the near-black window.
                            shape.fill(wall).overlay(shape.strokeBorder(Color.white.opacity(dark ? 0.10 : 0), lineWidth: 1)).offset(y: down ? 1 : 3)
                            shape.fill(LinearGradient(colors: face, startPoint: .top, endPoint: .bottom))
                                .overlay(shape.strokeBorder(Color.white.opacity(dark ? 0.14 : 0.9), lineWidth: 1)
                                    .mask { LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center) })   // the lit top rim
                                .overlay(shape.strokeBorder(hovering && enabled ? Brand.aqua.opacity(0.8) : Color.primary.opacity(dark ? 0.08 : 0.12), lineWidth: hovering && enabled ? 1 : 0.5))
                                .shadow(color: Brand.ink.opacity(dark ? 0.5 : 0.10), radius: 8, y: 4)   // constant: never animated
                        }
                    }
                }
                .contentShape(shape)
                .opacity(enabled ? 1 : 0.5)
                .offset(y: down ? 2 : 0)
                .animation(Motion.pop, value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

/// Copying has no visible effect, so the title reads "Copied" for a moment.
struct CopyButton: View {
    var title = "Copy"
    let action: () -> Void
    @State private var copied = false

    var body: some View {
        Button(copied ? "Copied" : title) {
            action()
            copied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                copied = false
            }
        }
    }
}
