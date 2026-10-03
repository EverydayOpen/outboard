import Foundation

/// Why a path is never moved, renamed, linked or copied into. `recipeID` is the never card that explains it (`never-containers` ...);
/// a path that matches no card (a system folder, a path with `..`) carries a plain id that is not in the catalogue.
public struct NeverReason: Codable, Hashable, Sendable {
    public var recipeID: String
    public var text: String

    public init(recipeID: String, text: String) {
        self.recipeID = recipeID
        self.text = text
    }
}

/// The text of the nine never cards, in one place: the catalogue's `.never(reason:)` and `NeverList` say the same sentence.
enum NeverTexts {
    static let containers = "macOS stops sandboxed apps from starting when their data folder is replaced by a link, as Docker for Mac issue 771 reports."
    static let appleData = "Apple apps expect these on your Mac, and macOS protects them. Outboard doesn't touch them."
    static let homebrew = "Homebrew's prebuilt packages only work in its default location on your Mac's own disk (Homebrew docs)."
    static let cachesAndHome = "Hundreds of apps write to the Caches folder the moment they start, so moving all of it makes apps misbehave when the drive is away. Individual app caches are offered where Outboard knows how. Your home folder isn't offered either: Apple supports moving it, and with FileVault it can stop you logging in."
    static let icloud = "These files are managed by iCloud. Moving them can interfere with syncing."
    static let appBundles = "Moving an app can break its updates and permissions. Outboard moves data, not apps."
    static let simulators = "Xcode manages simulator runtimes as disk images. Moving them can leave simulators unable to load. To free space, remove the runtimes you don't need in Xcode, Settings, Components."
    static let dockerOrbstack = "Docker Desktop and OrbStack have their own storage setting, and Docker's has been unreliable on external drives for years. Outboard doesn't move their data."
    static let pnpmUv = "These stores work by linking files from your projects. On another drive the files are copied instead, so space on your Mac can go up, not down."
    static let system = "macOS itself uses this folder."
    static let traversal = "This path contains '..' or a relative part, so Outboard can't tell where it leads."
}

/// The paths Outboard never touches (BUILD_PLAN §2, §4.4). Pure and lexical: it compares path text, case-insensitively (a Mac volume
/// is case-insensitive by default, so `~/library/containers` is the same folder); the Mac layer resolves links before asking.
public enum NeverList {
    private static let containerRoots = ["Library/Containers", "Library/Group Containers"]
    private static let appleDataRoots = ["Library/Mail", "Library/Safari", "Library/Messages"]
    private static let simulatorRoots = ["Library/Developer/CoreSimulator"]
    private static let dockerRoots = [".docker", ".orbstack"]
    private static let pnpmUvRoots = ["Library/pnpm", ".local/share/pnpm", ".cache/uv"]
    /// Desktop and Documents are synced by iCloud when the user turns that on, and are the user's own files either way.
    private static let personalRoots = ["Desktop", "Documents"]
    /// Folders whose whole content is never offered, but whose children may be (Caches: per-app cache recipes are fine).
    private static let exactOnly = ["Library", "Library/Application Support", "Library/Caches"]
    private static let homebrewRoots = ["/opt/homebrew", "/usr/local"]
    private static let systemRoots = ["/System", "/Library", "/usr", "/bin", "/sbin", "/private", "/etc", "/var", "/opt", "/cores", "/dev"]
    private static let exactAbsolute = ["/", "/Users", "/Volumes", "/Applications"]

