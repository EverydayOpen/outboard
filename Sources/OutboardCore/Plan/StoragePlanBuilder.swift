import Foundation

/// Builds the ranked plan the Plan screen lists and the card summarises (BUILD_PLAN §4.4). One status per catalogue entry; the
/// headline counts only what this build would actually offer to move (`PlanItem.offeredBytes`). Every count the UI shows comes from this.
public enum StoragePlanBuilder {
    public static func build(recipes: [Recipe], scans: [SizeScan], prefs: Preferences, policy: Policy, macOS: MinOS, now: Date) -> StoragePlan {
        var items: [(item: PlanItem, index: Int)] = []
        for (index, recipe) in recipes.enumerated() {
            items.append((item(for: recipe, scans: scans.filter { $0.recipeID == recipe.id }, prefs: prefs, policy: policy, macOS: macOS), index))
        }
        func group(_ s: PlanStatus) -> Int {
            switch s {
            case .movable: return 0
            case .guided: return 1
            case .notMeasured: return 2
            case .neverMove: return 4
            case .hiddenUntilVerified, .alreadyMoved, .absent, .belowThreshold, .needsNewerMacOS: return 3
            }
        }
        let sorted = items.sorted { a, b in
            let ga = group(a.item.status), gb = group(b.item.status)
            if ga != gb { return ga < gb }
            if ga <= 1 && a.item.allocatedBytes != b.item.allocatedBytes { return a.item.allocatedBytes > b.item.allocatedBytes }
            return a.index < b.index
        }
        return StoragePlan(items: sorted.map(\.item), measuredAt: now)
    }

    private static func item(for recipe: Recipe, scans: [SizeScan], prefs: Preferences, policy: Policy, macOS: MinOS) -> PlanItem {
        let unverified = Catalogue.isUnverified(recipe, policy: policy)
        var reason: NotMeasuredReason?
        var neverReason: String?
        let status: PlanStatus
        let present = scans.filter { $0.state != .absent }

        switch Catalogue.visibility(of: recipe, prefs: prefs, policy: policy, macOS: macOS) {
        case .never:
            status = .neverMove
            if case .never(let text) = recipe.method { neverReason = text }
        case .needsNewerMacOS:
            status = .needsNewerMacOS
        case .guided:
            if recipe.source != nil && present.isEmpty && !scans.isEmpty { status = .absent }
            else { status = .guided }
        case .hiddenUntilVerified:
            status = .hiddenUntilVerified
        case .offered:
            if scans.isEmpty || present.isEmpty {
                status = .absent
            } else if let primary = scans.first(where: { $0.path == recipe.source }), primary.isLink || primary.reason == .alreadyRedirected {
                status = .alreadyMoved
            } else if let bad = present.first(where: { $0.state == .notMeasured }) {
                status = .notMeasured
                reason = bad.reason
            } else {
                let bytes = present.reduce(UInt64(0)) { $0 &+ $1.allocatedBytes }
                if present.contains(where: { $0.state == .atLeast }) {
                    status = .notMeasured   // a floor is not a measurement: the plan, the card and the headline all filter this one status
                } else {
                    status = bytes >= Limits.minOfferBytes ? .movable : .belowThreshold
                }
            }
        }
        return PlanItem(recipeID: recipe.id, name: recipe.name, kind: recipe.kind, risk: recipe.riskClass, status: status, scans: scans,
                        notMeasuredReason: reason, neverReason: neverReason, missingDriveEffect: recipe.missingDriveEffect, isUnverified: unverified)
    }
}

extension SizeScan {
    /// One scan standing for a recipe's folders together (the consent sheet shows the sum): byte and file counts added, measured only
    /// if every part is. nil for an empty list.
    public static func merged(_ scans: [SizeScan]) -> SizeScan? {
        guard let first = scans.first else { return nil }
        var out = first
        var fp = TreeFingerprint()
        for s in scans {
            fp.files += s.fingerprint.files
            fp.directories += s.fingerprint.directories
            fp.symlinks += s.fingerprint.symlinks
            fp.logicalBytes += s.fingerprint.logicalBytes
            fp.allocatedBytes += s.fingerprint.allocatedBytes
            fp.hardLinkedFiles += s.fingerprint.hardLinkedFiles
            fp.specialFiles += s.fingerprint.specialFiles
            fp.datalessFiles += s.fingerprint.datalessFiles
            fp.sparseFiles += s.fingerprint.sparseFiles
            if s.state != .measured && s.state != .absent { out.state = s.state }
            out.isLink = out.isLink || s.isLink
        }
        out.fingerprint = fp
        out.measuredAt = scans.map(\.measuredAt).max() ?? first.measuredAt
        return out
    }

    /// What E10 to E12 need to know about this folder. `caseSensitive` comes from the Mac layer (the source volume).
    public func sourceNeeds(caseSensitive: Tri) -> SourceNeeds {
        SourceNeeds(logicalBytes: fingerprint.logicalBytes, isCaseSensitive: caseSensitive, hasHardLinks: fingerprint.hardLinkedFiles > 0,
                    hasSymlinks: fingerprint.symlinks > 0)
    }
}
