import Foundation

// The nine never cards (APP6 §4.2): visible on the Plan screen with their reasons. Outboard offers nothing for them and the
// never-list (`NeverList`) refuses every plan that touches them. The reason text is shared with `NeverList`.

enum NeverRecipes {
    static let containers = Recipe(id: "never-containers", version: 1, name: "Sandboxed app data",
        source: nil, method: .never(reason: NeverTexts.containers),
        riskClass: .irreplaceable, onDriveMissing: .none, confidence: .high, beta: .b0,
        missingDriveEffect: "",
        sources: ["https://github.com/docker/for-mac/issues/771"],
        verify: ["Whether a link below a container's Data folder is tolerated"])

    static let appleData = Recipe(id: "never-apple-data", version: 1, name: "Mail, Safari, Messages and Notes",
        source: nil, method: .never(reason: NeverTexts.appleData),
        riskClass: .irreplaceable, onDriveMissing: .none, confidence: .high, beta: .b0,
        missingDriveEffect: "",
        sources: ["https://imlzq.com/apple/macos/2024/08/24/Unveiling-Mac-Security-A-Comprehensive-Exploration-of-TCC-Sandboxing-and-App-Data-TCC.html"])

    static let homebrew = Recipe(id: "never-homebrew", version: 1, name: "Homebrew",
        source: nil, method: .never(reason: NeverTexts.homebrew),
        riskClass: .expensive, onDriveMissing: .none, confidence: .high, beta: .b0,
        missingDriveEffect: "",
        sources: ["https://docs.brew.sh/Support-Tiers"])

    static let cachesAndHome = Recipe(id: "never-caches-home", version: 1, name: "The Caches folder and your home folder",
        source: nil, method: .never(reason: NeverTexts.cachesAndHome),
        riskClass: .irreplaceable, onDriveMissing: .none, confidence: .high, beta: .b0,
        missingDriveEffect: "",
        sources: [
            "https://appleinsider.com/inside/macos-ventura/tips/how-to-move-your-home-directory-in-macos-ventura",
            "https://osxdaily.com/2010/02/16/move-your-home-directory-to-another-location/",
        ])

    static let icloud = Recipe(id: "never-icloud", version: 1, name: "Anything in iCloud Drive",
        source: nil, method: .never(reason: NeverTexts.icloud),
        riskClass: .irreplaceable, onDriveMissing: .none, confidence: .high, beta: .b0,
        missingDriveEffect: "",
        sources: ["https://github.com/EverydayOpen/whydunit"],
        verify: ["Add an Apple support page that describes how iCloud Drive manages its folders"])

    static let appBundles = Recipe(id: "never-app-bundles", version: 1, name: "Apps themselves",
        source: nil, method: .never(reason: NeverTexts.appBundles),
        riskClass: .expensive, onDriveMissing: .none, confidence: .high, beta: .b0,
        missingDriveEffect: "",
        sources: ["https://github.com/bevry-vibes/mac-move-apps"])

    static let simulators = Recipe(id: "never-simulator-runtimes", version: 1, name: "Xcode simulator runtimes",
        source: nil, method: .never(reason: NeverTexts.simulators),
        riskClass: .expensive, onDriveMissing: .none, confidence: .medium, beta: .b0,
        missingDriveEffect: "",
        sources: ["https://developer.apple.com/tutorials/data/documentation/xcode/downloading-and-installing-additional-xcode-components.md"])

    static let dockerOrbstack = Recipe(id: "never-docker-orbstack", version: 1, name: "Docker Desktop and OrbStack",
        source: nil, method: .never(reason: NeverTexts.dockerOrbstack),
        riskClass: .expensive, onDriveMissing: .none, confidence: .high, beta: .b0,
        missingDriveEffect: "",
        sources: [
            "https://docs.docker.com/desktop/settings-and-maintenance/settings/",
            "https://github.com/docker/for-mac/issues/6797",
        ])

    static let pnpmUv = Recipe(id: "never-pnpm-uv", version: 1, name: "pnpm and uv stores",
        source: nil, method: .never(reason: NeverTexts.pnpmUv),
        riskClass: .regenerable, onDriveMissing: .none, confidence: .high, beta: .b0,
        missingDriveEffect: "",
        sources: ["https://pnpm.io/settings/node-modules", "https://docs.astral.sh/uv/concepts/cache/"])
}
