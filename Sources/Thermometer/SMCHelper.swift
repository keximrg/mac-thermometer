import Darwin
import Foundation
import AppKit

enum SMCHelperService {
    static var socketPath: String {
        "/tmp/thermometer-smc-\(getuid()).sock"
    }

    static func isRunning() -> Bool {
        ping() != nil
    }

    @discardableResult
    static func ping() -> Bool? {
        switch send(SMCHelperRequest(cmd: "ping")) {
        case .success(let response):
            return response.ok
        case .failure:
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
    }

    static func authorizeAndStart() -> Bool {
        if isRunning() {
            return true
        }
        guard let executable = Bundle.main.executablePath, !executable.isEmpty else {
            return false
        }

        let uid = getuid()
        let parent = getpid()
        let quotedExecutable = posixQuoted(executable)
        let quotedSocket = posixQuoted(socketPath)
        let shell = "nohup \(quotedExecutable) --smc-helper --socket \(quotedSocket) --uid \(uid) --parent-pid \(parent) >/dev/null 2>&1 &"
        let source = "do shell script \(appleScriptQuoted(shell)) with administrator privileges"
        NSApp.activate(ignoringOtherApps: true)
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            return false
        }
        _ = script.executeAndReturnError(&error)
        if error != nil {
            return false
        }

        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            if isRunning() {
                return true
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
        return isRunning()
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

    private static func posixQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptQuoted(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        + "\""
    }
}

enum SMCHelperServer {
    static func run() {
        signal(SIGPIPE, SIG_IGN)

        let arguments = CommandLine.arguments
        let socketPath = argumentValue("socket") ?? SMCHelperService.socketPath
        let parentPid = argumentValue("parent-pid").flatMap(Int32.init) ?? 0
        let clientUID = argumentValue("uid").flatMap { uid_t($0) } ?? getuid()

        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)

        var addr = unixAddress(socketPath)
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            close(fd)
            return
        }
        chmod(socketPath, 0o600)
        let groupID = getpwuid(clientUID)?.pointee.pw_gid ?? 20
        chown(socketPath, clientUID, groupID)

        let reader = HardwareSensorReader()
        var running = true

        func restoreAndExit() {
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
                usleep(200_000)
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
                _ = writeLine(to: client, SMCHelperResponse(ok: true))

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
                var encodedTargets: [String: Double] = [:]
                outcome.targets.forEach { encodedTargets[String($0.key)] = $0.value }
                _ = writeLine(
                    to: client,
                    SMCHelperResponse(
                        ok: outcome.error == nil,
                        needsPrivilege: outcome.needsPrivilege,
                        error: outcome.error,
                        targets: encodedTargets
                    )
                )

            case "restore":
                reader.restoreAutomaticFans(fanCount: request.fanCount ?? 8)
                _ = writeLine(to: client, SMCHelperResponse(ok: true))

            case "quit":
                _ = writeLine(to: client, SMCHelperResponse(ok: true))
                restoreAndExit()

            default:
                _ = writeLine(to: client, SMCHelperResponse(ok: false, error: "unknown command"))
            }
        }

        _ = arguments
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

private struct SMCHelperRequest: Codable {
    var cmd: String
    var mode: String?
    var manualPercent: Double?
    var curveStartC: Double?
    var curveFullC: Double?
    var fanCount: Int?
}

private struct SMCHelperResponse: Codable {
    var ok: Bool
    var needsPrivilege: Bool?
    var error: String?
    var targets: [String: Double]?
}

private enum SMCHelperError: Error {
    case connect
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
