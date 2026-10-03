import Foundation

/// The destination rules E1 to E19 (BUILD_PLAN §4.3, APP6 §4.3). Pure: the Mac layer reads the facts, this decides.
/// A missing signal never becomes "eligible": an unknown one refuses when the recipe is irreplaceable and asks for a ticked box
/// otherwise (with three signals that refuse in both cases: internal or external, writable, free space).
public enum Eligibility {
    public static func evaluate(volume v: DriveFacts, recipe: Recipe?, source: SourceNeeds?, policy: Policy) -> EligibilityReport {
        let irreplaceable = recipe?.riskClass == .irreplaceable
        let unknownOutcome: EligibilityOutcome = irreplaceable ? .refuse : .ack
        let label = driveLabel(v)
        var out: [EligibilityVerdict] = []
        func add(_ rule: EligibilityRule, _ outcome: EligibilityOutcome, _ message: String, unknown: String? = nil) {
            out.append(EligibilityVerdict(rule: rule, outcome: outcome, message: message, unknownSignal: unknown))
        }

        // E1 local disk only
        if !v.isLocal || v.fileSystem == .network {
            add(.e1, .refuse, "This is a network location. Outboard only uses drives plugged into this Mac.")
        }
        // E2 not a disk image
        if v.bus == .diskImage && !policy.allowsDiskImages {
            add(.e2, .refuse, "This is a disk image, not a drive.")
        }
        // E3 external (the test is "not internal", never Removable or Ejectable)
        switch v.isInternal {
        case .yes: add(.e3, .refuse, "This volume is part of your Mac's own storage.")
        case .unknown: add(.e3, .refuse, "We couldn't tell whether this volume is external.", unknown: "internal or external")
        case .no: break
        }
        // E4 format
        switch v.fileSystem {
        case .apfs, .network: break
        case .hfsPlus:
            if recipe?.drive.allowsHFS ?? true {
                add(.e4, .warn, "This drive uses the older Mac OS Extended format. APFS is a better fit.")
            } else {
                add(.e4, .refuse, "This drive uses the older Mac OS Extended format. Outboard needs APFS for this move.")
            }
        case .exfat, .fat, .ntfs:
            add(.e4, .refuse, "This drive is formatted as \(v.fileSystem.displayName). Apps need APFS or Mac OS Extended. Outboard can't change a drive's format.")
        case .other:
            let raw = v.fileSystemRaw.trimmingCharacters(in: .whitespaces)
            add(.e4, .refuse, "This drive is formatted as \(raw.isEmpty ? "a format Outboard doesn't know" : raw). Apps need APFS or Mac OS Extended. Outboard can't change a drive's format.")
        }
        // E5 solid state, and a known slow link
        let needsSSD = recipe?.drive.requiresSolidState ?? true
        switch v.isSolidState {
        case .no:
            if needsSSD {
                add(.e5, .refuse, "This looks like a spinning hard disk. It's too slow for app data. Outboard will only use SSDs.")
            } else {
                add(.e5, .warn, "This looks like a spinning hard disk. Libraries work on one, but it may be slow.")
            }
        case .unknown:
            if needsSSD {
                if irreplaceable {
                    add(.e5, .refuse, "We couldn't tell whether this is a solid-state drive.", unknown: "solid state")
                } else {
                    add(.e5, .ack, "We couldn't tell whether this is a solid-state drive. Tick to confirm it is.", unknown: "solid state")
                }
            }
        case .yes: break
        }
        if let mbps = v.linkMegabitsPerSecond, mbps <= 480, v.isSolidState != .no {
            if needsSSD {
                add(.e5, .refuse, "This drive is connected at USB 2 speed. Outboard needs a newer connection (USB 3 or Thunderbolt).")
            } else {
                add(.e5, .warn, "This drive is connected at USB 2 speed. It may be slow.")
            }
        }
        // E6 writable
        if v.isLocked {
            add(.e6, .refuse, "This drive is locked. Unlock it in Disk Utility, then try again.")
        } else {
            switch v.isWritable {
            case .no: add(.e6, .refuse, "This drive is read-only.")
            case .unknown: add(.e6, .refuse, "We couldn't tell whether this drive is writable.", unknown: "writable")
            case .yes: break
            }
        }
        // E7 Time Machine: any of the three signals refuses
        if v.timeMachine.anyYes {
            add(.e7, .refuse, "This is a Time Machine disk. Use a different drive.")
        } else if v.timeMachine.allUnknown {
            if irreplaceable {
                add(.e7, .refuse, "We couldn't tell whether this is your Time Machine disk.", unknown: "Time Machine status")
            } else {
                add(.e7, .ack, "We couldn't tell whether this is your Time Machine disk. Tick to confirm it isn't.", unknown: "Time Machine status")
            }
        }
        if v.timeMachineSiblingInContainer && !v.timeMachine.anyYes {
            add(.e7, .info, "A volume on this drive's container is used by Time Machine.")
        }
        // E8 identity
        if v.uuid == nil || v.uuid?.isEmpty == true {
            add(.e8, .refuse, "This drive has no volume ID, so Outboard couldn't recognise it again.", unknown: "volume ID")
        } else if v.sameNameCount > 1 {
            add(.e8, .refuse, "Two drives have the same name. Rename one in Finder, then try again.")
        } else if !v.isStandardMount {
            add(.e8, .refuse, "This drive's folder under /Volumes doesn't match its name. Eject it and plug it in again.")
        }
        // E9 ownership
        switch v.ownershipHonoured {
        case .no:
            add(.e9, .refuse, "This drive is set to ignore ownership, so file permissions can't be kept. In Finder, Get Info on the drive and turn off 'Ignore ownership on this volume'.")
        case .unknown:
            if irreplaceable {
                add(.e9, .refuse, "We couldn't tell whether this drive keeps file ownership.", unknown: "ownership")
            } else {
                add(.e9, .ack, "We couldn't tell whether this drive keeps file ownership. Tick to confirm it does.", unknown: "ownership")
            }
        case .yes: break
        }
        // E10 case sensitivity (needs the source)
        if let source, v.isCaseSensitive != .yes, source.isCaseSensitive != .no {
            if source.isCaseSensitive == .yes && v.isCaseSensitive == .no {
                add(.e10, .refuse, "This drive isn't case-sensitive but the data is. Two files could collide.")
            } else {
                add(.e10, unknownOutcome, irreplaceable
                    ? "We couldn't tell whether this drive treats upper and lower case the same as the data does."
                    : "We couldn't tell whether this drive treats upper and lower case the same. Tick to confirm it matches your Mac.",
                    unknown: "case sensitivity")
            }
        }
        // E11 links
        let needsSymlinks = source?.hasSymlinks ?? (recipe?.method.kind == .symlink)
        let needsHardLinks = source?.hasHardLinks ?? false
        let linkSignals = (needsSymlinks ? [v.supportsSymlinks] : []) + (needsHardLinks ? [v.supportsHardLinks] : [])
        if linkSignals.contains(.no) {
            add(.e11, .refuse, "This drive can't hold the links this data needs.")
        } else if linkSignals.contains(.unknown) {
            add(.e11, unknownOutcome, irreplaceable
                ? "We couldn't tell whether this drive can hold links."
                : "We couldn't tell whether this drive can hold links. Tick to confirm it can.", unknown: "link support")
        }
        // E12 free space (needs the source)
        if let source {
            let need = requiredFree(forBytes: source.logicalBytes, capacity: v.capacityBytes)
            if let available = effectiveAvailable(v) {
                if available < need {
                    add(.e12, .refuse, "Needs \(Format.bytes(need)) free on \(label); it has \(Format.bytes(available)).")
                }
            } else {
                add(.e12, .refuse, "We couldn't tell how much space is free on \(label).", unknown: "free space")
            }
        }
        // E13 not synced
        if v.isSyncedLocation || NeverList.isSyncedPath(v.mountPoint) {
            add(.e13, .refuse, "This location is synced by a cloud service.")
        }
        // E14 mounted under /Volumes
        if !RuleContext.isStandardMount(v.mountPoint) {
            add(.e14, .refuse, "This drive is mounted in an unusual place.")
        }
        // E15 health
        switch v.smart {
        case .failing: add(.e15, .refuse, "macOS reports this drive as failing.")
        case .notSupported: add(.e15, .info, "macOS doesn't report this drive's health over this connection.")
        case .unknown: add(.e15, .info, "We couldn't read this drive's health status.", unknown: "drive health")
        case .verified: break
        }
        // E16 encryption, for sensitive data
        if recipe?.sensitive == true {
            switch v.isEncrypted {
            case .no: add(.e16, .ack, "This drive isn't encrypted. Anyone who finds it can read the backups on it.")
            case .unknown: add(.e16, .ack, "We couldn't tell whether this drive is encrypted. Tick to confirm you accept that.", unknown: "encryption")
            case .yes: break
            }
        }
        // E17 our marker
        if v.hasOutboardMarker {
            add(.e17, .info, "Your Outboard drive.")
        }
        // E19 sleep and hubs: once, with the general verdict
        if recipe == nil {
            add(.e19, .info, "Sleep can disconnect drives, hubs more often. If you can, plug the drive straight in. Outboard doesn't change your power settings.")
        }

        let order = EligibilityRule.allCases
        let severity: [EligibilityOutcome: Int] = [.refuse: 0, .ack: 1, .warn: 2, .info: 3]
        let sorted = out.enumerated().sorted { a, b in
            let ra = order.firstIndex(of: a.element.rule) ?? 0, rb = order.firstIndex(of: b.element.rule) ?? 0
            if ra != rb { return ra < rb }
            let sa = severity[a.element.outcome] ?? 9, sb = severity[b.element.outcome] ?? 9
            return sa != sb ? sa < sb : a.offset < b.offset
        }.map(\.element)
        return EligibilityReport(volumeID: v.id, recipeID: recipe?.id, verdicts: sorted)
    }

    /// E18: nil means fresh (same UUID, same mount point, still present).
    public static func freshness(plannedUUID: String, plannedMountPoint: String, now: DriveFacts?) -> EligibilityVerdict? {
        let changed = EligibilityVerdict(rule: .e18, outcome: .refuse, message: "The drive changed while we were getting ready. Nothing was changed.")
        guard let now, let uuid = now.uuid else { return changed }
        guard uuid.uppercased() == plannedUUID.uppercased(), PathNorm.normalize(now.mountPoint) == PathNorm.normalize(plannedMountPoint) else { return changed }
        return nil
    }

    /// "USB · APFS · encrypted: unknown · Time Machine: no · 38 GB free": plain labels, no claims.
    public static func summary(_ v: DriveFacts) -> String {
        let free = v.availableBytes.map { Format.bytes($0) + " free" } ?? "free space unknown"
        return [
            v.bus.displayName,
            v.fileSystem.displayName,
            "encrypted: \(v.isEncrypted.rawValue)",
            "Time Machine: \(v.timeMachine.verdict.rawValue)",
            free,
        ].joined(separator: " \u{00B7} ")
    }

    // MARK: - Space arithmetic (E12), shared with the planner

    /// The free space E12 asks for: at least 1.1 times the logical bytes, and at least max(10 GB, 5% of capacity) left afterwards.
    public static func requiredFree(forBytes logical: UInt64, capacity: UInt64) -> UInt64 {
        let withMargin = (logical &* Limits.freeSpaceNumerator &+ Limits.freeSpaceDenominator &- 1) / Limits.freeSpaceDenominator
        let keep = max(Limits.minFreeAfterBytes, capacity / 100 &* Limits.minFreeAfterPercent)
        return max(withMargin, logical &+ keep)
    }

    /// The space the drive can offer: `availableBytes`, capped by an APFS quota when there is one (VERIFY it honours a quota).
    public static func effectiveAvailable(_ v: DriveFacts) -> UInt64? {
        guard let available = v.availableBytes else { return nil }
        if let quota = v.quotaBytes { return min(available, quota) }
        return available
    }

    /// "Outboard drive" for a volume named Outboard (the recommended name), otherwise the volume's own name.
    public static func driveLabel(_ v: DriveFacts) -> String {
        v.name.lowercased() == "outboard" ? "Outboard drive" : v.name
    }
}
