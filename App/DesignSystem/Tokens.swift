import AppKit
import OutboardCore
import SwiftUI

// docs/DESIGN.md §6.1. Spacing, radii, the brand colours and the model-to-look mappings. No view lives here.

/// Spacing in points. `xxl` is the screen padding, `l` the bottom bar's.
enum Space {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 20
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 40
}

/// Concentric radii (DESIGN §6.1): plates 18, tiles 14, rows 12, chips 8.
enum Radius {
    static let card: CGFloat = 12
    static let chip: CGFloat = 8
    static let row: CGFloat = 12
    static let tile: CGFloat = 14
    static let plate: CGFloat = 18
}

/// docs/DESIGN.md §1, §6. Aqua is the one accent ("the line to the drive"); green only for all matched, Healthy and a moved
/// row's check; red only on a failed row's symbol. Slate and cyan exist only inside `Dusk` and the card: they are sky and
/// water, not UI.
enum Brand {
    /// Slate-black: the soft shadow under porcelain surfaces is tinted with it, never neutral grey (rule 3).
    static let ink = Color(red: 0.039, green: 0.102, blue: 0.157)                                     // #0A1A28
    /// The mooring key-cap fill and every aqua fill. Near-black text on it (10.4:1).
    static let aqua = Color(red: 0.310, green: 0.890, blue: 0.847)                                    // #4FE3D8
    static let onAqua = Color(red: 0.020, green: 0.141, blue: 0.129)                                  // #052421
    /// Aqua as text, a symbol, the tether or the outline: readable on paper and on the dusk quay (5.1:1 / 11.5:1).
    static let aquaInk = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.494, green: 0.925, blue: 0.894, alpha: 1)                            // #7EECE4
            : NSColor(srgbRed: 0.043, green: 0.435, blue: 0.451, alpha: 1)                            // #0B6F73
    })
    /// The lamp. Never on a control, a chip or text.
    static let lamp = Color(red: 0.373, green: 0.910, blue: 0.863)                                    // #5FE8DC
    static let skyTop = Color(red: 0.063, green: 0.110, blue: 0.173)                                  // #101C2C
    static let skyLow = Color(red: 0.055, green: 0.216, blue: 0.251)                                  // #0E3740
    /// The card's fixed night colours (an object, the same in both schemes; DESIGN §6.6).
    static let cardTop = Color(red: 0.043, green: 0.086, blue: 0.125)                                 // #0B1620
    static let cardBottom = Color(red: 0.059, green: 0.106, blue: 0.141)                              // #0F1B24
    static let cardText = Color(red: 0.918, green: 0.949, blue: 0.961)                                // #EAF2F5
    static let cardSecondary = Color(red: 0.616, green: 0.690, blue: 0.729)                           // #9DB0BA
    static let cardAccent = Color(red: 0.494, green: 0.925, blue: 0.894)                              // #7EECE4
}

extension Health {
    /// The pill word is `displayName` (Model). Health is carried by the word, never by colour alone (§1.1 rule 4): only
    /// Healthy gets the green dot; every other state gets the neutral dot. Never red: a problem is a fact to read.
    var tint: Color { self == .healthy ? .green : .secondary }
}

extension MethodKind {
    /// Neutral SF Symbols, never vendor logos (BUILD_PLAN §8). VERIFY each in the SF Symbols app: availability macOS 13 or earlier.
    var symbol: String {
        switch self {
        case .defaults: return "slider.horizontal.3"       // Official setting
        case .symlink: return "link"                       // Community method
        case .guided: return "list.number"                 // Guided
        case .never: return "hand.raised"                  // Not offered
        }
    }
}

extension RecipeID {
    /// One neutral symbol per catalogue entry; unknown ids get a folder. `RecipeID` is a typealias of `String`, so this adds
    /// `symbol` to every `String`; read it only on a recipe id. VERIFY each symbol on macOS 13.
    var symbol: String {
        switch self {
        case "xcode-deriveddata": return "hammer"
        case "xcode-archives": return "archivebox"
        case "ollama-models", "huggingface-hub-cache", "llamacpp-cache", "lmstudio-models": return "cube"
        case "npm-cache": return "shippingbox"
        case "ios-device-backups": return "iphone"
        case "mas-large-apps": return "bag"
        case "photos-library": return "photo.on.rectangle"
        case "music-media-folder": return "music.note"
        case "final-cut-library": return "film"
        case "logic-sound-library": return "pianokeys"
        case "steam-library": return "gamecontroller"
        case "android-sdk": return "chevron.left.forwardslash.chevron.right"
        default: return hasPrefix("never-") ? "hand.raised" : "folder"
        }
    }
}

extension StepStatus {
    /// Activity rows and the result sheet: a symbol in a status colour, the word beside it. Red only here, only on failed.
    var symbol: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .refused: return "hand.raised"
        case .mismatch: return "arrow.left.arrow.right.circle"
        case .interrupted: return "pause.circle"
        case .failed: return "xmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .ok: return .green
        case .failed: return .red
        default: return .secondary
        }
    }
}

extension BannerKind {
    /// A banner's leading symbol: neutral, secondary tint, never red (MOTION §1.1 rule 3). The text says what happened.
    var symbol: String {
        switch self {
        case .ejected, .locked: return "externaldrive.badge.minus"
        case .removedUnclean: return "externaldrive.badge.exclamationmark"
        case .backClean, .backChecked, .driveRenamed: return "externaldrive.badge.checkmark"
        case .appRunning, .revertPending: return "app.badge"
        case .sampleMismatch, .conflict, .foreignLink, .suspect, .differentDriveSameName, .driveChanged: return "questionmark.folder"
        case .needsPermission: return "lock"
        case .journalNotWritable: return "doc.badge.ellipsis"
        }
    }
}
