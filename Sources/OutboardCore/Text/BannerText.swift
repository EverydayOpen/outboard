import Foundation

/// The banners at the top of every tab while any relocation is not Healthy (BUILD_PLAN §8.1). Exact copy; `{drive}` is the label of
/// the drive the relocation lives on and `{apps}` the recipe names joined "A and B" / "A, B and C". One helper handles the verb
/// agreement. Relocations that share a kind and a drive share one banner.
public enum BannerText {
    public static let journalNotWritable = Banner(id: "journalNotWritable", kind: .journalNotWritable,
                                                  text: "I can't write the activity log, so nothing was changed.", actions: [.dismiss])
    public static let driveChanged = Banner(id: "driveChanged", kind: .driveChanged,
                                            text: "The drive changed while we were getting ready. Nothing was changed.", actions: [.dismiss])

    private static let kindOrder: [BannerKind] = [.conflict, .suspect, .foreignLink, .needsPermission, .locked, .sampleMismatch,
                                                   .differentDriveSameName, .removedUnclean, .appRunning, .revertPending, .ejected,
                                                   .driveRenamed, .backChecked, .backClean]

    public static func banners(records: [RelocationRecord], health: [RelocationHealth], returns: [String: ReturnReport]) -> [Banner] {
        let byID = Dictionary(health.map { ($0.moveID, $0) }, uniquingKeysWith: { first, _ in first })
        struct Item { var record: RelocationRecord; var health: RelocationHealth; var kind: BannerKind }
        var items: [Item] = []
        for record in records {
            guard let h = byID[record.id], let kind = kind(for: record, health: h, returns: returns[record.id]) else { continue }
            items.append(Item(record: record, health: h, kind: kind))
        }
        // Group by kind, then by drive (and by the name of the other drive for "same name").
        var groups: [(kind: BannerKind, key: String, items: [Item])] = []
        for item in items {
            let key = item.kind == .differentDriveSameName ? item.record.volume.name : item.record.volume.uuid
            if let i = groups.firstIndex(where: { $0.kind == item.kind && $0.key == key }) {
                groups[i].items.append(item)
            } else {
                groups.append((item.kind, key, [item]))
            }
        }
        let ordered = groups.enumerated().sorted { a, b in
            let ka = kindOrder.firstIndex(of: a.element.kind) ?? 99, kb = kindOrder.firstIndex(of: b.element.kind) ?? 99
            return ka != kb ? ka < kb : a.offset < b.offset
        }.map(\.element)
        return ordered.map { group in
            let records = group.items.map(\.record)
            let healths = group.items.map(\.health)
            let ids = records.map(\.id).sorted()
            let (text, actions) = copy(group.kind, records: records, healths: healths, returns: returns)
            return Banner(id: group.kind.rawValue + "|" + ids.joined(separator: ","), kind: group.kind, text: text, actions: actions, moveIDs: ids)
        }
    }

    // MARK: - Which banner

    private static func kind(for record: RelocationRecord, health h: RelocationHealth, returns: ReturnReport?) -> BannerKind? {
        switch h.state {
        case .park, .parked:
            if h.held == .appRunning && record.onDriveMissing == .revertSetting { return .revertPending }
            let needsCheck = removal(of: record, h)?.needsCheckBeforeReconnect ?? record.needsCheckBeforeReconnect
            return needsCheck ? .removedUnclean : .ejected
        case .restore:
            switch h.held {
            case nil: return nil
            case .some(.uncleanRemoval): return .removedUnclean
            case .some(.appRunning): return .appRunning
            case .some(.sampleMismatch), .some(.quickCheckFailed): return .sampleMismatch
            case .some(.wrongDrive): return .differentDriveSameName
            case .some(.needsPermission): return .needsPermission
            case .some(.readOnlyOrLocked): return .locked
            }
        case .needsPermission: return .needsPermission
        case .lockedOrReadOnly: return .locked
        case .divergedWhileAbsent, .diverged: return .conflict
        case .foreign: return .foreignLink
        case .suspect: return .suspect
        case .healthy, .retarget:
            guard let returns else { return nil }
            if returns.driveRenamed { return .driveRenamed }
            return returns.fullCheck ? .backChecked : .backClean
        case .recreate: return nil
        }
    }

