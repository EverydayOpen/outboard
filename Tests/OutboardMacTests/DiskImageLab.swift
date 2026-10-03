import Foundation
import XCTest

/// Real volumes for the tests, from disk images. The only file in the repository that runs the disk image tool, and only ever as
/// an absolute path with an argument array (no shell). Hosted runners answer "Resource busy" now and then, so attach and detach
/// retry with a backoff; the workflows end with an `if: always()` detach step as a second net. Everything is opt-in: the tests that
/// use it run only when the environment says `OUTBOARD_DISK_TESTS=1` (CI sets it), and skip with the reason otherwise.
enum DiskImageLab {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["OUTBOARD_DISK_TESTS"] == "1" }

    private static let tool = "/usr/bin/hdiutil"

    struct Image {
        var file: String
        /// `/dev/diskN` of the whole image.
        var device: String
        var mountPoint: String
        var volumeName: String
    }

    struct Failure: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    struct Result {
        var status: Int32
        var stdout: Data
        var stderr: String
        var text: String { String(decoding: stdout, as: UTF8.self) + stderr }
    }

    static func run(_ arguments: [String]) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return Result(status: -1, stdout: Data(), stderr: "could not start: \(error)") }
        // Drain both pipes while the tool runs, so a large answer cannot fill a pipe and stall it.
        let outBox = Box()
        let errBox = Box()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { outBox.data = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { errBox.data = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        process.waitUntilExit()
        group.wait()
        return Result(status: process.terminationStatus, stdout: outBox.data, stderr: String(decoding: errBox.data, as: UTF8.self))
    }

    private final class Box: @unchecked Sendable {
        var data = Data()
    }

    private static func runWithRetries(_ arguments: [String], attempts: Int = 4) -> Result {
        var last = run(arguments)
        var delay = 1.0
        for _ in 1..<attempts where last.status != 0 && last.text.lowercased().contains("busy") {
            Thread.sleep(forTimeInterval: delay)
            delay *= 2
            last = run(arguments)
        }
        return last
    }

    /// A sparse image with one volume of the given format; returns the file. A sparse image takes disk space only as it fills, so the
    /// default capacity is large: Core's free-space rule (E12) wants at least 10 GB left after a move. Skips when this runner cannot make one.
    static func create(in directory: String, name: String, volumeName: String, megabytes: Int = 14_000, fileSystem: String = "APFS") throws -> String {
        let base = directory + "/" + name
        let result = runWithRetries(["create", "-size", "\(megabytes)m", "-type", "SPARSE", "-fs", fileSystem, "-volname", volumeName, base])
        guard result.status == 0 else { throw XCTSkip("this runner could not create a \(fileSystem) disk image: \(result.text)") }
        return base + ".sparseimage"
    }

    static func attach(_ file: String, readOnly: Bool = false, ownersOff: Bool = false) throws -> Image {
        var arguments = ["attach", "-plist", "-nobrowse", "-noverify", "-noautofsck"]
        if readOnly { arguments.append("-readonly") }
        if ownersOff { arguments += ["-owners", "off"] }
        arguments.append(file)
        let result = runWithRetries(arguments)
        guard result.status == 0,
              let plist = try? PropertyListSerialization.propertyList(from: result.stdout, options: [], format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            throw XCTSkip("this runner could not attach the disk image: \(result.text)")
        }
        guard let volume = entities.first(where: { $0["mount-point"] is String }), let mount = volume["mount-point"] as? String else {
            throw XCTSkip("the disk image did not mount")
        }
        let device = (entities.compactMap { $0["dev-entry"] as? String }.first) ?? ""
        return Image(file: file, device: device, mountPoint: mount, volumeName: (mount as NSString).lastPathComponent)
    }

    /// Detaches the whole image. `force` ignores open files (an unplug in all but name).
    @discardableResult
    static func detach(_ image: Image, force: Bool = false) -> Bool {
        let target = image.device.isEmpty ? image.mountPoint : image.device
        let arguments = force ? ["detach", "-force", target] : ["detach", target]
        return runWithRetries(arguments).status == 0
    }
}
