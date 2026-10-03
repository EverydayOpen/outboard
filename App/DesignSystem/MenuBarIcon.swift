import AppKit
import SwiftUI

/// The menu bar item's glyph (docs/DESIGN.md §6.4), drawn once by `ImageRenderer` and cached: the mark as a template image, so
/// it follows the menu bar's appearance. No colour, no number, no animation, ever. `attention` is a different template image
/// (the tether open, the lamp hollow) swapped in while any moved folder is Drive away or Held; the item's accessibility label
/// carries the state in words.
@MainActor enum MenuBarIcon {
    static let moored: NSImage = glyph(attention: false)
    static let attention: NSImage = glyph(attention: true)

    // VERIFY on macOS 13, 15 and 26 that ImageRenderer draws the shapes and `nsImage` is non-nil; if it comes out blank,
    // ship a pre-rendered PDF in the asset catalogue instead.
    private static func glyph(attention: Bool) -> NSImage {
        let renderer = ImageRenderer(content: OutboardMark(size: 16, color: .black, attention: attention))
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage(size: NSSize(width: 16, height: 16))
        image.isTemplate = true
        return image
    }
}
