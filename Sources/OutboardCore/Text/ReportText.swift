import Foundation

/// The export report (BUILD_PLAN §4.5, safety-ux §8.2): built from the records and the journal, rendered as Markdown and JSON. Both
/// are golden-file tested. Nothing is written without a save panel and nothing is uploaded. The footer is fixed and never widened.
public enum ReportText {
    /// Verbatim; edit it only to narrow it.
    public static let footer = "This report lists what Outboard did and checked. It does not show that your data is undamaged or that a drive is reliable. Outboard has not been tried on every Mac or every drive."
    public static let provenance = "Generated on this Mac. Not uploaded."

    /// `health` is optional: the words from the live guard ("Healthy", "Drive away"). Without it a parked relocation says "Drive away"
    /// and an active one says nothing about health (the report claims only what it was told).
    public static func document(records: [RelocationRecord], log: [JournalEntry], drives: [DriveFacts], options: ReportOptions,
                                health: [String: Health] = [:]) -> ReportDocument {
        let ordered = records.sorted { $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id < $1.id }
        var names: [String: String] = [:]
        for c in Catalogue.all { names[c.id] = c.name }
        for r in ordered { names[r.recipeID] = r.recipeName }

        // Drives used, in order of first use. With the hide setting on they are "Drive 1", "Drive 2" and carry no identifier.
        var driveRows: [ReportDrive] = []
        var seen: Set<String> = []
        var standIns: [String: String]?
        if options.hidePaths { standIns = [:] }
        for r in ordered where seen.insert(r.volume.uuid.uppercased()).inserted {
            let facts = drives.first { $0.uuid?.uppercased() == r.volume.uuid.uppercased() }
            var name = r.volume.name
            var prefix = String(r.volume.uuid.uppercased().prefix(8))
            if standIns != nil {
                name = "Drive \(seen.count)"
                prefix = ""
                standIns?[r.volume.uuid.uppercased()] = name
            }
            driveRows.append(ReportDrive(name: name, uuidPrefix: prefix, format: facts?.fileSystem.displayName ?? "not connected",
                                         encrypted: facts?.isEncrypted ?? .unknown, firstUsed: r.createdAt))
        }

        var relocations: [ReportRelocation] = []
        var problems: [String] = []
        for r in ordered {
            let lines = log.filter { $0.id == r.id }
            let timeline = ActivityText.rows(from: lines, problemsOnly: false, driveLabels: standIns)
            let driveText = options.hidePaths ? "\(r.recipeName) on \(standIns?[r.volume.uuid.uppercased()] ?? "a drive")" : "\(r.volume.label): \(r.relativePath)"
            var healthWord: String?
            if r.state.isActive { healthWord = health[r.id]?.displayName ?? (r.isParked ? Health.driveAway.displayName : nil) }
            var unresolved: [String] = []
            if r.needsCheckBeforeReconnect && r.state.isActive {
                let how = r.removalKind == .unclean ? "The drive was removed without ejecting"
                                                    : "The drive was not connected when Outboard looked, and Outboard didn't see how it was removed"
                unresolved.append("\(how); Check and reconnect is needed before it is reconnected.")
            }
            if r.safetyCopyReminderDue(now: options.now) { unresolved.append("The safety copy has been on this Mac for \(Limits.safetyCopyReminderDays) days or more.") }
            if r.state == .swapped { unresolved.append("Waiting for you to try the app and confirm.") }
            relocations.append(ReportRelocation(
                recipeID: r.recipeID, recipeName: r.recipeName, methodLabel: r.method.displayName,
                source: options.hidePaths ? r.recipeName : r.macPath, destination: driveText, logicalBytes: r.logicalBytes, fileCount: r.fileCount,
                state: r.state, health: healthWord, safetyCopy: r.safetyCopy, verification: r.verification, unresolved: unresolved, timeline: timeline))
            for p in problemTexts(of: r, lines: lines, standIns: standIns) { problems.append("\(Format.date(r.createdAt)) \(r.recipeName): \(p)") }
        }
        return ReportDocument(appVersion: options.appVersion, macOSVersion: options.macOSVersion, macModel: options.macModel, generatedAt: options.now,
                              provenance: provenance, isSample: options.isSample, drives: driveRows, relocations: relocations, problems: problems, footer: footer)
    }

    /// The record's problems. The ones folded from journal lines name the drive, so with the hide setting on they are rendered again from
    /// the lines with the stand-in names; the out-of-order notes (which name no drive) are kept as they are.
    private static func problemTexts(of r: RelocationRecord, lines: [JournalEntry], standIns: [String: String]?) -> [String] {
        guard let standIns else { return r.problems }
        var out = r.problems.filter { $0.hasPrefix(MoveMachine.outOfOrderPrefix) }
        let names = [r.recipeID: r.recipeName]
        for line in lines where line.isProblem || line.moveStep == nil {
            let text = ActivityText.entry(for: line, recipeNames: names, driveLabels: standIns, moveVolume: r.volume.uuid).text
            if !out.contains(text) { out.append(text) }
        }
        return out
    }

    // MARK: - Markdown