    /// How the drive left: what the guard sees now, else what the park line recorded.
    private static func removal(of record: RelocationRecord, _ h: RelocationHealth) -> RemovalKind? { h.removal ?? record.removalKind }

    // MARK: - The words

    private static func names(_ records: [RelocationRecord]) -> [String] {
        var seen: Set<String> = []
        return records.map(\.recipeName).filter { seen.insert($0).inserted }
    }

    /// The one verb-agreement helper: "is" or "are", "it" or "them", "that app" or "those apps".
    private struct Agreement {
        let plural: Bool
        let manyApps: Bool
        init(_ names: [String]) {
            manyApps = names.count > 1
            plural = names.count > 1 || (names.first.map(RecipeNames.isPlural) ?? false)
        }
        var be: String { plural ? "are" : "is" }
        var it: String { plural ? "them" : "it" }
        var theApps: String { manyApps ? "those apps" : "that app" }
        var each: String { manyApps ? "each one" : "it" }
    }

    private static func copy(_ kind: BannerKind, records: [RelocationRecord], healths: [RelocationHealth],
                             returns: [String: ReturnReport]) -> (String, [BannerAction]) {
        let drive = records[0].volume.label
        let list = names(records)
        let apps = RecipeNames.join(list)
        let a = Agreement(list)
        switch kind {
        case .ejected:
            let clause = ejectedClause(records, healths, a)
            return ("\(drive) was ejected. \(apps) \(a.be) on it, so \(a.theApps) can't see \(a.it). \(clause) Plug it back in and we'll put things back.", [])
        case .removedUnclean:
            // "Removed without ejecting" is said only when the guard saw the unmount without an eject first; a drive that was already
            // gone when Outboard looked is not described as pulled.
            if zip(records, healths).allSatisfy({ removal(of: $0, $1) == .unclean }) {
                return ("\(drive) was removed without ejecting. Please check your files before reconnecting.", [.checkAndReconnect])
            }
            return ("\(drive) was not connected when Outboard looked, and Outboard didn't see how it was removed. Please check your files before reconnecting, because Outboard can't tell how it left.",
                    [.checkAndReconnect])
        case .backClean:
            let r = returns[records[0].id]
            let checked: String
            if let r, r.sampleOf > 0 {
                checked = "Checked \(Format.number(r.sampled)) of \(Format.number(r.sampleOf)) files: all matched."
            } else if let r {
                checked = "Checked \(Format.count(r.sampled, "file")): all matched."
            } else {
                checked = ""
            }
            return (("\(drive) is back. \(apps) \(a.be) connected again. " + checked).trimmingCharacters(in: .whitespaces), [.dismiss])
        case .backChecked:
            let r = returns[records[0].id] ?? ReturnReport()
            var text = "Checked \(Format.count(r.comparedFiles, "file")) that haven't changed since they were copied: all matched."
            if r.changedSince > 0 { text += " \(Format.count(r.changedSince, "file")) \(r.changedSince == 1 ? "has" : "have") changed since and weren't compared." }
            return (text, [.dismiss])
        case .appRunning:
            let running = RecipeNames.join(unique(records.map { RecipeNames.appName($0.recipeID) }))
            let object = records.count == 1 ? nounPhrase(records[0]) : "them"
            return ("\(drive) is back. Quit \(running) and we'll reconnect \(object).", [])
        case .sampleMismatch:
            let reports = records.compactMap { returns[$0.id] }
            let mismatches = reports.reduce(0) { $0 + $1.mismatches }
            let sampled = reports.reduce(0) { $0 + $1.sampled }
            let canForce = records.allSatisfy { Held.allowsReconnectAnyway($0) }
            var actions: [BannerAction] = [.showFiles]
            if canForce { actions.append(.reconnectAnyway) }
            actions.append(.leaveDisconnected)
            if mismatches > 0 && sampled > 0 {
                return ("\(Format.number(mismatches)) of \(Format.number(sampled)) files differ from when they were copied. We haven't reconnected anything.", actions)
            }
            return ("Files on \(drive) don't match what was copied. We haven't reconnected anything.", [.checkAndReconnect] + actions)
        case .differentDriveSameName:
            return ("A drive named \(records[0].volume.name) is connected, but it isn't the one we moved your data to. We left everything as it was.", [])
        case .driveRenamed:
            return ("\(drive) was renamed. We updated the link for \(apps).", [.dismiss])
        case .conflict:
            let away = healths.contains { $0.state == .divergedWhileAbsent }
            return ("Something new appeared where \(apps) should be\(away ? " (made while the drive was away)" : ""). We haven't touched it.",
                    [.showInFinder, .setAsideAndReconnect, .leaveAsIs])
        case .needsPermission:
            return ("macOS blocked access to the drive.", [.openPrivacySettings])
        case .revertPending:
            let running = RecipeNames.join(unique(records.map { RecipeNames.appName($0.recipeID) }))
            return ("\(drive) is away. Quit \(running) and we'll put \(a.manyApps ? "their settings" : "its setting") back.", [])
        case .locked:
            return ("\(drive) is locked or read-only, so Outboard can't change anything on it. \(apps) may not see \(a.manyApps ? "their" : "its") data.", [])
        case .foreignLink:
            return ("A link where \(apps) should be isn't one Outboard made. Outboard has stopped managing \(a.it), and nothing was changed.", [.showInFinder, .leaveAsIs])
        case .suspect:
            return ("\(drive) is connected, but it doesn't match what Outboard moved your data to. We haven't touched anything.", [.showInFinder, .forget])
        case .journalNotWritable:
            return (journalNotWritable.text, journalNotWritable.actions)
        case .driveChanged:
            return (driveChanged.text, driveChanged.actions)
        }
    }

