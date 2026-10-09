import Darwin
import Foundation
import AppKit
import Security
import ServiceManagement

enum SMCHelperService {
    /// System daemon socket. The helper runs outside the login session, so
    /// shutdown no longer treats it as another logged-in user.
    static let socketPath = "/var/run/thermometer-smc.sock"
    static let versionPath = "/Library/PrivilegedHelperTools/com.local.Thermometer.helper.version"
    static let plistPath = "/Library/LaunchDaemons/com.local.Thermometer.helper.plist"
    static let jobLabel = "com.local.Thermometer.helper"
    static var lastFailureMessage: String?

    static func legacySocketPath() -> String {
        "/tmp/thermometer-smc-\(getuid()).sock"
    }

    static func currentHelperVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    static func helperVersionMatches() -> Bool {
        guard let installed = try? String(contentsOfFile: versionPath, encoding: .utf8) else {
            return false
        }
        return installed.trimmingCharacters(in: .whitespacesAndNewlines) == currentHelperVersion()
    }

    static func isPrivilegedHelperRunning() -> Bool {
        guard let response = ping() else { return false }
        return response.root == true || response.uid == 0
    }

    static func ping() -> SMCHelperResponse? {
        switch send(SMCHelperRequest(cmd: "ping"), timeoutSeconds: 1.5) {
        case .success(let response) where response.ok:
            return response
        default:
            return nil
        }
    }

    static func apply(
        mode: FanControlMode,
        manualPercent: Double,
        curveStartC: Double,
        curveFullC: Double
    ) -> FanControlOutcome? {
        let request = SMCHelperRequest(
            cmd: "apply",
            mode: mode.rawValue,
            manualPercent: manualPercent,
            curveStartC: curveStartC,
            curveFullC: curveFullC
        )
        switch send(request, timeoutSeconds: 12) {
        case .success(let response):
            var targets: [Int: Double] = [:]
            response.targets?.forEach { key, value in
                if let index = Int(key) {
                    targets[index] = value
                }
            }
            return FanControlOutcome(
                targets: targets,
                error: response.error,
                needsPrivilege: response.needsPrivilege ?? false
            )
        case .failure:
            return nil
        }
    }

    static func restore(fanCount: Int) {
        _ = send(SMCHelperRequest(cmd: "restore", fanCount: fanCount), timeoutSeconds: 4)
    }

    /// Stops a helper left in the GUI session by older builds. That process is
    /// what makes macOS ask for an administrator password on every shutdown.
    static func retireLegacySessionHelper() {
        if didRetireLegacyHelper { return }
        didRetireLegacyHelper = true
        _ = send(
            SMCHelperRequest(cmd: "quit"),
            timeoutSeconds: 2,
            socketPath: legacySocketPath()
        )
    }

    @discardableResult
    static func ensureRunning(allowInteraction: Bool) -> Bool {
        retireLegacySessionHelper()
        if isPrivilegedHelperRunning() {
            if helperVersionMatches() || !allowInteraction {
                return true
            }
        }
        guard allowInteraction else { return false }
        lastFailureMessage = nil
        guard FanPrivilege.shared.installHelper() else { return false }
        if waitUntilRunning() {
            return true
        }
        if legacyHelperNeedsApproval() {
            lastFailureMessage = "请在系统设置的登录项中允许 Thermometer 风扇助手。允许一次后，关机不再询问密码。"
            if #available(macOS 13.0, *) {
                SMAppService.openSystemSettingsLoginItems()
            }
        } else if lastFailureMessage == nil {
            lastFailureMessage = "风扇助手没有启动，请再授权一次"
        }
        return false
    }

    static func waitUntilRunning(timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isPrivilegedHelperRunning() {
                return true
            }
            Thread.sleep(forTimeInterval: 0.12)
        }
        return isPrivilegedHelperRunning()
    }

    private static var didRetireLegacyHelper = false

    private static func legacyHelperNeedsApproval() -> Bool {
        guard #available(macOS 13.0, *),
              FileManager.default.fileExists(atPath: plistPath) else {
            return false
        }
        return SMAppService.statusForLegacyPlist(at: URL(fileURLWithPath: plistPath)) == .requiresApproval
    }

    private static func send(
        _ request: SMCHelperRequest,
        timeoutSeconds: TimeInterval = 3,
        socketPath: String? = nil
    ) -> Result<SMCHelperResponse, Error> {
        do {
            let data = try JSONEncoder().encode(request) + Data([0x0A])
            let reply = try transact(
                data,
                timeoutSeconds: timeoutSeconds,
                socketPath: socketPath ?? Self.socketPath
            )
            let response = try JSONDecoder().decode(SMCHelperResponse.self, from: reply)
            return .success(response)
        } catch {
            return .failure(error)
        }
    }

    private static func transact(
        _ payload: Data,
        timeoutSeconds: TimeInterval,
        socketPath: String
    ) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SMCHelperError.connect }
        defer { close(fd) }

        var addr = unixAddress(socketPath)
        let connected = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw SMCHelperError.connect }

        var written = 0
        payload.withUnsafeBytes { buffer in
            if let base = buffer.baseAddress {
                written = Darwin.write(fd, base, payload.count)
            }
        }
        guard written == payload.count else { throw SMCHelperError.connect }

        var reply = Data()
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var chunk = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count > 0 {
                reply.append(contentsOf: chunk.prefix(count))
                if reply.contains(0x0A) {
                    break
                }
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                break
            }
        }
        guard let newline = reply.firstIndex(of: 0x0A) else {
            throw SMCHelperError.connect
        }
        return reply.prefix(upTo: newline)
    }
}

