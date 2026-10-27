import Foundation
import Darwin
import CoreGraphics
import ApplicationServices

/// Error text is fixed per case. It never contains argv, stdin, stdout, stderr or environment values.
enum DisclaimSpawnError: LocalizedError, Equatable {
    case disclaimUnavailable
    case disclaimFailed
    case invalidRequest
    case setupFailed
    case launchFailed(Int32)
    case timedOut(TimeInterval)
    case outputTooLarge
    case errorOutputTooLarge
    case waitFailed

    var errorDescription: String? {
        switch self {
        case .disclaimUnavailable: return "系统缺少子进程责任隔离接口，已拒绝启动子进程（不会回退为继承屏幕录制或辅助功能授权）。"
        case .disclaimFailed: return "无法为子进程放弃屏幕录制和辅助功能授权责任，已拒绝启动。"
        case .invalidRequest: return "子进程请求无效。"
        case .setupFailed: return "无法准备子进程隔离环境。"
        case .launchFailed(let code): return "无法启动子进程（系统错误 \(code)）。请检查可执行文件及其运行环境。"
        case .timedOut(let seconds): return "子进程超时（\(Int(seconds)) 秒），已终止。"
        case .outputTooLarge: return "子进程输出过大，已终止。"
        case .errorOutputTooLarge: return "子进程错误输出过大，已终止。"
        case .waitFailed: return "无法获取子进程退出状态。"
        }
    }
}


/// Drives a child's stdin from its stdout. Called only from the spawner's I/O thread, serially.
struct DisclaimInteractiveStep { var write = Data(); var closeInput = false }
protocol DisclaimInteractiveDriver: AnyObject {
    func consume(_ chunk: Data) -> DisclaimInteractiveStep
}
struct DisclaimSpawnRequest {
    enum WorkingDirectory {
        /// Fresh 0700 directory under the temporary directory, removed after the child and its group are gone.
        case privateTemporary(prefix: String)
        /// Existing absolute directory (not created or removed).
        case path(String)
    }

    /// Absolute path of the executable (no PATH search, no shell).
    var executable: String
    /// Arguments after argv[0]; argv[0] is always `executable`.
    var arguments: [String] = []
    /// The complete child environment. Nothing is inherited implicitly; see `DisclaimEnvironment`.
    var environment: [String: String]
    var standardInput = Data()
    /// Optional interactive lifecycle. When set, stdin stays open after `standardInput` is written; the driver sees
    /// every stdout chunk (on the spawner's I/O thread) and decides what to write next and when to send EOF.
    /// Timeout, cancellation, output caps, process-group kill and private cwd apply unchanged.
    var interactive: DisclaimInteractiveDriver?
    var workingDirectory: WorkingDirectory = .privateTemporary(prefix: "cmux-spawn")
    var timeout: TimeInterval = 30
    var maxStandardOutput = 8 * 1024 * 1024
    var maxStandardError = 1024 * 1024
    /// stderr is always drained and size-capped. Retained only when a caller needs to parse it; it must never be shown.
    var retainStandardError = false
    /// Delay between SIGTERM and SIGKILL of the process group.
    var killGrace: TimeInterval = 1
}

struct DisclaimSpawnResult {
    var standardOutput: Data
    var standardError: Data
    /// Exit code, or 128 + signal when killed by a signal.
    var exitStatus: Int32
    var signal: Int32?
}

/// Environment helpers for children. Always an explicit allow/remove decision, never a shell.
enum DisclaimEnvironment {
    /// Current process environment minus the listed prefixes/keys, plus overrides.
    static func inherited(removingPrefixes prefixes: [String] = [], removingKeys keys: Set<String> = [], overrides: [String: String] = [:]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where keys.contains(key) || prefixes.contains(where: { key.hasPrefix($0) }) {
            environment.removeValue(forKey: key)
        }
        for (key, value) in overrides { environment[key] = value }
        return environment
    }

    /// Terminal CLIs: clear every cmux/WezTerm (Kaku) target variable so the target is always explicit.
    /// Pass plugin-specific extra variable names (e.g. Kaku target variables) in `extraKeys`.
    static func terminalCLI(extraKeys: Set<String> = [], overrides: [String: String] = [:]) -> [String: String] {
        inherited(removingPrefixes: ["CMUX_", "WEZTERM_", "KAKU_"], removingKeys: extraKeys, overrides: overrides)
    }

    /// Environment for pi: keeps HOME, PATH, provider secrets and PI_CODING_AGENT_DIR (models/auth),
    /// drops cmux and pi session/intercom state.
    static func pi() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("CMUX_") || key.hasPrefix("PI_SESSION") || key.hasPrefix("PI_INTERCOM") || key == "PI_CODING_AGENT_SESSION_DIR" {
            environment.removeValue(forKey: key)
        }
        return environment
    }
}

