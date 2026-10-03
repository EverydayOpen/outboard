// swift-tools-version:6.0
import PackageDescription

// OutboardCore is Foundation-only (builds and tests on Linux and Windows-Docker too).
// OutboardMac holds AppKit/Darwin/CryptoKit/ServiceManagement, so it only exists on macOS. OutboardFixture is the tiny sleeping
// executable the Mac tests copy into a fake .app bundle and run, to prove the running-app guard. OutboardCrashHelper runs one
// move and `_exit(9)`s at a chosen journal record (DEBUG-only Faults hooks), so the tests can check recovery on real files.
var products: [Product] = [.library(name: "OutboardCore", targets: ["OutboardCore"])]
var targets: [Target] = [
    .target(name: "OutboardCore"),
    // Fixtures are read from disk via #filePath, not bundled (keeps Linux builds warning-free).
    .testTarget(name: "OutboardCoreTests", dependencies: ["OutboardCore"], exclude: ["Fixtures"]),
]

#if os(macOS)
products.append(.library(name: "OutboardMac", targets: ["OutboardMac"]))
targets += [
    .target(name: "OutboardMac", dependencies: ["OutboardCore"]),
    .executableTarget(name: "OutboardFixture"),
    .executableTarget(name: "OutboardCrashHelper", dependencies: ["OutboardMac", "OutboardCore"], path: "Tests/OutboardCrashHelper"),
    .testTarget(name: "OutboardMacTests", dependencies: ["OutboardMac", "OutboardCore"]),
]
#endif

let package = Package(
    name: "Outboard",
    // macOS 13: ImageRenderer, NavigationSplitView, MenuBarExtra and SMAppService need it (BUILD_PLAN §1).
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets,
    // ponytail: Swift 5 mode keeps strict-concurrency diagnostics as warnings while the Mac code is unverified
    // on real hardware; move to .v6 once CI is green and warnings are cleaned up.
    swiftLanguageModes: [.v5]
)
