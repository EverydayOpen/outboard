import Foundation

/// The Storage Plan card as plain text and numbers (BUILD_PLAN §8.1, APP6 §3.3). The app draws it; this decides what it says.
/// It never shows paths, file names, the user's name, drive names (before a move) or UUIDs. Rows are rounded with the
/// largest-remainder method so they add up to the headline, and bar fractions follow the unrounded bytes.
public enum StoragePlanText {
    static let footnote = "Sizes are what these folders take on disk. Space comes back when the originals are trashed and the Trash is emptied."
    static let afterMovesFootnote = "Sizes are those of the folders when they were moved. Space comes back when the originals are trashed and the Trash is emptied."
    static let maxRows = 3
    static let hiddenHeadline = "Some moves are hidden for now"

    public static func card(from plan: StoragePlan, relocations: [RelocationRecord], prefs: Preferences, isSample: Bool) -> StoragePlanCard {
        let active = relocations.filter { $0.direction == .toDrive && $0.state.isActive }
        if !active.isEmpty { return afterMoves(active, plan: plan, prefs: prefs, isSample: isSample) }

        let movable = plan.movable.filter { $0.offeredBytes > 0 }
        let unmeasured = plan.items.filter { $0.status == .notMeasured && $0.kind != .guided }
        let guidedLines = guidedLines(plan, showNames: prefs.showAppNamesOnCard)
        let total = movable.reduce(UInt64(0)) { $0 &+ $1.offeredBytes }
        let hiddenBytes = plan.hiddenPresent.reduce(UInt64(0)) { $0 &+ $1.allocatedBytes }
        let bigEnough = total >= Limits.smallPlanBytes

        let variant: CardVariant
        if !unmeasured.isEmpty { variant = .partlyMeasured }
        else if bigEnough { variant = guidedLines.isEmpty ? .plan : .planWithGuided }
        else if !movable.isEmpty || !guidedLines.isEmpty || hiddenBytes > 0 { variant = .small }
        else { variant = .nothingFound }

        var rows: [CardRow] = []
        var moreLine: String?
        let headline: String
        var measuredLine = "Measured on this Mac. Nothing was moved."

        switch variant {
        case .plan, .planWithGuided, .partlyMeasured:
            let (measuredRows, more) = rowsFor(movable, showNames: prefs.showAppNamesOnCard)
            rows = measuredRows
            moreLine = more
            headline = bigEnough ? "Your Mac could free up to \(Format.gigabytes(Format.gigabytesRounded(movable.map(\.offeredBytes)).reduce(0, +)))"
                                 : "Not everything could be measured"
            if variant == .partlyMeasured {
                for (i, item) in unmeasured.enumerated() {
                    let needsAccess = item.notMeasuredReason == .needsFullDiskAccess
                    let partial = item.isLowerBound
                    rows.append(CardRow(id: item.recipeID, label: prefs.showAppNamesOnCard ? item.name : "Folder \(movable.count + i + 1)", bytes: 0,
                                        text: partial ? Format.atLeast(item.allocatedBytes) : "not measured", fraction: 0,
                                        note: partial ? "only partly measured" : needsAccess ? "needs Full Disk Access" : "couldn't be read"))
                }
            }
        case .small where hiddenBytes > 0:
            headline = hiddenHeadline
            measuredLine = "\(Format.bytes(hiddenBytes)) sits in folders whose moves are hidden until they are tried on a real Mac. Turn them on in Preferences to see them."
        case .small:
            headline = "Nothing big to move"
            if let largest = movable.max(by: { $0.offeredBytes < $1.offeredBytes }) {
                measuredLine = "The largest is \(prefs.showAppNamesOnCard ? largest.name : "one folder") at \(Format.bytes(largest.offeredBytes))."
            } else {
                measuredLine = "Nothing here is a folder Outboard moves itself."
            }
        case .nothingFound:
            headline = "No big folders from the apps Outboard knows"
            let known = plan.items.filter { $0.kind != .never }.count
            measuredLine = "Outboard knows \(known) apps. More are added in updates."
        case .afterMoves:
            headline = ""   // not reachable here: handled above
        }
        return StoragePlanCard(variant: variant, headline: headline, rows: rows, moreLine: moreLine,
                               guidedLines: variant == .plan || variant == .nothingFound ? [] : guidedLines,
                               measuredLine: measuredLine, footnote: footnote, totalBytes: total, isSample: isSample,
                               showsAppNames: prefs.showAppNamesOnCard, measuredAt: plan.measuredAt)
    }