/// The single process launcher for pi, its auth helpers and terminal-plugin CLIs.
/// posix_spawn only; sets responsibility_spawnattrs_setdisclaim(attr, 1) so the child is its own
/// TCC responsible process and does not inherit this app's Screen Recording / Accessibility grants.
/// The private symbol is resolved dynamically; when it is missing or fails, nothing is launched.
enum DisclaimSpawner {
    private typealias DisclaimFunction = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>?, Int32) -> Int32
    private static let disclaimFunction: DisclaimFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else { return nil } // RTLD_DEFAULT
        return unsafeBitCast(symbol, to: DisclaimFunction.self)
    }()

    static var isAvailable: Bool { disclaimFunction != nil }

    /// Blocking-free async entry. Cancelling the calling task terminates the child's process group.
    static func run(_ request: DisclaimSpawnRequest) async throws -> DisclaimSpawnResult {
        try await DisclaimedProcess(request).run()
    }

    fileprivate static func applyDisclaim(_ attributes: inout posix_spawnattr_t?) throws {
        guard let function = disclaimFunction else { throw DisclaimSpawnError.disclaimUnavailable }
        guard function(&attributes, 1) == 0 else { throw DisclaimSpawnError.disclaimFailed }
    }
}

/// One spawn. Create, `run()` once, `cancel()` from any thread. The child leads its own process group;
/// timeout, cancellation, oversize output and a finished leader all kill the whole group
/// (SIGTERM, then SIGKILL after `killGrace`; leftover group members are SIGKILLed once the leader exits).
final class DisclaimedProcess: @unchecked Sendable {
    private let request: DisclaimSpawnRequest
    private let lock = NSLock()
    private var cancelled = false
    private var started = false
    private var pid: pid_t = 0

