import Foundation

// The four pure approvers. Each takes a closed shape and a `RuleContext` and answers allowed or refused with a plain reason. They
// check the *shape* of a path pair (text only); facts that need the disk (the destination does not exist, no parent is a link, the
// stamp is unchanged) are checked by the Mac verb right before it acts, in the pinned order of BUILD_PLAN §3.4.

enum RuleCommon {
    /// Absolute, normalised, no "." or ".." component. nil when fine.
    static func shape(_ paths: String...) -> String? {
        for p in paths {
            let n = PathNorm.normalize(p)
            if n.isEmpty { return "A path is empty (the drive may be away)." }
            if !n.hasPrefix("/") { return "A path is not absolute." }
            if PathNorm.hasDotComponent(n) { return "A path contains '..' or '.'." }
        }
        return nil
    }

    /// `<recipeFolder>` is `<mount>/Outboard/<recipe-id>` on a standard mount.
    static func recipeFolderIsValid(_ ctx: RuleContext) -> Bool {
        guard RuleContext.isStandardMount(ctx.mountPoint) else { return false }
        let c = PathNorm.components(ctx.recipeFolder)
        guard c.count == 4, c[0] == "Volumes", c[2] == Names.driveFolder, !c[3].isEmpty else { return false }
        return "/Volumes/" + c[1] == PathNorm.normalize(ctx.mountPoint)
    }

    static func macSideProblem(_ path: String, ctx: RuleContext) -> String? {
        if !PathNorm.isStrictlyUnder(path, ctx.home) { return "The folder is not inside your home folder." }
        if let never = NeverList.reason(forPath: path, home: ctx.home) { return never.text }
        if NeverList.isOutboardOwn(path, home: ctx.home) { return "That is Outboard's own folder." }
        return nil
    }

    static func ends(_ path: String, withInfixOf base: String, _ infix: String) -> Bool {
        guard path.hasPrefix(base + infix) else { return false }
        return !path.dropFirst((base + infix).count).contains("/")
    }

    /// `<infix>` + optional `-<digits>` (a numbered suffix when the first name is taken).
    static func numberedSuffix(_ rest: Substring) -> Bool {
        if rest.isEmpty { return true }
        guard rest.first == "-" else { return false }
        let digits = rest.dropFirst()
        return !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// `YYYY-MM-DD` followed by an optional numbered suffix.
    static func datedSuffix(_ rest: Substring) -> Bool {
        let u = Array(rest.utf8)
        guard u.count >= 10 else { return false }
        func digit(_ i: Int) -> Bool { u[i] >= 48 && u[i] <= 57 }
        guard (0..<4).allSatisfy(digit), u[4] == 45, digit(5), digit(6), u[7] == 45, digit(8), digit(9) else { return false }
        return numberedSuffix(Substring(String(decoding: u[10...], as: UTF8.self)))
    }
}

public enum RenameRules {
    /// `<parkedFolder><slot>` with an optional `-<digits>`.
    private static func numberedSlot(_ path: String, _ slot: String, _ ctx: RuleContext) -> Bool {
        let base = ctx.parkedFolder + slot
        return RuleCommon.ends(path, withInfixOf: ctx.parkedFolder, slot) && RuleCommon.numberedSuffix(Substring(path.dropFirst(base.count)))
    }