/// Asks for an administrator password once, installs a LaunchDaemon, then
/// drops the authorization. The daemon is not part of the login session.
private final class FanPrivilege {
    static let shared = FanPrivilege()

    private let lock = NSLock()
    private var authRef: AuthorizationRef?
    private var suppressFallback = false

    func installHelper() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if SMCHelperService.isPrivilegedHelperRunning(), SMCHelperService.helperVersionMatches() {
            return true
        }
        suppressFallback = false
        let installed = installWithAuthorizationServices() || (!suppressFallback && installWithAppleScript())
        releaseAuthorization()
        return installed
    }

    deinit {
        releaseAuthorization()
    }

    private func releaseAuthorization() {
        if let authRef {
            AuthorizationFree(authRef, [])
            self.authRef = nil
        }
    }

    private func obtainRights(allowInteraction: Bool) -> Bool {
        if authRef == nil {
            var created: AuthorizationRef?
            let status = AuthorizationCreate(nil, nil, [], &created)
            guard status == errAuthorizationSuccess, let created else {
                return false
            }
            authRef = created
        }
        guard let authRef else { return false }

        return kAuthorizationRightExecute.withCString { namePointer in
            var item = AuthorizationItem(
                name: namePointer,
                valueLength: 0,
                value: nil,
                flags: 0
            )
            return withUnsafeMutablePointer(to: &item) { itemPointer in
                var rights = AuthorizationRights(count: 1, items: itemPointer)
                var flags: AuthorizationFlags = [.extendRights, .preAuthorize]
                if allowInteraction {
                    flags.insert(.interactionAllowed)
                }
                NSApp.activate(ignoringOtherApps: true)
                let status = AuthorizationCopyRights(authRef, &rights, nil, flags, nil)
                if status == errAuthorizationCanceled {
                    suppressFallback = true
                    SMCHelperService.lastFailureMessage = "已取消授权"
                }
                return status == errAuthorizationSuccess
            }
        }
    }

    private func installWithAuthorizationServices() -> Bool {
        guard let executable = Bundle.main.executablePath, !executable.isEmpty else {
            return false
        }
        guard let exec = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "AuthorizationExecuteWithPrivileges") else {
            return false
        }
        guard obtainRights(allowInteraction: true) else {
            return false
        }
        // The password dialog already ran. Don't raise a second one if launch fails.
        suppressFallback = true
        guard let authRef else { return false }
        let execute = unsafeBitCast(exec, to: AuthorizationExecuteWithPrivilegesProc.self)
        let args = installArguments(executable: executable)
        let cStrings: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        defer {
            cStrings.dropLast().compactMap { $0 }.forEach { free($0) }
        }

        var pipe: UnsafeMutablePointer<FILE>?
        var argv = cStrings
        let status: OSStatus = executable.withCString { path in
            argv.withUnsafeMutableBufferPointer { buffer in
                execute(authRef, path, [], buffer.baseAddress, &pipe)
            }
        }
        guard status == errAuthorizationSuccess, let pipe else {
            if status == errAuthorizationCanceled {
                suppressFallback = true
                SMCHelperService.lastFailureMessage = "已取消授权"
            }
            if let pipe {
                fclose(pipe)
            }
            return false
        }
        let output = readPipe(pipe, timeout: 20)
        fclose(pipe)
        return interpretInstallerOutput(output, allowFallback: false)
    }

    private func installWithAppleScript() -> Bool {
        guard let executable = Bundle.main.executablePath, !executable.isEmpty else {
            return false
        }
        let shell = ([executable] + installArguments(executable: executable))
            .map(posixQuoted)
            .joined(separator: " ")
        let source = "do shell script \(appleScriptQuoted(shell)) with administrator privileges"
        NSApp.activate(ignoringOtherApps: true)
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return false }
        let result = script.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String
            SMCHelperService.lastFailureMessage = message?.isEmpty == false ? message : "已取消授权"
            return false
        }
        return interpretInstallerOutput(result.stringValue ?? "", allowFallback: true)
    }

    private func installArguments(executable: String) -> [String] {
        [
            "--install-privileged-helper",
            "--uid", String(getuid()),
            "--version", SMCHelperService.currentHelperVersion(),
            "--source", executable
        ]
    }

    private func interpretInstallerOutput(_ output: String, allowFallback: Bool) -> Bool {
        if output.contains("installed") {
            SMCHelperService.lastFailureMessage = nil
            return true
        }
        suppressFallback = !allowFallback
        if let line = output.split(separator: "\n").first(where: { $0.hasPrefix("error:") }) {
            SMCHelperService.lastFailureMessage = line.dropFirst("error:".count)
                .trimmingCharacters(in: .whitespaces)
        }
        return false
    }

    private func readPipe(_ pipe: UnsafeMutablePointer<FILE>, timeout: TimeInterval) -> String {
        let fd = fileno(pipe)
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
        var output = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 1024)
        while Date() < deadline {
            var polled = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remaining = Int32(max(deadline.timeIntervalSinceNow * 1000, 1))
            let result = poll(&polled, 1, min(remaining, 500))
            if result > 0 {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count > 0 {
                    output.append(contentsOf: buffer.prefix(count))
                } else if count == 0 {
                    break
                } else if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                    continue
                } else {
                    break
                }
            } else if result == 0 {
                continue
            } else if errno == EINTR {
                continue
            } else {
                break
            }
        }
        return String(data: output, encoding: .utf8) ?? ""
    }
}