    init(_ request: DisclaimSpawnRequest) { self.request = request }

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return pid > 0 }

    func cancel() {
        lock.lock()
        cancelled = true
        if pid > 0 { Darwin.kill(-pid, SIGTERM) }
        lock.unlock()
    }

    func run() async throws -> DisclaimSpawnResult {
        try Task.checkCancellation()
        let result = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<DisclaimSpawnResult, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try self.runBlocking()) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { self.cancel() })
        try Task.checkCancellation()
        if isCancelled { throw CancellationError() }
        return result
    }

    /// Blocks the calling thread. Prefer `run()`.
    func runBlocking() throws -> DisclaimSpawnResult {
        lock.lock()
        guard !started else { lock.unlock(); throw DisclaimSpawnError.invalidRequest }
        started = true
        let alreadyCancelled = cancelled
        lock.unlock()
        if alreadyCancelled { throw CancellationError() }
        guard request.executable.hasPrefix("/"), request.timeout > 0, request.maxStandardOutput >= 0, request.maxStandardError >= 0,
              !request.executable.contains("\0"), !request.arguments.contains(where: { $0.contains("\0") }),
              !request.environment.contains(where: { $0.key.isEmpty || $0.key.contains("=") || $0.key.contains("\0") || $0.value.contains("\0") })
        else { throw DisclaimSpawnError.invalidRequest }
        guard FileManager.default.isExecutableFile(atPath: request.executable) else { throw DisclaimSpawnError.launchFailed(ENOENT) }

        var temporaryDirectory: URL?
        let workingPath: String
        switch request.workingDirectory {
        case .path(let path):
            guard path.hasPrefix("/"), !path.contains("\0") else { throw DisclaimSpawnError.invalidRequest }
            workingPath = path
        case .privateTemporary(let prefix):
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
            do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
            catch { throw DisclaimSpawnError.setupFailed }
            temporaryDirectory = directory
            workingPath = directory.path
        }
        defer { if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) } }

        var descriptors: [Int32] = []
        defer { for fd in descriptors { Darwin.close(fd) } }
        func closeFD(_ fd: Int32) { if let index = descriptors.firstIndex(of: fd) { Darwin.close(fd); descriptors.remove(at: index) } }
        func makePipe() throws -> [Int32] {
            var pair: [Int32] = [0, 0]
            guard Darwin.pipe(&pair) == 0 else { throw DisclaimSpawnError.setupFailed }
            descriptors += pair
            for index in 0..<2 {
                // Never let a pipe end occupy 0-2, or dup2 onto stdio would clobber it. F_DUPFD_CLOEXEC also sets close-on-exec.
                let moved = fcntl(pair[index], F_DUPFD_CLOEXEC, 3)
                guard moved >= 0 else { throw DisclaimSpawnError.setupFailed }
                closeFD(pair[index])
                descriptors.append(moved)
                pair[index] = moved
            }
            return pair
        }
        let stdinPipe = try makePipe(), stdoutPipe = try makePipe(), stderrPipe = try makePipe()

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw DisclaimSpawnError.setupFailed }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw DisclaimSpawnError.setupFailed }
        defer { posix_spawnattr_destroy(&attributes) }
        // Fail closed before anything is launched.
        try DisclaimSpawner.applyDisclaim(&attributes)

        var setup: Int32 = 0
        setup |= posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], STDIN_FILENO)
        setup |= posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO)
        setup |= posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO)
        if #available(macOS 26.0, *) {
            setup |= posix_spawn_file_actions_addchdir(&actions, workingPath)
        } else {
            setup |= posix_spawn_file_actions_addchdir_np(&actions, workingPath)
        }
        var emptyMask = sigset_t(), allSignals = sigset_t()
        sigemptyset(&emptyMask)
        sigfillset(&allSignals)
        setup |= posix_spawnattr_setsigmask(&attributes, &emptyMask)
        setup |= posix_spawnattr_setsigdefault(&attributes, &allSignals)
        // 0x4000 = POSIX_SPAWN_CLOEXEC_DEFAULT: only fds 0-2 survive into the child.
        setup |= posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF) | 0x4000)
        setup |= posix_spawnattr_setpgroup(&attributes, 0)
        guard setup == 0 else { throw DisclaimSpawnError.setupFailed }

        var argv = ([request.executable] + request.arguments).map { strdup($0) } + [nil]
        var envp = request.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for value in argv { free(value) }; for value in envp { free(value) } }

        var child: pid_t = 0
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        let spawnResult = posix_spawn(&child, request.executable, &actions, &attributes, &argv, &envp)
        if spawnResult == 0 { pid = child }
        lock.unlock()
        guard spawnResult == 0 else { throw DisclaimSpawnError.launchFailed(spawnResult) }

        closeFD(stdinPipe[0]); closeFD(stdoutPipe[1]); closeFD(stderrPipe[1])
        for fd in [stdinPipe[1], stdoutPipe[0], stderrPipe[0]] { _ = fcntl(fd, F_SETFL, O_NONBLOCK) }
        _ = fcntl(stdinPipe[1], F_SETNOSIGPIPE, 1)

        var input = request.standardInput
        var closeRequested = request.interactive == nil
        let start = ProcessInfo.processInfo.systemUptime
        var stopAt: TimeInterval?
        var exitedAt: TimeInterval?
        var failure: DisclaimSpawnError?
        var output = Data(), errorData = Data()
        var errorBytes = 0, inputOffset = 0
        var exited = false, status: Int32 = 0
        var openInput = true, openOutput = true, openError = true
        var buffer = [UInt8](repeating: 0, count: 16384)
        if input.isEmpty && closeRequested { closeFD(stdinPipe[1]); openInput = false }

        while !exited || openOutput || openError {
            let now = ProcessInfo.processInfo.systemUptime
            if stopAt == nil && (isCancelled || now - start >= request.timeout || failure != nil) {
                if !isCancelled && failure == nil { failure = .timedOut(request.timeout) }
                stopAt = now
                Darwin.kill(-child, SIGTERM)
                if openInput { closeFD(stdinPipe[1]); openInput = false }
            }
            if let stopAt, now - stopAt >= request.killGrace { Darwin.kill(-child, SIGKILL) }
            // A daemonized descendant outside the group can hold the pipes forever; stop waiting shortly after exit.
            if let exitedAt, now - exitedAt >= 2, openOutput || openError {
                if openOutput { closeFD(stdoutPipe[0]); openOutput = false }
                if openError { closeFD(stderrPipe[0]); openError = false }
                if failure == nil { failure = .waitFailed }
                break
            }
            var polls = [pollfd(fd: openInput && inputOffset < input.count ? stdinPipe[1] : -1, events: Int16(POLLOUT), revents: 0),
                         pollfd(fd: openOutput ? stdoutPipe[0] : -1, events: Int16(POLLIN), revents: 0),
                         pollfd(fd: openError ? stderrPipe[0] : -1, events: Int16(POLLIN), revents: 0)]
            _ = Darwin.poll(&polls, nfds_t(polls.count), 50)
            if openInput && polls[0].revents != 0 {
                let count = input.withUnsafeBytes { bytes in Darwin.write(stdinPipe[1], bytes.baseAddress!.advanced(by: inputOffset), input.count - inputOffset) }
                if count > 0 { inputOffset += count }
                if (inputOffset >= input.count && closeRequested) || (count < 0 && errno != EAGAIN && errno != EINTR) { closeFD(stdinPipe[1]); openInput = false }
            }
            for channel in 1...2 where polls[channel].fd >= 0 && polls[channel].revents != 0 {
                let fd = polls[channel].fd
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count > 0 {
                    if channel == 1 {
                        if output.count + count <= request.maxStandardOutput {
                            let chunk = Data(buffer.prefix(count))
                            output.append(chunk)
                            if let driver = request.interactive, openInput || !closeRequested {
                                let step = driver.consume(chunk)
                                if openInput, !step.write.isEmpty {
                                    if inputOffset >= input.count { input = step.write; inputOffset = 0 } else { input.append(step.write) }
                                }
                                if step.closeInput { closeRequested = true }
                                if openInput && closeRequested && inputOffset >= input.count { closeFD(stdinPipe[1]); openInput = false }
                            }
                        }
                        else if failure == nil { failure = .outputTooLarge }
                    } else {
                        errorBytes += count // Drain; retain only on explicit request, within the cap.
                        if errorBytes > request.maxStandardError { if failure == nil { failure = .errorOutputTooLarge } }
                        else if request.retainStandardError { errorData.append(contentsOf: buffer.prefix(count)) }
                    }
                } else if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) {
                    closeFD(fd)
                    if channel == 1 { openOutput = false } else { openError = false }
                }
            }
            if !exited {
                // Detect exit without reaping so the pgid cannot be recycled before the group is killed.
                var info = siginfo_t()
                let waited = waitid(P_PID, id_t(child), &info, WEXITED | WNOHANG | WNOWAIT)
                if waited == 0 && info.si_pid == child {
                    exited = true
                    exitedAt = ProcessInfo.processInfo.systemUptime
                    // Credential helpers and other group members must not outlive the child.
                    Darwin.kill(-child, SIGKILL)
                    if openInput { closeFD(stdinPipe[1]); openInput = false }
                } else if waited < 0 && errno != EINTR {
                    exited = true
                    exitedAt = ProcessInfo.processInfo.systemUptime
                    if failure == nil { failure = .waitFailed }
                    Darwin.kill(-child, SIGKILL)
                }
            }
        }

        // Reap under the lock so cancel() can never signal a recycled pid.
        lock.lock()
        var reaped: pid_t
        repeat { reaped = waitpid(child, &status, 0) } while reaped < 0 && errno == EINTR
        pid = 0
        lock.unlock()
        if isCancelled { throw CancellationError() }
        if let failure { throw failure }
        guard reaped == child else { throw DisclaimSpawnError.waitFailed }
        let signal: Int32? = (status & 0x7f) == 0 ? nil : status & 0x7f
        let exitStatus: Int32 = signal.map { 128 + $0 } ?? (status >> 8) & 0xff
        return DisclaimSpawnResult(standardOutput: output, standardError: errorData, exitStatus: exitStatus, signal: signal)
    }
}