    public static func markdown(_ d: ReportDocument) -> String {
        var out: [String] = ["# Outboard report", ""]
        if d.isSample { out += ["Sample data", ""] }
        out.append("- Outboard \(d.appVersion)")
        out.append("- macOS \(d.macOSVersion)")
        if let model = d.macModel, !model.isEmpty { out.append("- Mac: \(model)") }
        out.append("- Generated \(Format.dateTime(d.generatedAt))")
        out.append("- \(d.provenance)")
        out.append("")
        out.append("## Drives")
        out.append("")
        if d.drives.isEmpty { out.append("No drive has been used.") }
        for drive in d.drives {
            var line = "- \(drive.name)" + (drive.uuidPrefix.isEmpty ? "" : " (\(drive.uuidPrefix))") + ": \(drive.format), encrypted: \(drive.encrypted.rawValue)"
            if let first = drive.firstUsed { line += ", first used \(Format.date(first))" }
            out.append(line)
        }
        out.append("")
        out.append("## Moves")
        out.append("")
        if d.relocations.isEmpty { out.append("Nothing has been moved.") }
        for r in d.relocations {
            out.append("### \(r.recipeName)")
            out.append("")
            out.append("- Method: \(r.methodLabel)")
            out.append("- From: \(r.source)")
            out.append("- To: \(r.destination)")
            out.append("- Size: \(Format.bytes(r.logicalBytes)), \(Format.count(r.fileCount, "file"))")
            out.append("- State: \(r.state.displayName)")
            if let h = r.health { out.append("- Health: \(h)") }
            out.append("- Original on this Mac: \(safetyCopyText(r.safetyCopy))")
            if let v = r.verification {
                var line = "- Compared: \(Format.count(v.filesCompared, "file")) (\(Format.bytes(v.bytesCompared))) by size and \(v.algorithm), \(v.differences == 1 ? "1 difference" : "\(Format.number(v.differences)) differences")"
                line += v.destinationReadUncached ? "; the copy on the drive was read without the page cache" : ""
                out.append(line + ".")
                if v.hardLinkedCopiedSeparately > 0 {
                    out.append("- \(Format.count(v.hardLinkedCopiedSeparately, "hard-linked file")) \(v.hardLinkedCopiedSeparately == 1 ? "was" : "were") copied as separate files.")
                }
            }
            for u in r.unresolved { out.append("- Open: \(u)") }
            out.append("")
            out.append("Timeline")
            out.append("")
            if r.timeline.isEmpty { out.append("- No log lines.") }
            for e in r.timeline { out.append("- \(Format.dateTime(e.timestamp))  \(e.text)") }
            out.append("")
        }
        out.append("## Problems")
        out.append("")
        if d.problems.isEmpty { out.append("None recorded.") }
        for p in d.problems { out.append("- \(p)") }
        out.append("")
        out.append("---")
        out.append("")
        out.append(d.footer)
        return out.joined(separator: "\n") + "\n"
    }

    private static func safetyCopyText(_ s: SafetyCopyState) -> String {
        switch s {
        case .none: return "not present"
        case .kept: return "kept on this Mac, renamed"
        case .inTrash: return "in the Trash"
        case .gone: return "not found where it was left"
        }
    }

    // MARK: - JSON

    /// Sorted keys, two-space indent, ISO-8601 whole seconds, `schema: 1`.
    public static func json(_ d: ReportDocument) -> String {
        func drive(_ x: ReportDrive) -> JSONValue {
            .object(["name": .string(x.name), "uuidPrefix": x.uuidPrefix.isEmpty ? JSONValue.null : JSONValue.string(x.uuidPrefix), "format": .string(x.format),
                     "encrypted": .string(x.encrypted.rawValue), "firstUsed": x.firstUsed.map { JSONValue.string(ISO8601Lite.string($0)) } ?? .null])
        }
        func verification(_ v: VerificationSummary?) -> JSONValue {
            guard let v else { return .null }
            return .object(["algorithm": .string(v.algorithm), "filesCompared": .num(v.filesCompared), "bytesCompared": .unum(v.bytesCompared),
                            "symlinksCompared": .num(v.symlinksCompared), "differences": .num(v.differences),
                            "hardLinkedCopiedSeparately": .num(v.hardLinkedCopiedSeparately),
                            "destinationReadUncached": .bool(v.destinationReadUncached), "manifestDigest": .string(v.manifestDigest),
                            "completedAt": .string(ISO8601Lite.string(v.completedAt))])
        }
        func relocation(_ r: ReportRelocation) -> JSONValue {
            .object([
                "recipeID": .string(r.recipeID), "recipeName": .string(r.recipeName), "methodLabel": .string(r.methodLabel),
                "source": .string(r.source), "destination": .string(r.destination), "logicalBytes": .unum(r.logicalBytes),
                "fileCount": .num(r.fileCount), "state": .string(r.state.rawValue), "health": .optional(r.health),
                "safetyCopy": .string(r.safetyCopy.rawValue), "verification": verification(r.verification),
                "unresolved": .strings(r.unresolved),
                "timeline": .array(r.timeline.map { e in
                    .object(["at": .string(ISO8601Lite.string(e.timestamp)), "step": .string(e.step), "text": .string(e.text),
                             "problem": .bool(e.tone == .problem)])
                }),
            ])
        }
        return JSONValue.object([
            "schema": .num(d.schema),
            "appVersion": .string(d.appVersion), "macOSVersion": .string(d.macOSVersion), "macModel": .optional(d.macModel),
            "generatedAt": .string(ISO8601Lite.string(d.generatedAt)), "provenance": .string(d.provenance), "isSample": .bool(d.isSample),
            "drives": .array(d.drives.map(drive)), "relocations": .array(d.relocations.map(relocation)),
            "problems": .strings(d.problems), "footer": .string(d.footer),
        ]).render() + "\n"
    }
}
