import OutboardCore
import SwiftUI

// docs/DESIGN.md §6.5 (Activity). The journal rendered, newest first, one line per step. The lines come from Core `ActivityText`
// through `AppModel.log`, so this screen, the export and crash recovery cannot disagree (invariant I10). Every line says what was
// done or checked, never what it means. The log can't be edited or cleared from here. Nothing in this screen animates: it is a list
// of facts. Written, not compiled.

struct ActivityView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.systemActions) private var system
    @State private var moveID: String?
    @State private var range = DayRange.all
    @State private var problemsOnly = false

    private enum DayRange: String, CaseIterable, Identifiable {
        case all = "All time", today = "Today", week = "Last 7 days"
        var id: String { rawValue }
    }

    private struct MoveChoice: Identifiable {
        let id: String
        let label: String
    }

    private struct DayGroup: Identifiable {
        let day: Date
        let rows: [ActivityEntry]
        var id: Date { day }
    }

    /// The moves in the log, newest first, each labelled with its recipe name and the day it began.
    private var moves: [MoveChoice] {
        var seen: Set<String> = []
        var out: [MoveChoice] = []
        for entry in model.log {
            guard let id = entry.moveID, seen.insert(id).inserted else { continue }
            out.append(MoveChoice(id: id, label: "\(entry.recipeName ?? "Move") \u{00B7} \(Format.shortDate(entry.timestamp))"))
        }
        return out.reversed()
    }

    /// Newest first, filtered.
    private var shown: [ActivityEntry] {
        let calendar = Calendar.current
        let weekAgo = Date().addingTimeInterval(-7 * 86_400)
        return model.log.reversed().filter { entry in
            if problemsOnly && entry.tone != .problem { return false }
            if let moveID, entry.moveID != moveID { return false }
            switch range {
            case .all: return true
            case .today: return calendar.isDateInToday(entry.timestamp)
            case .week: return entry.timestamp >= weekAgo
            }
        }
    }

    private func grouped(_ entries: [ActivityEntry]) -> [DayGroup] {
        let calendar = Calendar.current
        var groups: [(day: Date, rows: [ActivityEntry])] = []
        for entry in entries {
            let day = calendar.startOfDay(for: entry.timestamp)
            if let i = groups.indices.last, groups[i].day == day {
                groups[i].rows.append(entry)
            } else {
                groups.append((day: day, rows: [entry]))
            }
        }
        return groups.map { DayGroup(day: $0.day, rows: $0.rows) }
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .complete, time: .omitted)
    }

    var body: some View {
        let entries = shown
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Space.s) {
                header
                if !model.log.isEmpty { filters(count: entries.count) }
            }
            .padding(.horizontal, Space.xl)
            .padding(.top, Space.xl)
            .padding(.bottom, Space.s)
            Divider()
            if model.log.isEmpty {
                message("Nothing here yet", "What Outboard checks and changes is listed here, newest first.")
            } else if entries.isEmpty {
                VStack(spacing: Space.s) {
                    message("No lines match these filters", nil)
                    Button("Clear Filters") {
                        moveID = nil
                        range = .all
                        problemsOnly = false
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                List {
                    ForEach(grouped(entries)) { group in
                        Section(header: Text(dayTitle(group.day)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)) {
                            ForEach(group.rows) { ActivityRow(entry: $0) }
                        }
                    }
                }
                .listStyle(.inset)
            }
            Divider()
            Text("The log can't be edited or cleared from Outboard.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.horizontal, Space.xl).padding(.vertical, Space.s)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Activity").font(.system(size: 28, weight: .semibold)).tracking(-0.5)
                Text("What Outboard checked and changed, newest first.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Space.s)
            Menu {
                Button("Markdown\u{2026}") { model.exportReport(format: .markdown) }
                Button("JSON\u{2026}") { model.exportReport(format: .json) }
                Divider()
                Toggle("Hide folder paths", isOn: $model.prefs.hideFolderPathsInExports)
            } label: {
                Label("Export\u{2026}", systemImage: "square.and.arrow.up")
            }
            .fixedSize()
            .disabled(model.log.isEmpty)
            .help("Save a report of this log as Markdown or JSON")
            if let revealLog = system.revealLog {
                Button("Reveal Log in Finder") { revealLog() }
                    .buttonStyle(.bordered)
                    .help("Show the log file in Finder")
            }
        }
    }

    private func filters(count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            FlowLayout(spacing: Space.s, lineSpacing: Space.xs) {
                Picker("Folder", selection: $moveID) {
                    Text("All moves").tag(String?.none)
                    ForEach(moves) { Text($0.label).tag(Optional($0.id)) }
                }
                .pickerStyle(.menu).fixedSize()
                Picker("When", selection: $range) {
                    ForEach(DayRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu).fixedSize()
                Toggle("Problems only", isOn: $problemsOnly).toggleStyle(.checkbox)
            }
            Spacer(minLength: Space.xs)
            Text(Format.count(count, "line")).font(.system(size: 12, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private func message(_ title: String, _ detail: String?) -> some View {
        VStack(spacing: Space.xs) {
            Image(systemName: "list.bullet.rectangle").font(.system(size: 28)).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(title).font(.system(size: 15, weight: .semibold))
            if let detail { Text(detail).font(.system(size: 13)).foregroundStyle(.secondary) }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Space.xxl)
        .accessibilityElement(children: .combine)
    }
}

/// One journal line. A problem (an abort, a mismatch, a held or conflicting move, an unknown step) has a symbol and the word
/// "Problem" for VoiceOver; it is never red here, because a line does not say whether the step itself failed. The text is
/// selectable.
private struct ActivityRow: View {
    let entry: ActivityEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            if entry.tone == .problem {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary).frame(width: 16).accessibilityLabel("Problem")
            } else {
                Circle().fill(Color.secondary.opacity(0.5)).frame(width: 5, height: 5).frame(width: 16).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Text(meta).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: Space.xs)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var meta: String {
        let time = entry.timestamp.formatted(date: .omitted, time: .shortened)
        return [entry.recipeName, time].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }
}
