import Darwin
import Foundation
import AppKit
import Security

enum SMCHelperService {
    static var socketPath: String {
        "/tmp/thermometer-smc-\(getuid()).sock"
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

    static func shutdown() {
        _ = send(SMCHelperRequest(cmd: "quit"), timeoutSeconds: 2)
        FanPrivilege.shared.releaseSpawnedHelper()
    }

    @discardableResult
    static func ensureRunning(allowInteraction: Bool) -> Bool {
        if isPrivilegedHelperRunning() {
            return true
        }
        return FanPrivilege.shared.startHelper(allowInteraction: allowInteraction)
    }

    private static func send(
        _ request: SMCHelperRequest,
        timeoutSeconds: TimeInterval = 3
    ) -> Result<SMCHelperResponse, Error> {
        do {
            let data = try JSONEncoder().encode(request) + Data([0x0A])
            let reply = try transact(data, timeoutSeconds: timeoutSeconds)
            let response = try JSONDecoder().decode(SMCHelperResponse.self, from: reply)
            return .success(response)
        } catch {
            return .failure(error)
        }
    }

    private static func transact(_ payload: Data, timeoutSeconds: TimeInterval) throws -> Data {
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

/// Holds a session AuthorizationRef so the password is asked once and reused.
private final class FanPrivilege {
    static let shared = FanPrivilege()

    private let lock = NSLock()
    private var authRef: AuthorizationRef?
    private var communicationsPipe: UnsafeMutablePointer<FILE>?

    func startHelper(allowInteraction: Bool) -> Bool {
        if SMCHelperService.isPrivilegedHelperRunning() {
            return true
        }
        lock.lock()
        if SMCHelperService.isPrivilegedHelperRunning() {
            lock.unlock()
            return true
        }
        var started = startWithAuthorizationServices(allowInteraction: allowInteraction)
        if !started, allowInteraction {
            started = startWithAppleScript()
        }
        lock.unlock()
        guard started else { return false }
        return waitUntilRunning()
    }

    func releaseSpawnedHelper() {
        if let pipe = communicationsPipe {
            fclose(pipe)
            communicationsPipe = nil
        }
    }

    deinit {
        releaseSpawnedHelper()
        if let authRef {
            AuthorizationFree(authRef, [])
        }
    }

    private func waitUntilRunning() -> Bool {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if SMCHelperService.isPrivilegedHelperRunning() {
                return true
            }
            Thread.sleep(forTimeInterval: 0.12)
        }
        return SMCHelperService.isPrivilegedHelperRunning()
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
                return AuthorizationCopyRights(authRef, &rights, nil, flags, nil) == errAuthorizationSuccess
            }
        }
    }

    private func startWithAuthorizationServices(allowInteraction: Bool) -> Bool {
        guard let executable = Bundle.main.executablePath, !executable.isEmpty else {
            return false
        }
        guard obtainRights(allowInteraction: allowInteraction) else {
            return false
        }
        guard let authRef else { return false }
        guard let exec = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "AuthorizationExecuteWithPrivileges") else {
            return false
        }
        let execute = unsafeBitCast(exec, to: AuthorizationExecuteWithPrivilegesProc.self)

        let socketPath = SMCHelperService.socketPath
        let uid = String(getuid())
        let parent = String(getpid())
        let args = [
            "--smc-helper",
            "--foreground",
            "--socket", socketPath,
            "--uid", uid,
            "--parent-pid", parent
        ]

        let cStrings: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        defer {
            cStrings.dropLast().compactMap { $0 }.forEach { free($0) }
        }

        if let previous = communicationsPipe {
            fclose(previous)
            communicationsPipe = nil
        }

        var pipe: UnsafeMutablePointer<FILE>?
        var argv = cStrings
        let status: OSStatus = executable.withCString { path in
            argv.withUnsafeMutableBufferPointer { buffer in
                execute(authRef, path, [], buffer.baseAddress, &pipe)
            }
        }
        if status == errAuthorizationSuccess {
            communicationsPipe = pipe
            return true
        }
        if let pipe {
            fclose(pipe)
        }
        return false
    }

    private func startWithAppleScript() -> Bool {
        guard let executable = Bundle.main.executablePath, !executable.isEmpty else {
            return false
        }
        let uid = getuid()
        let parent = getpid()
        let perl = """
        use POSIX qw(setsid); exit 0 if fork; setsid(); exit 0 if fork; chdir "/"; exec @ARGV
        """
        let shell = [
            "/usr/bin/perl",
            "-e",
            posixQuoted(perl),
            posixQuoted(executable),
            "--smc-helper",
            "--foreground",
            "--socket", posixQuoted(SMCHelperService.socketPath),
            "--uid", String(uid),
            "--parent-pid", String(parent)
        ].joined(separator: " ")
        let source = "do shell script \(appleScriptQuoted(shell)) with administrator privileges"
        NSApp.activate(ignoringOtherApps: true)
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return false }
        _ = script.executeAndReturnError(&error)
        return error == nil
    }
}

private typealias AuthorizationExecuteWithPrivilegesProc = @convention(c) (
    AuthorizationRef,
    UnsafePointer<CChar>,
    AuthorizationFlags,
    UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
    UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
) -> OSStatus

enum SMCHelperServer {
    static func run() {
        signal(SIGPIPE, SIG_IGN)

        let socketPath = argumentValue("socket") ?? SMCHelperService.socketPath
        let parentPid = argumentValue("parent-pid").flatMap(Int32.init) ?? 0
        let clientUID = argumentValue("uid").flatMap { uid_t($0) } ?? getuid()
        let logURL = URL(fileURLWithPath: "/tmp/thermometer-smc-\(clientUID).log")

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
        chmod(socketPath, 0o600)
        let groupID = getpwuid(clientUID)?.pointee.pw_gid ?? 20
        chown(socketPath, clientUID, groupID)
        log("listening")

        let reader = HardwareSensorReader()
        var running = true

        func restoreAndExit() {
            log("restore and exit")
            reader.restoreAutomaticFans(fanCount: 8)
            unlink(socketPath)
            close(fd)
            running = false
        }

        while running {
            if parentPid > 0, kill(parentPid, 0) != 0 {
                restoreAndExit()
                break
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
    }

    private static func argumentValue(_ name: String) -> String? {
        let flag = "--\(name)"
        guard let index = CommandLine.arguments.firstIndex(of: flag),
              index + 1 < CommandLine.arguments.count else {
            return nil
        }
        return CommandLine.arguments[index + 1]
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