    /// What the guard did about the missing drive. "We put a note" and "We put its setting back" are said only when every relocation that
    /// asks for one is parked; one that is not yet parked, or whose park failed, is said as that.
    private static func ejectedClause(_ records: [RelocationRecord], _ healths: [RelocationHealth], _ a: Agreement) -> String {
        let modes = Set(records.map(\.onDriveMissing))
        let acting = zip(records, healths).filter { $0.0.onDriveMissing == .parkPlaceholder || $0.0.onDriveMissing == .revertSetting }
        if acting.isEmpty {
            return "We left \(a.manyApps ? "their settings" : "its setting") as \(a.manyApps ? "they were" : "it was")."
        }
        let pending = acting.filter { $0.1.state != .parked }
        let notes = modes == [.parkPlaceholder], settings = modes == [.revertSetting]
        if pending.isEmpty {
            if notes { return "We put a note where \(a.manyApps ? "each one was" : "it was")." }
            if settings { return "We put \(a.manyApps ? "their settings" : "its setting") back." }
            return "We put a note or the setting back where needed."
        }
        if pending.contains(where: { $0.1.parkFailed }) {
            if notes { return "Outboard couldn't put a note there." }
            if settings { return "Outboard couldn't put \(a.manyApps ? "their settings" : "its setting") back." }
            return "Outboard couldn't put a note or the setting back."
        }
        if notes { return "We haven't put a note where \(a.manyApps ? "each one was" : "it was") yet." }
        if settings { return "We haven't put \(a.manyApps ? "their settings" : "its setting") back yet." }
        return "We haven't put a note or the setting back yet."
    }

    private static func unique(_ items: [String]) -> [String] {
        var seen: Set<String> = []
        return items.filter { seen.insert($0).inserted }
    }

    /// "its models" for "Ollama models" (the app's name is dropped), "your iPhone backups" when there is no app to drop.
    private static func nounPhrase(_ record: RelocationRecord) -> String {
        let app = RecipeNames.appName(record.recipeID)
        if record.recipeName.hasPrefix(app + " ") { return "its " + record.recipeName.dropFirst(app.count + 1) }
        return "your " + record.recipeName
    }
}
