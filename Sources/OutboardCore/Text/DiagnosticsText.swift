import Foundation

/// "Copy diagnostics": the eligibility signals per volume and the errno matrix per measured folder, so week-one testers can settle the
/// `diskutil` keys and the permission questions. **No file names, no folder names, no drive names, no volume IDs**: a volume is "Volume 1",
/// a folder is its recipe id.
public enum DiagnosticsText {
    public static func text(volumes: [DriveFacts], scans: [SizeScan], osVersion: String, appVersion: String) -> String {
        var out: [String] = ["Outboard \(appVersion) on macOS \(osVersion)", ""]
        out.append("Volumes")
        if volumes.isEmpty { out.append("- none") }
        for (i, v) in volumes.enumerated() {
            out.append("- Volume \(i + 1): \(v.fileSystem.rawValue) (\(clean(v.fileSystemRaw))), bus \(v.bus.rawValue) (\(clean(v.busRaw)))")
            out.append("  local \(v.isLocal), internal \(v.isInternal.rawValue), writable \(v.isWritable.rawValue), solid state \(v.isSolidState.rawValue), encrypted \(v.isEncrypted.rawValue), locked \(v.isLocked)")
            out.append("  ownership \(v.ownershipHonoured.rawValue), symlinks \(v.supportsSymlinks.rawValue), hard links \(v.supportsHardLinks.rawValue), case-sensitive \(v.isCaseSensitive.rawValue), SMART \(v.smart.rawValue)")
            out.append("  Time Machine: role \(v.timeMachine.apfsBackupRole.rawValue), tmutil \(v.timeMachine.listedByTmutil.rawValue), root folder \(v.timeMachine.backupFolderAtRoot.rawValue), sibling \(v.timeMachineSiblingInContainer)")
            out.append("  uuid \(v.uuid == nil ? "missing" : "present"), standard mount \(v.isStandardMount), same-name volumes \(v.sameNameCount), synced \(v.isSyncedLocation), marker \(v.hasOutboardMarker)")
            out.append("  capacity \(Format.bytes(v.capacityBytes)), free \(v.availableBytes.map { Format.bytes($0) } ?? "unknown"), quota \(v.quotaBytes.map { Format.bytes($0) } ?? "none"), link \(v.linkMegabitsPerSecond.map { "\($0) Mbit/s" } ?? "unknown")")
            let verdicts = Eligibility.evaluate(volume: v, recipe: nil, source: nil, policy: .release).verdicts
            out.append("  verdicts: " + (verdicts.isEmpty ? "none" : verdicts.map { "\($0.rule.rawValue) \($0.outcome.rawValue)" }.joined(separator: ", ")))
        }
        out.append("")
        out.append("Folders")
        if scans.isEmpty { out.append("- none") }
        for s in scans {
            var line = "- \(s.recipeID): \(s.state.rawValue)"
            if let reason = s.reason { line += ", \(reason.rawValue)" }
            if let code = s.errnoCode { line += ", errno \(code)" }
            line += ", link \(s.isLink)"
            let f = s.fingerprint
            line += ", \(f.files) files, \(f.directories) folders, \(f.symlinks) links, hard-linked \(f.hardLinkedFiles), special \(f.specialFiles), dataless \(f.datalessFiles), sparse \(f.sparseFiles)"
            out.append(line)
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// The raw format and bus strings are short names from the system; keep them to plain characters so a stray value can't carry a name.
    private static func clean(_ s: String) -> String {
        let kept = s.unicodeScalars.filter { ($0.value >= 48 && $0.value <= 57) || ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) || $0 == " " || $0 == "-" || $0 == "+" }
        return String(String.UnicodeScalarView(kept.prefix(40)))
    }
}