private typealias AuthorizationExecuteWithPrivilegesProc = @convention(c) (
    AuthorizationRef,
    UnsafePointer<CChar>,
    AuthorizationFlags,
    UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
    UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
) -> OSStatus

private func helperArgument(_ name: String) -> String? {
    let flag = "--\(name)"
    guard let index = CommandLine.arguments.firstIndex(of: flag),
          index + 1 < CommandLine.arguments.count else {
        return nil
    }
    return CommandLine.arguments[index + 1]
}

private func peerIdentity(_ fd: Int32) -> (uid: uid_t, pid: pid_t)? {
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard getpeereid(fd, &uid, &gid) == 0 else { return nil }
    var pid: pid_t = 0
    var length = socklen_t(MemoryLayout<pid_t>.size)
    if getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) != 0 {
        pid = 0
    }
    return (uid, pid)
}

enum SMCHelperInstaller {
    static func run() -> Int32 {
        guard geteuid() == 0 else {
            emit("error: not root")
            return 1
        }
        guard let source = helperArgument("source"),
              let version = helperArgument("version"),
              let uid = helperArgument("uid").flatMap({ uid_t($0) }),
              FileManager.default.isExecutableFile(atPath: source) else {
            emit("error: invalid installer arguments")
            return 1
        }

        let destination = "/Library/PrivilegedHelperTools/com.local.Thermometer.helper"
        do {
            try install(source: source, destination: destination, uid: uid, version: version)
        } catch {
            emit("error: \(error.localizedDescription)")
            return 1
        }
        guard SMCHelperService.waitUntilRunning(timeout: 8) else {
            emit("error: helper failed to start")
            return 1
        }
        emit("installed")
        return 0
    }

    private static func install(
        source: String,
        destination: String,
        uid: uid_t,
        version: String
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            atPath: "/Library/PrivilegedHelperTools",
            withIntermediateDirectories: true
        )
        try fm.createDirectory(
            atPath: "/Library/Logs/Thermometer",
            withIntermediateDirectories: true
        )
        _ = runLaunchctl(["bootout", "system/\(SMCHelperService.jobLabel)"])
        Thread.sleep(forTimeInterval: 0.3)

        if fm.fileExists(atPath: destination) {
            try fm.removeItem(atPath: destination)
        }
        try fm.copyItem(atPath: source, toPath: destination)
        removexattr(destination, "com.apple.quarantine", 0)
        guard chmod(destination, 0o755) == 0, chown(destination, 0, 0) == 0 else {
            throw InstallerError("无法设置助手文件权限")
        }