    /// Why this absolute path must not be a source, a destination or a staging folder; nil when nothing in the list matches.
    public static func reason(forPath path: String, home: String) -> NeverReason? {
        let p = PathNorm.normalize(path)
        guard p.hasPrefix("/") else { return NeverReason(recipeID: "never-path", text: NeverTexts.traversal) }
        if PathNorm.hasDotComponent(p) { return NeverReason(recipeID: "never-path", text: NeverTexts.traversal) }
        if PathNorm.components(p).contains(where: { $0.lowercased().hasSuffix(".app") }) {
            return NeverReason(recipeID: "never-app-bundles", text: NeverTexts.appBundles)
        }
        if isSyncedPath(p) { return NeverReason(recipeID: "never-icloud", text: NeverTexts.icloud) }

        let h = PathNorm.normalize(home)
        if !h.isEmpty && h != "/" {
            if p.lowercased() == h.lowercased() { return NeverReason(recipeID: "never-caches-home", text: NeverTexts.cachesAndHome) }
            if PathNorm.isUnder(p, h, caseInsensitive: true) {
                for root in personalRoots where PathNorm.isUnder(p, h + "/" + root, caseInsensitive: true) {
                    return NeverReason(recipeID: "never-icloud", text: NeverTexts.icloud)
                }
                for root in containerRoots where PathNorm.isUnder(p, h + "/" + root, caseInsensitive: true) {
                    return NeverReason(recipeID: "never-containers", text: NeverTexts.containers)
                }
                for root in appleDataRoots where PathNorm.isUnder(p, h + "/" + root, caseInsensitive: true) {
                    return NeverReason(recipeID: "never-apple-data", text: NeverTexts.appleData)
                }
                for root in simulatorRoots where PathNorm.isUnder(p, h + "/" + root, caseInsensitive: true) {
                    return NeverReason(recipeID: "never-simulator-runtimes", text: NeverTexts.simulators)
                }
                for root in dockerRoots where PathNorm.isUnder(p, h + "/" + root, caseInsensitive: true) {
                    return NeverReason(recipeID: "never-docker-orbstack", text: NeverTexts.dockerOrbstack)
                }
                for root in pnpmUvRoots where PathNorm.isUnder(p, h + "/" + root, caseInsensitive: true) {
                    return NeverReason(recipeID: "never-pnpm-uv", text: NeverTexts.pnpmUv)
                }
                for root in exactOnly where p.lowercased() == (h + "/" + root).lowercased() {
                    return NeverReason(recipeID: "never-caches-home", text: NeverTexts.cachesAndHome)
                }
            }
        }
        for root in homebrewRoots where PathNorm.isUnder(p, root, caseInsensitive: true) {
            return NeverReason(recipeID: "never-homebrew", text: NeverTexts.homebrew)
        }
        for root in systemRoots where PathNorm.isUnder(p, root, caseInsensitive: true) {
            return NeverReason(recipeID: "never-system", text: NeverTexts.system)
        }
        if PathNorm.isUnder(p, "/Applications", caseInsensitive: true) {
            return NeverReason(recipeID: "never-app-bundles", text: NeverTexts.appBundles)
        }
        for exact in exactAbsolute where p.lowercased() == exact.lowercased() {
            return NeverReason(recipeID: "never-system", text: NeverTexts.system)
        }
        return nil
    }

    /// The only place the cloud-sync names appear (grep G11). A component named like an iCloud, File Provider or third-party sync
    /// folder anywhere in the path makes the whole path synced.
    public static func isSyncedPath(_ path: String) -> Bool {
        for component in PathNorm.components(path) {
            let c = component.lowercased()
            if c == "mobile documents" || c == "cloudstorage" || c == "clouddocs" || c == "fileprovider" { return true }
            if c.hasPrefix("icloud~") || c.hasPrefix("com~apple~clouddocs") { return true }
            if c == "dropbox" || c.hasPrefix("onedrive") || c == "google drive" || c == "googledrive" { return true }
            if c == "box sync" || c == "pcloud drive" || c == "mega" { return true }
        }
        return false
    }

    /// Outboard's own folder under Application Support (the journal, the manifests, `Parked/`).
    public static func isOutboardOwn(_ path: String, home: String) -> Bool {
        let root = PathNorm.normalize(home) + "/Library/Application Support/" + Names.supportFolder
        return PathNorm.isUnder(path, root, caseInsensitive: true)
    }
}