/// Evidence that a disclaimed child does not inherit this app's Screen Recording / Accessibility trust.
/// The app executable re-invokes itself with `argument` (handled before NSApplication starts, see `emitAndExit`);
/// the parent compares the child's answers with its own preflight values. Both must be false in the child.
enum ChildPermissionProbe {
    static let argument = "--child-permission-probe"

    struct Report: Equatable {
        var screenRecordingPreflight: Bool
        var accessibilityTrusted: Bool
    }

    /// Call from the executable's entry point when `CommandLine.arguments` contains `argument`.
    /// Prints one line `sr=<0|1> ax=<0|1>`, never prompts (CGPreflight does not prompt; AXIsProcessTrusted does not prompt).
    static func emitAndExit() -> Never {
        let report = "sr=\(CGPreflightScreenCaptureAccess() ? 1 : 0) ax=\(AXIsProcessTrusted() ? 1 : 0)\n"
        FileHandle.standardOutput.write(Data(report.utf8))
        exit(0)
    }

    /// Spawns this app's own executable through the shared disclaiming spawner.
    static func run(executable: String? = Bundle.main.executablePath) async throws -> Report {
        guard let executable else { throw DisclaimSpawnError.launchFailed(ENOENT) }
        var request = DisclaimSpawnRequest(executable: executable, arguments: [argument],
                                           environment: DisclaimEnvironment.inherited(removingPrefixes: ["CMUX_"]))
        request.timeout = 10
        request.maxStandardOutput = 64
        request.maxStandardError = 4096
        let result = try await DisclaimSpawner.run(request)
        guard result.exitStatus == 0, let text = String(data: result.standardOutput, encoding: .utf8) else { throw DisclaimSpawnError.waitFailed }
        let fields = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard fields.count == 2, let sr = fields[0].split(separator: "=").last, let ax = fields[1].split(separator: "=").last,
              ["0", "1"].contains(String(sr)), ["0", "1"].contains(String(ax)) else { throw DisclaimSpawnError.waitFailed }
        return Report(screenRecordingPreflight: sr == "1", accessibilityTrusted: ax == "1")
    }
}