        let plist: [String: Any] = [
            "Label": SMCHelperService.jobLabel,
            "Program": destination,
            "ProgramArguments": [
                destination,
                "--smc-helper",
                "--socket", SMCHelperService.socketPath,
                "--uid", String(uid)
            ],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 2,
            "ExitTimeOut": 20,
            "ProcessType": "Background",
            "StandardOutPath": "/Library/Logs/Thermometer/helper.log",
            "StandardErrorPath": "/Library/Logs/Thermometer/helper.log",
            "AssociatedBundleIdentifiers": ["com.local.Thermometer"]
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        let plistURL = URL(fileURLWithPath: SMCHelperService.plistPath)
        try data.write(to: plistURL, options: .atomic)
        try Data(version.utf8).write(to: URL(fileURLWithPath: SMCHelperService.versionPath), options: .atomic)
        guard chmod(SMCHelperService.plistPath, 0o644) == 0,
              chown(SMCHelperService.plistPath, 0, 0) == 0,
              chmod(SMCHelperService.versionPath, 0o644) == 0,
              chown(SMCHelperService.versionPath, 0, 0) == 0 else {
            throw InstallerError("无法设置助手配置权限")
        }

        _ = runLaunchctl(["enable", "system/\(SMCHelperService.jobLabel)"])
        let bootstrap = runLaunchctl(["bootstrap", "system", SMCHelperService.plistPath])
        if bootstrap.status != 0 {
            let kickstart = runLaunchctl(["kickstart", "-k", "system/\(SMCHelperService.jobLabel)"])
            if kickstart.status != 0 {
                let detail = bootstrap.output.trimmingCharacters(in: .whitespacesAndNewlines)
                throw InstallerError(detail.isEmpty ? "launchctl bootstrap 失败" : detail)
            }
        } else {
            _ = runLaunchctl(["kickstart", "-k", "system/\(SMCHelperService.jobLabel)"])
        }
    }

    private static func emit(_ message: String) {
        fputs(message + "\n", stdout)
        fflush(stdout)
    }

    private static func runLaunchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        let outputQueue = DispatchQueue(label: "com.local.Thermometer.launchctl")
        let outputBox = OutputBox()
        outputQueue.async {
            outputBox.data = pipe.fileHandleForReading.readDataToEndOfFile()
        }
        do {
            try process.run()
        } catch {
            try? pipe.fileHandleForWriting.close()
            return (1, error.localizedDescription)
        }
        process.waitUntilExit()
        outputQueue.sync {}
        return (process.terminationStatus, String(data: outputBox.data, encoding: .utf8) ?? "")
    }
}

private struct InstallerError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private final class OutputBox: @unchecked Sendable {
    var data = Data()
}

private var smcHelperStopFlag: Int32 = 0

