import Foundation
import OutboardCore

/// The only place a child process is started (BUILD_PLAN §5.2, grep G4). A closed enum of commands with absolute paths and
/// argument arrays: no shell, no input, no environment from outside. `diskutil` and `tmutil` only read. `defaults` runs for
/// catalogue keys only. A command that takes too long is abandoned: the caller gets `timedOut`, and the child is never
/// signalled (Outboard has no signal API anywhere).
enum ProcessRunner {
    enum Command {
        case diskutilInfo(path: String)
        case diskutilList
        case diskutilApfsList
        case tmutilDestinations
        case defaultsRead(domain: String, key: String)
        case defaultsWrite(domain: String, key: String, type: DefaultsValueType, value: String)

        var path: String {
            switch self {
            case .diskutilInfo, .diskutilList, .diskutilApfsList: return "/usr/sbin/diskutil"
            case .tmutilDestinations: return "/usr/bin/tmutil"
            case .defaultsRead, .defaultsWrite: return "/usr/bin/defaults"
            }
        }

        /// Empty means "not allowed": a defaults key that is not in the catalogue is never run.
        var arguments: [String] {
            switch self {
            case .diskutilInfo(let path): return ["info", "-plist", path]
            case .diskutilList: return ["list", "-plist"]
            case .diskutilApfsList: return ["apfs", "list", "-plist"]
            case .tmutilDestinations: return ["destinationinfo", "-X"]
            case .defaultsRead(let domain, let key):
                guard Catalogue.allowsDefaults(domain, key) else { return [] }
                return ["read", domain, key]
            case .defaultsWrite(let domain, let key, let type, let value):
                guard Catalogue.allowsDefaults(domain, key) else { return [] }
                return ["write", domain, key, type.flag, value]
            }
        }
    }

    struct Output: Sendable {
        var status: Int32
        var stdout: Data
        var timedOut: Bool
        var ran: Bool = true
        var ok: Bool { ran && !timedOut && status == 0 }
        var text: String { String(decoding: stdout, as: UTF8.self) }
    }

    private static let outputCap = 1 << 20

    #if DEBUG
    /// Tests only: answers a command without running it (so a test never writes the real user's preferences) and shortens the wait.
    static var interceptor: ((Command) -> Output?)?
    static var timeoutSeconds: TimeInterval = 10
    #else
    private static let timeoutSeconds: TimeInterval = 10
    #endif

    /// Blocks the calling thread for at most the timeout (the engine's critical section cannot suspend, so the defaults path
    /// calls this directly). Absolute executable, argument array, stdin and stderr on /dev/null, stdout drained concurrently (no
    /// 64 KB pipe deadlock) and capped at 1 MB. A stuck child keeps its drain thread until it exits; that is the price of never
    /// signalling.
    static func run(_ command: Command) -> Output {
        guard !command.arguments.isEmpty else { return Output(status: -2, stdout: Data(), timedOut: false, ran: false) }
        #if DEBUG
        if let answer = interceptor?(command) { return answer }
        #endif
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.path)
        process.arguments = command.arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { return Output(status: -1, stdout: Data(), timedOut: false, ran: false) }

        let collected = Collected()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            // Keep draining past the cap so the child never blocks on a full pipe.
            while let chunk = try? pipe.fileHandleForReading.read(upToCount: 1 << 16), !chunk.isEmpty {
                collected.add(chunk, cap: outputCap)
            }
            process.waitUntilExit()
            collected.finish(status: process.terminationStatus)
            finished.signal()
        }
        if finished.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            return Output(status: -1, stdout: collected.data, timedOut: true)
        }
        return Output(status: collected.status, stdout: collected.data, timedOut: false)
    }

    /// The same, for async callers: the wait happens on a background queue, not on the cooperative pool.
    static func runAsync(_ command: Command) async -> Output {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: run(command)) }
        }
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private var code: Int32 = -1

        func add(_ chunk: Data, cap: Int) {
            lock.lock()
            if buffer.count < cap { buffer.append(chunk.prefix(cap - buffer.count)) }
            lock.unlock()
        }

        func finish(status: Int32) {
            lock.lock()
            code = status
            lock.unlock()
        }

        var data: Data {
            lock.lock()
            defer { lock.unlock() }
            return buffer
        }

        var status: Int32 {
            lock.lock()
            defer { lock.unlock() }
            return code
        }
    }
}