    public static func check(_ op: RenameOp, from: String, to: String, ctx: RuleContext) -> RuleVerdict {
        if let problem = RuleCommon.shape(from, to, ctx.macPath, ctx.home) { return .refused(problem) }
        let f = PathNorm.normalize(from)
        let t = PathNorm.normalize(to)
        if f == t { return .refused("The two paths are the same.") }
        if let problem = RuleCommon.macSideProblem(ctx.macPath, ctx: ctx) { return .refused(problem) }
        if NeverList.isSyncedPath(f) || NeverList.isSyncedPath(t) { return .refused("This location is synced by a cloud service.") }

        switch op {
        case .setAside:
            guard ctx.direction == .toDrive else { return .refused("A return does not set the original aside.") }
            guard f == ctx.macPath, t == ctx.beforeMovePath, PathNorm.parent(f) == PathNorm.parent(t) else {
                return .refused("The original may only be renamed to its own name plus \(Names.beforeMoveSuffix), in the same folder.")
            }
        case .undoSetAside:
            guard f == ctx.beforeMovePath, t == ctx.macPath, PathNorm.parent(f) == PathNorm.parent(t) else {
                return .refused("Only \(Names.beforeMoveSuffix) may be renamed back to the original name, in the same folder.")
            }
        case .publish:
            if ctx.direction == .toDrive {
                guard RuleCommon.recipeFolderIsValid(ctx) else { return .refused("The drive's Outboard folder is not where it should be.") }
                guard f == ctx.stagingPath, t == ctx.finalPath, PathNorm.parent(f) == ctx.recipeFolder, PathNorm.parent(t) == ctx.recipeFolder else {
                    return .refused("A copy may only be published from its staging folder to its final name, inside its recipe folder.")
                }
            } else {
                guard f == ctx.returningPath, t == ctx.macPath, PathNorm.parent(f) == PathNorm.parent(t) else {
                    return .refused("A returned copy may only be renamed from its \(Names.returningInfix) name to the original name.")
                }
            }
        case .park:
            // `link`, or `link-2`, `link-3` ... when an earlier park or retarget left one there (that one is evidence and stays).
            guard f == ctx.macPath, numberedSlot(t, "/link", ctx) else {
                return .refused("Only the link at the original path may be moved aside, and only into Parked/<id>/link.")
            }
        case .unpark:
            let note = f == ctx.macPath && numberedSlot(t, "/note", ctx)
            let link = numberedSlot(f, "/link", ctx) && t == ctx.macPath
            guard note || link else { return .refused("Only the note at the original path, or the parked link, may be moved on unpark.") }
        case .setAsideForeign:
            guard f == ctx.macPath, PathNorm.parent(f) == PathNorm.parent(t) else {
                return .refused("Only the item at the original path may be set aside, in the same folder.")
            }
            let rest = t.dropFirst(ctx.macPath.count)
            let allowed: Bool
            if t.hasPrefix(ctx.macPath + Names.createdWhileMovingSuffix) {
                allowed = RuleCommon.numberedSuffix(rest.dropFirst(Names.createdWhileMovingSuffix.count))
            } else if t.hasPrefix(ctx.macPath + Names.createdWhileRollingBackSuffix) {
                allowed = RuleCommon.numberedSuffix(rest.dropFirst(Names.createdWhileRollingBackSuffix.count))
            } else if t.hasPrefix(ctx.macPath + Names.whileAwayInfix) {
                allowed = RuleCommon.datedSuffix(rest.dropFirst(Names.whileAwayInfix.count))
            } else {
                allowed = false
            }
            guard allowed else { return .refused("A foreign item may only be renamed to \(Names.createdWhileMovingSuffix), \(Names.createdWhileRollingBackSuffix) or \(Names.whileAwayInfix)<date>.") }
        }
        return .allowed
    }
}

public enum CopyRules {
    public static func check(source: String, destination: String, ctx: RuleContext) -> RuleVerdict {
        if let problem = RuleCommon.shape(source, destination, ctx.macPath, ctx.home) { return .refused(problem) }
        let s = PathNorm.normalize(source)
        let d = PathNorm.normalize(destination)
        if NeverList.isSyncedPath(s) || NeverList.isSyncedPath(d) { return .refused("This location is synced by a cloud service.") }
        if PathNorm.isUnder(d, s, caseInsensitive: true) || PathNorm.isUnder(s, d, caseInsensitive: true) {
            return .refused("The copy would be inside its own source.")
        }
        if let problem = RuleCommon.macSideProblem(ctx.macPath, ctx: ctx) { return .refused(problem) }
        switch ctx.direction {
        case .toDrive:
            guard s == ctx.sourcePath, s == ctx.macPath else { return .refused("Only the folder in the plan may be copied.") }
            guard RuleCommon.recipeFolderIsValid(ctx) else { return .refused("The drive's Outboard folder is not where it should be.") }
            guard d == ctx.stagingPath, PathNorm.parent(d) == ctx.recipeFolder, PathNorm.leaf(d).hasPrefix(Names.stagingPrefix) else {
                return .refused("A copy may only go to a new staging folder inside its recipe folder.")
            }
        case .returnToMac:
            guard RuleContext.isStandardMount(ctx.mountPoint), s == ctx.sourcePath, s == ctx.finalPath else {
                return .refused("Only the copy on the recorded drive may be copied back.")
            }
            guard d == ctx.returningPath, PathNorm.parent(d) == PathNorm.parent(ctx.macPath) else {
                return .refused("A copy may only come back to a new \(Names.returningInfix) folder beside the original path.")
            }
        }
        return .allowed
    }
}

public enum LinkRules {
    public static func check(linkPath: String, target: String, ctx: RuleContext) -> RuleVerdict {
        if let problem = RuleCommon.shape(linkPath, target, ctx.macPath, ctx.home) { return .refused(problem) }
        let l = PathNorm.normalize(linkPath)
        let t = PathNorm.normalize(target)
        guard ctx.direction == .toDrive else { return .refused("A return does not create links.") }
        if let problem = RuleCommon.macSideProblem(ctx.macPath, ctx: ctx) { return .refused(problem) }
        guard l == ctx.macPath else { return .refused("A link may only be created at the original path.") }
        guard RuleContext.isStandardMount(ctx.mountPoint), t == ctx.finalPath, PathNorm.isStrictlyUnder(t, ctx.mountPoint) else {
            return .refused("A link may only point at the recorded drive's copy.")
        }
        if NeverList.isSyncedPath(t) { return .refused("This location is synced by a cloud service.") }
        return .allowed
    }
}

public enum TrashRules {
    public static func allows(path: String, ctx: RuleContext) -> RuleVerdict {
        if let problem = RuleCommon.shape(path, ctx.home) { return .refused(problem) }
        let p = PathNorm.normalize(path)
        if p == ctx.beforeMovePath {
            guard ctx.recordState == .confirmed else { return .refused("The original can only go to the Trash after you confirm the move.") }
            if let problem = RuleCommon.macSideProblem(ctx.macPath, ctx: ctx) { return .refused(problem) }
            return .allowed
        }
        if p == ctx.returningPath {
            // The half-copied folder of a return that stopped, beside the original path on the Mac.
            guard ctx.direction == .returnToMac, ctx.recordState == .aborted else {
                return .refused("A copy that is coming back to your Mac can only go to the Trash after that move has stopped.")
            }
            if let problem = RuleCommon.macSideProblem(ctx.macPath, ctx: ctx) { return .refused(problem) }
            return .allowed
        }
        guard ctx.knownLeftovers.map(PathNorm.normalize).contains(p) else {
            return .refused("Outboard only moves its own leftovers and the confirmed original to the Trash.")
        }
        guard RuleContext.isStandardMount(ctx.mountPoint), PathNorm.isStrictlyUnder(p, ctx.mountPoint + "/" + Names.driveFolder) else {
            return .refused("A leftover must be inside the drive's Outboard folder.")
        }
        if p == ctx.macPath || PathNorm.isUnder(p, ctx.macPath) || PathNorm.isUnder(ctx.macPath, p) {
            return .refused("The live folder is never moved to the Trash.")
        }
        return .allowed
    }
}
