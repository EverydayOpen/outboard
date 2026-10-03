import AppKit
import OutboardCore
import SwiftUI
import UniformTypeIdentifiers

/// The only code in App/ that writes a file, and only where the user picks in a save panel (BUILD_PLAN §1 "Writes" (d),
/// safety_greps G3). It is also one of the two files allowed to touch the pasteboard (G9). Nothing is uploaded and no share
/// sheet is used: the report and the Storage Plan card are saved or copied on this Mac, nothing else.
@MainActor enum Export {
    /// "Export…" on the Activity screen: the report as Markdown or JSON. Core `ReportText` made the document from the journal
    /// as the user last saw it (paths already hidden if they ticked the box, "Sample data" in demo mode). Returns false for a
    /// card format; the save panel itself reports nothing back.
    @discardableResult static func run(_ format: ExportFormat, report: ReportDocument) -> Bool {
        switch format {
        case .markdown: save(Data(ReportText.markdown(report).utf8), as: UTType(filenameExtension: "md") ?? .plainText, name: "Outboard Report.md")
        case .json: save(Data(ReportText.json(report).utf8), as: .json, name: "Outboard Report.json")
        case .cardPNG, .cardText: return false
        }
        return true
    }

    /// The Storage Plan card: `.cardPNG` opens a save panel for the 1200 px PNG, `.cardText` copies the one-line text. False when
    /// the card could not be drawn (a beep; nothing was saved) or `format` is a report format.
    @discardableResult static func run(_ format: ExportFormat, card: StoragePlanCard) -> Bool {
        switch format {
        case .cardPNG:
            guard let data = pngData(card) else {
                NSSound.beep()
                return false
            }
            save(data, as: .png, name: "Outboard Storage Plan.png")
        case .cardText: copyText(StoragePlanText.copyText(card))
        case .markdown, .json: return false
        }
        return true
    }

    /// "Copy as image": the card on the pasteboard as PNG and TIFF, so every paste target finds one. If it cannot be drawn the
    /// text version is copied instead (and a beep sounds) and this returns false.
    @discardableResult static func copyImage(_ card: StoragePlanCard) -> Bool {
        guard let rep = render(card), let png = rep.representation(using: .png, properties: [:]) else {
            copyText(StoragePlanText.copyText(card))
            NSSound.beep()
            return false
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        pasteboard.setData(rep.tiffRepresentation, forType: .tiff)
        return true
    }

    /// Plain text to the pasteboard (the card's text version, Copy Diagnostics, Copy Path).
    static func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    #if DEBUG
    /// For the DEBUG demo (`-demoCardOut <png path>`): no panel, so it exists only in Debug builds. False if the card could not
    /// be drawn or written.
    static func writePNG(_ card: StoragePlanCard, to url: URL) -> Bool {
        guard let data = pngData(card) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
    #endif

    /// The card at 2x: 1200 px wide, 630 px or more tall, drawn by `PlanCardArt`, the same view the on-screen preview scales.
    /// VERIFY on macOS 13 and 26 that `ImageRenderer` returns 1200 x 630 for a short card and keeps the width for a tall one.
    private static func render(_ card: StoragePlanCard) -> NSBitmapImageRep? {
        let renderer = ImageRenderer(content: PlanCardArt(card: card))
        renderer.scale = 2
        return renderer.cgImage.map { NSBitmapImageRep(cgImage: $0) }
    }

    private static func pngData(_ card: StoragePlanCard) -> Data? {
        render(card)?.representation(using: .png, properties: [:])
    }

    /// A sheet on the key window when there is one, a standalone panel otherwise. The panel asks before replacing a file.
    private static func save(_ data: Data, as type: UTType, name: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = name
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
    }
}

/// Plain text to the pasteboard, spelled as in Aftertaste (Copy Path, Copy Diagnostics). Here rather than in the design system
/// because the pasteboard is allowed only in AppModel.swift and Export.swift (G9). The one implementation is `Export.copyText`.
@MainActor func copyToPasteboard(_ text: String) { Export.copyText(text) }