    /// The text version: one line, copied to the pasteboard. "My Mac could free up to 87 GB: Xcode 41 GB, Ollama 30 GB, iPhone backups
    /// 16 GB. Measured with Outboard; nothing moved. everydayopen.github.io/outboard"
    public static func copyText(_ card: StoragePlanCard) -> String {
        let site = card.website
        func list() -> String {
            var parts = card.rows.filter { $0.bytes > 0 }.map { "\(card.showsAppNames ? RecipeNames.shortName($0.id) : $0.label) \($0.text)" }
            if let more = card.moreLine { parts.append(more) }
            return parts.joined(separator: ", ")
        }
        switch card.variant {
        case .plan, .planWithGuided, .partlyMeasured:
            let tail = "Measured with Outboard; nothing moved. \(site)"
            guard card.headline.hasPrefix("Your Mac") else { return "Part of my Mac couldn't be measured by Outboard; nothing moved. \(site)" }
            let head = "My" + card.headline.dropFirst("Your".count)
            if card.showsAppNames { return "\(head): \(list()). \(tail)" }
            let n = card.rows.filter { $0.bytes > 0 }.count + (card.moreLine == nil ? 0 : 1)
            return "\(head) from \(Format.count(n, "folder")). \(tail)"
        case .small where card.headline == hiddenHeadline:
            return "Some moves on my Mac are hidden until they are tried on a real Mac. Measured with Outboard; nothing moved. \(site)"
        case .small:
            return "Nothing big to move on my Mac. Measured with Outboard; nothing moved. \(site)"
        case .nothingFound:
            return "No big folders from the apps Outboard knows. Measured with Outboard; nothing moved. \(site)"
        case .afterMoves:
            let tail = "Moved with Outboard; every step is in its log. \(site)"
            if card.showsAppNames { return "\(card.headline): \(list()). \(tail)" }
            return "\(card.headline). \(tail)"
        }
    }

    // MARK: - Rows

    private static func rowsFor(_ items: [PlanItem], showNames: Bool) -> (rows: [CardRow], more: String?) {
        guard !items.isEmpty else { return ([], nil) }
        let ordered = items.sorted { $0.offeredBytes != $1.offeredBytes ? $0.offeredBytes > $1.offeredBytes : $0.name < $1.name }
        let rounded = Format.gigabytesRounded(ordered.map(\.offeredBytes))
        let shown = ordered.prefix(maxRows)
        let top = Double(shown.first?.offeredBytes ?? 1)
        let rows = shown.enumerated().map { i, item in
            CardRow(id: item.recipeID, label: showNames ? item.name : "Folder \(i + 1)", bytes: item.offeredBytes, text: Format.gigabytes(rounded[i]),
                    fraction: top > 0 ? Double(item.offeredBytes) / top : 0)
        }
        var more: String?
        if ordered.count > maxRows {
            let rest = rounded[maxRows...].reduce(0, +)
            more = "and \(ordered.count - maxRows) more (\(Format.gigabytes(rest)))"
        }
        return (rows, more)
    }

    private static func guidedLines(_ plan: StoragePlan, showNames: Bool) -> [String] {
        let big = plan.guided.filter { $0.allocatedBytes >= Limits.smallPlanBytes && !$0.isLowerBound }
            .sorted { $0.allocatedBytes > $1.allocatedBytes }
        return big.prefix(3).map { item in
            if showNames {
                return "Also on this Mac: \(item.name) \(Format.bytes(item.allocatedBytes)). \(RecipeNames.appName(item.recipeID)) moves it itself; Outboard shows the steps."
            }
            return "Also on this Mac: a library of \(Format.bytes(item.allocatedBytes)). Its app moves it itself; Outboard shows the steps."
        }
    }

    // MARK: - After moves

    private static func afterMoves(_ active: [RelocationRecord], plan: StoragePlan, prefs: Preferences, isSample: Bool) -> StoragePlanCard {
        let ordered = active.sorted { $0.logicalBytes != $1.logicalBytes ? $0.logicalBytes > $1.logicalBytes : $0.id < $1.id }
        let rounded = Format.gigabytesRounded(ordered.map(\.logicalBytes))
        let total = ordered.reduce(UInt64(0)) { $0 &+ $1.logicalBytes }
        let top = Double(ordered.first?.logicalBytes ?? 1)
        let rows = ordered.prefix(maxRows).enumerated().map { i, r in
            CardRow(id: r.recipeID, label: prefs.showAppNamesOnCard ? r.recipeName : "Folder \(i + 1)", bytes: r.logicalBytes,
                    text: Format.gigabytes(rounded[i]), fraction: top > 0 ? Double(r.logicalBytes) / top : 0)
        }
        var more: String?
        if ordered.count > maxRows {
            more = "and \(ordered.count - maxRows) more (\(Format.gigabytes(rounded[maxRows...].reduce(0, +))))"
        }
        let drives = Set(ordered.map(\.volume.uuid))
        // The card is the shareable one: it never carries a drive's own name (app screens and the report do).
        let driveText = drives.count == 1 ? "your Outboard drive" : "\(drives.count) drives"
        let kept = ordered.filter { $0.safetyCopy == .kept }.reduce(UInt64(0)) { $0 &+ $1.logicalBytes }
        let inTrash = ordered.filter { $0.safetyCopy == .inTrash }.reduce(UInt64(0)) { $0 &+ $1.logicalBytes }
        let line: String
        if kept > 0 { line = "Safety copies still on this Mac: \(Format.bytes(kept)) until you confirm." }
        else if inTrash > 0 { line = "Originals are in the Trash: \(Format.bytes(inTrash)) until you empty it." }
        else { line = "No safety copies remain on this Mac." }
        return StoragePlanCard(variant: .afterMoves, headline: "Moved \(Format.gigabytes(rounded.reduce(0, +))) to \(driveText)", rows: rows, moreLine: more,
                               guidedLines: [], measuredLine: line, footnote: afterMovesFootnote, totalBytes: total, isSample: isSample,
                               showsAppNames: prefs.showAppNamesOnCard,
                               measuredAt: ordered.map(\.updatedAt).max() ?? plan.measuredAt)
    }
}