enum SMCHelperServer {
    static func run() {
        signal(SIGPIPE, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let terminateSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        terminateSource.setEventHandler { smcHelperStopFlag = 1 }
        terminateSource.resume()
        let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        interruptSource.setEventHandler { smcHelperStopFlag = 1 }
        interruptSource.resume()

        let socketPath = helperArgument("socket") ?? SMCHelperService.socketPath
        let parentPid = helperArgument("parent-pid").flatMap(Int32.init) ?? 0
        let clientUID = helperArgument("uid").flatMap { uid_t($0) } ?? getuid()
        try? FileManager.default.createDirectory(
            atPath: "/Library/Logs/Thermometer",
            withIntermediateDirectories: true
        )
        let logURL = URL(fileURLWithPath: "/Library/Logs/Thermometer/helper.log")

        func log(_ message: String) {
            let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: logURL) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: logURL)
            }
        }

        log("helper start euid=\(geteuid()) uid=\(getuid()) pid=\(getpid()) socket=\(socketPath)")
        guard geteuid() == 0 else {
            log("refusing to run without root")
            _exit(2)
        }

        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            log("socket() failed errno=\(errno)")
            return
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)

        var addr = unixAddress(socketPath)
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            log("bind/listen failed errno=\(errno)")
            close(fd)
            return
        }
        let staffGID = getgrnam("staff").map { $0.pointee.gr_gid } ?? 20
        chown(socketPath, 0, staffGID)
        chmod(socketPath, 0o660)
        log("listening")

        let reader = HardwareSensorReader()
        var running = true
        var controllingPID: pid_t = 0

        func restoreAndExit() {
            log("restore and exit")
            reader.restoreAutomaticFans(fanCount: 8)
            unlink(socketPath)
            close(fd)
            running = false
        }

        while running && smcHelperStopFlag == 0 {
            if parentPid > 0, kill(parentPid, 0) != 0 {
                restoreAndExit()
                break
            }
            if controllingPID > 0 {
                errno = 0
                if kill(controllingPID, 0) != 0, errno == ESRCH {
                    log("client \(controllingPID) exited, restoring fans")
                    reader.restoreAutomaticFans(fanCount: 8)
                    controllingPID = 0
                }
            }

            var clientAddr = sockaddr_un()
            var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let client = withUnsafeMutablePointer(to: &clientAddr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(fd, $0, &clientLen)
                }
            }
            if client < 0 {
                usleep(150_000)
                continue
            }
            defer { close(client) }

            let peer = peerIdentity(client)
            let peerUID = peer?.uid ?? uid_t.max
            guard peerUID == 0 || peerUID == clientUID else {
                _ = writeLine(to: client, SMCHelperResponse(ok: false, error: "forbidden"))
                continue
            }
            if peerUID == clientUID, let pid = peer?.pid, pid > 0 {
                controllingPID = pid
            }

            guard let payload = readLine(from: client),
                  let request = try? JSONDecoder().decode(SMCHelperRequest.self, from: payload)
            else {
                _ = writeLine(to: client, SMCHelperResponse(ok: false, error: "invalid request"))
                continue
            }

            switch request.cmd {
            case "ping":
                _ = writeLine(
                    to: client,
                    SMCHelperResponse(ok: true, root: geteuid() == 0, uid: UInt32(geteuid()))
                )

            case "apply":
                let mode = FanControlMode(rawValue: request.mode ?? "") ?? .system
                let snapshot = reader.sample()
                let outcome = reader.applyFanControl(
                    mode: mode,
                    manualPercent: request.manualPercent ?? 0.45,
                    curveStartC: request.curveStartC ?? 55,
                    curveFullC: request.curveFullC ?? 85,
                    controlTemperature: [snapshot.cpuC, snapshot.gpuC].compactMap { $0 }.max(),
                    fans: snapshot.fans
                )
                log("apply mode=\(mode.rawValue) error=\(outcome.error ?? "none") targets=\(outcome.targets)")
                var encodedTargets: [String: Double] = [:]
                outcome.targets.forEach { encodedTargets[String($0.key)] = $0.value }
                _ = writeLine(
                    to: client,
                    SMCHelperResponse(
                        ok: outcome.error == nil,
                        needsPrivilege: outcome.needsPrivilege,
                        error: outcome.error,
                        targets: encodedTargets,
                        root: geteuid() == 0,
                        uid: UInt32(geteuid())
                    )
                )

            case "restore":
                reader.restoreAutomaticFans(fanCount: request.fanCount ?? 8)
                _ = writeLine(to: client, SMCHelperResponse(ok: true, root: true, uid: 0))

            case "quit":
                _ = writeLine(to: client, SMCHelperResponse(ok: true, root: true, uid: 0))
                restoreAndExit()

            default:
                _ = writeLine(to: client, SMCHelperResponse(ok: false, error: "unknown command"))
            }
        }
        if running {
            restoreAndExit()
        }
    }

    private static func readLine(from fd: Int32) -> Data? {
        var data = Data()
        var byte: UInt8 = 0
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            let count = Darwin.read(fd, &byte, 1)
            if count == 1 {
                if byte == 0x0A { break }
                data.append(byte)
                if data.count > 16_384 { return nil }
            } else if count == 0 {
                break
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                usleep(20_000)
            } else if errno == EINTR {
                continue
            } else {
                break
            }
        }
        return data.isEmpty ? nil : data
    }

    private static func writeLine(to fd: Int32, _ response: SMCHelperResponse) -> Bool {
        guard var data = try? JSONEncoder().encode(response) else { return false }
        data.append(0x0A)
        return data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return false }
            return Darwin.write(fd, base, data.count) == data.count
        }
    }
}

struct SMCHelperRequest: Codable {
    var cmd: String
    var mode: String?
    var manualPercent: Double?
    var curveStartC: Double?
    var curveFullC: Double?
    var fanCount: Int?
}

struct SMCHelperResponse: Codable {
    var ok: Bool
    var needsPrivilege: Bool?
    var error: String?
    var targets: [String: Double]?
    var root: Bool?
    var uid: UInt32?
}

private enum SMCHelperError: Error {
    case connect
}

private func posixQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func appleScriptQuoted(_ value: String) -> String {
    "\"" + value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    + "\""
}

private func unixAddress(_ path: String) -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let chars = path.utf8CString
    withUnsafeMutablePointer(to: &addr.sun_path) { tuplePointer in
        tuplePointer.withMemoryRebound(to: CChar.self, capacity: 104) { destination in
            chars.withUnsafeBufferPointer { source in
                let count = min(source.count, 104)
                if let base = source.baseAddress {
                    destination.update(from: base, count: count)
                }
            }
        }
    }
    return addr
}
