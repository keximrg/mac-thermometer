import Darwin
import Foundation
import IOKit
import IOKit.hidsystem

// Kept here until the shared UI models are introduced. Fan support is determined
// by FNum, so a valid zero RPM reading is intentionally preserved.
struct FanReading: Identifiable, Hashable, Sendable {
    let index: Int
    let name: String
    let rpm: Double
    let minRPM: Double?
    let maxRPM: Double?

    var id: Int { index }
}

struct RawSensorSnapshot: Sendable {
    let cpuC: Double?
    let gpuC: Double?
    let storageC: Double?
    let batteryC: Double?
    let fans: [FanReading]
    let sensorCount: Int
    let sourceSummary: String
    let fanControlAvailable: Bool
}

struct FanControlOutcome: Sendable {
    let targets: [Int: Double]
    let error: String?
    let needsPrivilege: Bool

    init(targets: [Int: Double], error: String?, needsPrivilege: Bool = false) {
        self.targets = targets
        self.error = error
        self.needsPrivilege = needsPrivilege
    }
}

enum SMCWriteStatus: Equatable {
    case success
    case acceptedWithWarning
    case notPrivileged
    case missingKey
    case rejected(UInt8)
    case failed

    var succeeded: Bool {
        self == .success || self == .acceptedWithWarning
    }
}

final class HardwareSensorReader {
    private let lock = NSLock()
    private let smc: SMCReader?
    private let hid: HIDTemperatureReader
    private let family: ChipFamily
    private var lastDiagnostics: [String]
    private var softwareOwnsFans = false
    private var resolvedModeKeys: [Int: String] = [:]
    private var ftstIsHeld = false

    init() {
        let smc = SMCReader()
        let hid = HIDTemperatureReader()

        self.smc = smc
        self.hid = hid
        self.family = ChipFamily.detect(using: smc)
        let smcServiceName = smc?.serviceName ?? "unavailable"
        self.lastDiagnostics = [
            "Chip family: \(self.family.rawValue)",
            "SMC parameter stride: \(MemoryLayout<SMCParamStruct>.stride)",
            "SMC service: \(smcServiceName)",
            "HID backend: \(hid.status)"
        ]
    }

    func sample() -> RawSensorSnapshot {
        lock.lock()
        defer { lock.unlock() }

        let hidReadings = hid.readTemperatures()

        var cpu = averageSMC(keys: family.cpuKeys, source: "SMC \(family.rawValue) CPU")
        if cpu == nil {
            cpu = firstSMC(
                keys: ["TCMb", "TCMz", "TCAD", "TC0D", "TC0P", "TPMP"],
                source: "SMC CPU fallback"
            )
        }
        if cpu == nil {
            cpu = averageHID(
                hidReadings,
                source: "HID CPU",
                matching: { name in
                    name.hasPrefix("pACC MTR Temp Sensor") ||
                        name.hasPrefix("eACC MTR Temp Sensor")
                }
            )
        }

        var gpu = averageSMC(keys: family.gpuKeys, source: "SMC \(family.rawValue) GPU")
        if gpu == nil {
            gpu = firstSMC(
                keys: ["TRDX", "TG0D", "TGDD", "TG0P", "TCGC"],
                source: "SMC GPU fallback"
            )
        }
        if gpu == nil {
            gpu = averageHID(
                hidReadings,
                source: "HID GPU",
                matching: { $0.hasPrefix("GPU MTR Temp Sensor") }
            )
        }

        var storage = averageHID(
            hidReadings,
            source: "HID NAND",
            matching: { name in
                name.hasPrefix("NAND CH") && name.hasSuffix(" temp")
            }
        )
        if storage == nil {
            storage = firstSMC(
                keys: [
                    "TH0x", "TH0A", "TH0B", "TH0C", "T5SP",
                    "Ts1P", "TsOP", "Tm0P", "Ts0P"
                ],
                source: "SMC storage fallback"
            )
        }

        var battery = averageSMC(
            keys: ["TB0T", "TB1T", "TB2T"],
            source: "SMC battery"
        )
        if battery == nil {
            battery = readSmartBatteryTemperature()
        }
        if battery == nil {
            battery = averageHID(
                hidReadings,
                source: "HID battery",
                matching: { $0 == "gas gauge battery" }
            )
        }

        let fanResult = readFans()
        let metrics = [cpu, gpu, storage, battery].compactMap { $0 }
        let sensorCount = metrics.reduce(0) { $0 + $1.count } + fanResult.fans.count

        var sources = metrics.map(\.source)
        if let fanCount = fanResult.reportedCount {
            sources.append("SMC fans \(fanCount)")
        }
        if sources.isEmpty {
            sources = ["No readable hardware sensors"]
        }

        let smcServiceName = smc?.serviceName ?? "unavailable"
        let reportedFanCount = fanResult.reportedCount.map(String.init) ?? "unavailable"
        var diagnostics = [
            "Chip family: \(family.rawValue)",
            "SMC parameter stride: \(MemoryLayout<SMCParamStruct>.stride)",
            "SMC service: \(smcServiceName)",
            "HID backend: \(hid.status)",
            "HID valid temperature services: \(hidReadings.count)"
        ]
        diagnostics.append(contentsOf: diagnosticLine(label: "CPU", metric: cpu))
        diagnostics.append(contentsOf: diagnosticLine(label: "GPU", metric: gpu))
        diagnostics.append(contentsOf: diagnosticLine(label: "Storage", metric: storage))
        diagnostics.append(contentsOf: diagnosticLine(label: "Battery", metric: battery))
        diagnostics.append("Fans reported by FNum: \(reportedFanCount)")
        diagnostics.append("SMC write service: \(smc?.writeServiceName ?? "unavailable")")
        diagnostics.append(
            "Fan control keys: F0Tg=\(smc?.hasKey("F0Tg") == true), F0md=\(smc?.hasKey("F0md") == true), F0Md=\(smc?.hasKey("F0Md") == true), FS!=\(smc?.hasKey("FS! ") == true), Ftst=\(smc?.hasKey("Ftst") == true)"
        )
        if let modeKey = modeKeyLocked(for: 0) {
            let modeValue = smc?.readUnsigned(modeKey).map(String.init) ?? "unreadable"
            diagnostics.append("Fan 0 mode key \(modeKey)=\(modeValue)")
        }
        diagnostics.append(contentsOf: fanResult.fans.map { fan in
            let limits: String
            if let minimum = fan.minRPM, let maximum = fan.maxRPM {
                limits = String(format: " (min %.0f, max %.0f)", minimum, maximum)
            } else {
                limits = ""
            }
            return String(format: "Fan %d: %.0f RPM%@", fan.index, fan.rpm, limits)
        })
        lastDiagnostics = diagnostics

        return RawSensorSnapshot(
            cpuC: cpu?.value,
            gpuC: gpu?.value,
            storageC: storage?.value,
            batteryC: battery?.value,
            fans: fanResult.fans,
            sensorCount: sensorCount,
            sourceSummary: sources.joined(separator: ", "),
            fanControlAvailable: canControlFansLocked(fanCount: fanResult.fans.count)
        )
    }

    func applyFanControl(
        mode: FanControlMode,
        manualPercent: Double,
        curveStartC: Double,
        curveFullC: Double,
        controlTemperature: Double?,
        fans: [FanReading]
    ) -> FanControlOutcome {
        lock.lock()
        defer { lock.unlock() }
        return applyFanControlLocked(
            mode: mode,
            manualPercent: manualPercent,
            curveStartC: curveStartC,
            curveFullC: curveFullC,
            controlTemperature: controlTemperature,
            fans: fans
        )
    }

    func restoreAutomaticFans(fanCount: Int? = nil) {
        lock.lock()
        defer { lock.unlock() }
        restoreAutomaticFansLocked(fanCount: fanCount)
    }

    func diagnosticLines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lastDiagnostics
    }

    private func averageSMC(keys: [String], source: String) -> MetricReading? {
        guard let smc, !keys.isEmpty else { return nil }

        let values = keys.compactMap { key -> NamedTemperature? in
            guard let value = smc.readTemperature(key) else { return nil }
            return NamedTemperature(name: key, value: value)
        }
        return MetricReading.average(values, source: source)
    }

    private func firstSMC(keys: [String], source: String) -> MetricReading? {
        guard let smc else { return nil }

        for key in keys {
            if let value = smc.readTemperature(key) {
                return MetricReading(
                    value: value,
                    count: 1,
                    source: "\(source) [\(key)]",
                    details: [NamedTemperature(name: key, value: value)]
                )
            }
        }
        return nil
    }

    private func averageHID(
        _ readings: [NamedTemperature],
        source: String,
        matching predicate: (String) -> Bool
    ) -> MetricReading? {
        MetricReading.average(readings.filter { predicate($0.name) }, source: source)
    }

    private func readFans() -> (fans: [FanReading], reportedCount: Int?) {
        guard let smc, let rawCount = smc.readUnsigned("FNum") else {
            return ([], nil)
        }

        // The upper bound prevents malformed SMC data from creating a large loop.
        let fanCount = min(max(Int(rawCount), 0), 16)
        var fans: [FanReading] = []
        fans.reserveCapacity(fanCount)

        for index in 0..<fanCount {
            // Zero is a valid reading on Apple Silicon when a fan is stopped.
            guard let rpm = smc.readNumber("F\(index)Ac"), rpm >= 0, rpm <= 30_000 else {
                continue
            }

            let minimum = smc.readNumber("F\(index)Mn").flatMap {
                (0...30_000).contains($0) ? $0 : nil
            }
            let maximum = smc.readNumber("F\(index)Mx").flatMap {
                (0...30_000).contains($0) ? $0 : nil
            }
            fans.append(
                FanReading(
                    index: index,
                    name: fanCount == 1 ? "Fan" : "Fan \(index + 1)",
                    rpm: rpm,
                    minRPM: minimum,
                    maxRPM: maximum
                )
            )
        }
        return (fans, fanCount)
    }

    private func canControlFansLocked(fanCount: Int) -> Bool {
        guard let smc, fanCount > 0 else { return false }
        return smc.hasKey("F0Tg")
            || modeKeyLocked(for: 0) != nil
            || smc.hasKey("FS! ")
            || smc.hasKey("Ftst")
    }

    private func modeKeyLocked(for index: Int) -> String? {
        if let cached = resolvedModeKeys[index] {
            return cached
        }
        guard let smc else { return nil }
        for suffix in ["md", "Md"] {
            let key = "F\(index)\(suffix)"
            if smc.hasKey(key) {
                resolvedModeKeys[index] = key
                return key
            }
        }
        return nil
    }

    private func applyFanControlLocked(
        mode: FanControlMode,
        manualPercent: Double,
        curveStartC: Double,
        curveFullC: Double,
        controlTemperature: Double?,
        fans: [FanReading]
    ) -> FanControlOutcome {
        let available = canControlFansLocked(fanCount: fans.count)
        guard available else {
            return FanControlOutcome(
                targets: [:],
                error: fans.isEmpty ? nil : "当前机型不支持软件调节风扇"
            )
        }

        switch mode {
        case .system:
            if softwareOwnsFans {
                restoreAutomaticFansLocked(fanCount: max(fans.count, 1))
            }
            return FanControlOutcome(targets: [:], error: nil)

        case .manual, .temperature:
            let percent: Double
            if mode == .manual {
                percent = manualPercent.clamped(to: 0...1)
            } else {
                guard let temperature = controlTemperature else {
                    restoreAutomaticFansLocked(fanCount: max(fans.count, 1))
                    return FanControlOutcome(
                        targets: [:],
                        error: "缺少芯片温度，已交还系统控制"
                    )
                }
                let start = curveStartC.clamped(to: 35...90)
                let full = max(curveFullC, start + 1)
                if temperature <= start {
                    percent = 0
                } else if temperature >= full {
                    percent = 1
                } else {
                    percent = (temperature - start) / (full - start)
                }
            }

            guard let smc else {
                return FanControlOutcome(
                    targets: [:],
                    error: "无法连接 SMC"
                )
            }

            var targets: [Int: Double] = [:]
            var anySuccess = false
            var lastFailure: String?
            var needsPrivilege = false

            for fan in fans {
                let minimum = fan.minRPM ?? 0
                let maximum = fan.maxRPM ?? max(fan.rpm, 4_000)
                let ceiling = max(maximum, minimum)
                let target = (minimum + percent * (ceiling - minimum)).clamped(to: minimum...ceiling)
                let modeStatus = setFanForcedLocked(fan.index, forced: true)
                if modeStatus == .notPrivileged {
                    needsPrivilege = true
                    lastFailure = "需要管理员权限才能调节风扇"
                    continue
                }

                let targetKey = "F\(fan.index)Tg"
                let wrote = smc.writeNumberStatus(targetKey, target)
                if wrote == .notPrivileged {
                    needsPrivilege = true
                    lastFailure = "需要管理员权限才能调节风扇"
                    continue
                }

                if modeStatus.succeeded || wrote.succeeded {
                    anySuccess = true
                    targets[fan.index] = target
                } else {
                    lastFailure = "无法写入风扇 \(fan.index + 1) 的转速"
                }
            }

            if !anySuccess {
                return FanControlOutcome(
                    targets: [:],
                    error: lastFailure ?? "风扇转速写入失败",
                    needsPrivilege: needsPrivilege
                )
            }
            softwareOwnsFans = true
            return FanControlOutcome(targets: targets, error: nil)
        }
    }

    private func restoreAutomaticFansLocked(fanCount: Int?) {
        guard let smc else { return }
        let count = min(max(fanCount ?? 8, 1), 16)
        for index in 0..<count {
            _ = setFanForcedLocked(index, forced: false)
        }
        if smc.hasKey("FS! ") {
            _ = smc.writeNumber("FS! ", 0)
        }
        if ftstIsHeld || smc.hasKey("Ftst") {
            _ = smc.writeNumber("Ftst", 0)
            ftstIsHeld = false
        }
        softwareOwnsFans = false
    }

    @discardableResult
    private func setFanForcedLocked(_ index: Int, forced: Bool) -> SMCWriteStatus {
        guard let smc else { return .failed }
        var statuses: [SMCWriteStatus] = []

        if let modeKey = modeKeyLocked(for: index) {
            let desired = forced ? 1.0 : 0.0
            var status = smc.writeNumberStatus(modeKey, desired)
            if forced, !status.succeeded, status != .notPrivileged, smc.hasKey("Ftst") {
                let unlock = smc.writeNumberStatus("Ftst", 1)
                if unlock == .notPrivileged {
                    return .notPrivileged
                }
                if unlock.succeeded {
                    ftstIsHeld = true
                    Thread.sleep(forTimeInterval: 0.5)
                    let deadline = Date().addingTimeInterval(8)
                    while Date() < deadline {
                        status = smc.writeNumberStatus(modeKey, desired)
                        if status.succeeded || status == .notPrivileged {
                            break
                        }
                        Thread.sleep(forTimeInterval: 0.1)
                    }
                }
            }
            statuses.append(status)
        }

        if smc.hasKey("FS! ") {
            let bitStatus: SMCWriteStatus
            if let current = smc.readUnsigned("FS! ") {
                let mask: UInt64 = 1 << index
                let next = forced ? (current | mask) : (current & ~mask)
                bitStatus = smc.writeNumberStatus("FS! ", Double(next))
            } else if !forced {
                bitStatus = smc.writeNumberStatus("FS! ", 0)
            } else {
                bitStatus = .failed
            }
            statuses.append(bitStatus)
        }

        if statuses.contains(.notPrivileged) {
            return .notPrivileged
        }
        if statuses.contains(where: \.succeeded) {
            return .success
        }
        return statuses.last ?? .missingKey
    }

    private func readSmartBatteryTemperature() -> MetricReading? {
        guard let matching = IOServiceMatching("AppleSmartBattery") else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        // VirtualTemperature follows the SMC battery sensors more closely on
        // current Apple Silicon hardware. Both properties are centi-degrees C.
        for propertyName in ["VirtualTemperature", "Temperature"] {
            guard let unmanaged = IORegistryEntryCreateCFProperty(
                service,
                propertyName as CFString,
                kCFAllocatorDefault,
                IOOptionBits(0)
            ) else {
                continue
            }
            let object = unmanaged.takeRetainedValue()
            guard let number = object as? NSNumber else { continue }

            let rawValue = number.doubleValue
            let value = rawValue > 200 ? rawValue / 100.0 : rawValue
            guard Self.isValidTemperature(value) else { continue }

            let detail = NamedTemperature(name: "AppleSmartBattery.\(propertyName)", value: value)
            return MetricReading(
                value: value,
                count: 1,
                source: "IORegistry battery [\(propertyName)]",
                details: [detail]
            )
        }
        return nil
    }

    private func diagnosticLine(label: String, metric: MetricReading?) -> [String] {
        guard let metric else { return ["\(label): unavailable"] }
        let values = metric.details
            .map { String(format: "%@=%.2f°C", $0.name, $0.value) }
            .joined(separator: ", ")
        return [
            String(format: "%@ aggregate: %.2f°C via %@", label, metric.value, metric.source),
            "\(label) inputs: \(values)"
        ]
    }

    fileprivate static func isValidTemperature(_ value: Double) -> Bool {
        value.isFinite && value > 0 && value <= 125
    }
}

private struct NamedTemperature {
    let name: String
    let value: Double
}

private struct MetricReading {
    let value: Double
    let count: Int
    let source: String
    let details: [NamedTemperature]

    static func average(_ values: [NamedTemperature], source: String) -> MetricReading? {
        guard !values.isEmpty else { return nil }
        let total = values.reduce(0.0) { $0 + $1.value }
        return MetricReading(
            value: total / Double(values.count),
            count: values.count,
            source: "\(source) (\(values.count))",
            details: values
        )
    }
}

private enum ChipFamily: String {
    case intel = "Intel"
    case m1 = "Apple M1"
    case m2 = "Apple M2"
    case m3 = "Apple M3"
    case m4 = "Apple M4"
    case m5 = "Apple M5"
    case appleUnknown = "Apple Silicon"

    static func detect(using smc: SMCReader?) -> ChipFamily {
        #if arch(x86_64)
        return .intel
        #else
        let brand = sysctlString("machdep.cpu.brand_string")?.lowercased() ?? ""
        if brand.contains("m5") { return .m5 }
        if brand.contains("m4") { return .m4 }
        if brand.contains("m3") { return .m3 }
        if brand.contains("m2") { return .m2 }
        if brand.contains("m1") { return .m1 }

        // Some restricted process environments hide machdep.cpu.brand_string.
        // Probe generation-specific read-only keys in newest-first order.
        if smc?.readTemperature("Tp00") != nil, smc?.readTemperature("Tg0U") != nil {
            return .m5
        }
        if smc?.readTemperature("Tp0V") != nil || smc?.readTemperature("Tg0G") != nil {
            return .m4
        }
        if smc?.readTemperature("Tf04") != nil, smc?.readTemperature("Tf14") != nil {
            return .m3
        }
        if smc?.readTemperature("Tp1h") != nil || smc?.readTemperature("Tg0f") != nil {
            return .m2
        }
        if smc?.readTemperature("Tg05") != nil || smc?.readTemperature("Tp0T") != nil {
            return .m1
        }
        return .appleUnknown
        #endif
    }

    var cpuKeys: [String] {
        switch self {
        case .intel:
            return [
                "TC0D", "TC0E", "TC0F", "TC0H", "TC0P", "TCAD",
                "TC0C", "TC1C", "TC2C", "TC3C", "TC4C", "TC5C",
                "TC6C", "TC7C", "TC8C", "TC9C", "TCAC", "TCBC"
            ]
        case .m1:
            return [
                "Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H",
                "Tp0L", "Tp0P", "Tp0X", "Tp0b"
            ]
        case .m2:
            return [
                "Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05",
                "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"
            ]
        case .m3:
            return [
                "Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09",
                "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49",
                "Tf4A", "Tf4B", "Tf4D", "Tf4E"
            ]
        case .m4:
            return [
                "Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05",
                "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"
            ]
        case .m5:
            return [
                "Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K",
                "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d",
                "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"
            ]
        case .appleUnknown:
            return []
        }
    }

    var gpuKeys: [String] {
        switch self {
        case .intel:
            return ["TCGC", "TG0D", "TGDD", "TG0H", "TG0P"]
        case .m1:
            return ["Tg05", "Tg0D", "Tg0L", "Tg0T"]
        case .m2:
            return ["Tg0f", "Tg0j"]
        case .m3:
            return ["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"]
        case .m4:
            return ["Tg0G", "Tg0H", "Tg1U", "Tg1k", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"]
        case .m5:
            return ["Tg0U", "Tg0X", "Tg0d", "Tg0g", "Tg0j", "Tg1Y", "Tg1c", "Tg1g"]
        case .appleUnknown:
            return []
        }
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        let sizeResult = name.withCString { sysctlbyname($0, nil, &size, nil, 0) }
        guard sizeResult == 0, size > 1 else { return nil }

        var buffer = [CChar](repeating: 0, count: size)
        let valueResult = buffer.withUnsafeMutableBytes { rawBuffer in
            name.withCString {
                sysctlbyname($0, rawBuffer.baseAddress, &size, nil, 0)
            }
        }
        guard valueResult == 0 else { return nil }
        return String(cString: buffer)
    }
}

// MARK: - SMC

private typealias SMCBytes32 = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

private struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

/// Binary-compatible with the 80-byte AppleSMC userspace request structure.
private struct SMCParamStruct {
    var key: UInt32 = 0
    var version = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()

    // Swift may otherwise reuse the nested KeyInfo tail padding. This field
    // keeps result at byte 40 and the byte payload at byte 48.
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes32 = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )
}

private struct SMCValue {
    let type: String
    let bytes: [UInt8]
}

private final class SMCReader {
    private static let kernelSelector: UInt32 = 2
    private static let readBytesCommand: UInt8 = 5
    private static let writeBytesCommand: UInt8 = 6
    private static let readKeyInfoCommand: UInt8 = 9
    private static let smcKeyNotWritable: UInt8 = 0x87
    private static let notPrivileged = Int32(bitPattern: 0xE00002C2)
    private static let notPermitted = Int32(bitPattern: 0xE00002C1)

    private var connection: io_connect_t = 0
    private var writeConnection: io_connect_t = 0
    private var keyInfoCache: [String: SMCKeyInfoData] = [:]
    private var missingKeys = Set<String>()
    private(set) var serviceName = "unavailable"
    private(set) var writeServiceName = "unavailable"

    init?() {
        guard MemoryLayout<SMCParamStruct>.stride == 80 else { return nil }

        for candidate in ["AppleSMCKeysEndpoint", "AppleSMC"] {
            let conn = Self.openNamedService(candidate)
            guard conn != 0 else { continue }
            connection = conn
            serviceName = candidate
            break
        }
        guard connection != 0 else { return nil }

        if serviceName == "AppleSMC" {
            writeConnection = connection
            writeServiceName = serviceName
        } else {
            let appleSMC = Self.openNamedService("AppleSMC")
            if appleSMC != 0 {
                writeConnection = appleSMC
                writeServiceName = "AppleSMC"
            } else {
                writeConnection = connection
                writeServiceName = serviceName
            }
        }
    }

    deinit {
        if writeConnection != 0, writeConnection != connection {
            IOServiceClose(writeConnection)
        }
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    private static func openNamedService(_ name: String) -> io_connect_t {
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching(name),
              IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess
        else {
            return 0
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            var conn: io_connect_t = 0
            let result = IOServiceOpen(service, mach_task_self_, 0, &conn)
            IOObjectRelease(service)
            if result == kIOReturnSuccess, conn != 0 {
                return conn
            }
            service = IOIteratorNext(iterator)
        }
        return 0
    }

    func readTemperature(_ key: String) -> Double? {
        guard let value = readNumber(key), HardwareSensorReader.isValidTemperature(value) else {
            return nil
        }
        return value
    }

    func readNumber(_ key: String) -> Double? {
        guard let value = readValue(key) else { return nil }
        return Self.decodeNumber(value)
    }

    func readUnsigned(_ key: String) -> UInt64? {
        guard let value = readValue(key) else { return nil }
        switch value.type {
        case "ui8 ":
            return value.bytes.first.map(UInt64.init)
        case "ui16":
            guard value.bytes.count >= 2 else { return nil }
            return UInt64(Self.bigEndianUInt16(value.bytes))
        case "ui32":
            guard value.bytes.count >= 4 else { return nil }
            return UInt64(Self.bigEndianUInt32(value.bytes))
        default:
            guard let decoded = Self.decodeNumber(value), decoded >= 0 else { return nil }
            return UInt64(decoded.rounded())
        }
    }

    func hasKey(_ key: String) -> Bool {
        fetchKeyInfo(key) != nil
    }

    @discardableResult
    func writeNumber(_ key: String, _ value: Double) -> Bool {
        writeNumberStatus(key, value).succeeded
    }

    func writeNumberStatus(_ key: String, _ value: Double) -> SMCWriteStatus {
        guard let info = fetchKeyInfo(key) else { return .missingKey }
        let type = Self.fourCharacterString(info.dataType)
        let size = Int(info.dataSize)
        guard size > 0, size <= 32,
              var payload = Self.encodeNumber(value, type: type) else {
            return .failed
        }
        if payload.count < size {
            payload.append(contentsOf: repeatElement(0, count: size - payload.count))
        } else if payload.count > size {
            payload = Array(payload.prefix(size))
        }
        return writeBytes(key, payload, info: info)
    }

    private func fetchKeyInfo(_ key: String) -> SMCKeyInfoData? {
        guard key.utf8.count == 4 else { return nil }
        if let cached = keyInfoCache[key] {
            return cached
        }
        if missingKeys.contains(key) {
            return nil
        }

        var input = SMCParamStruct()
        input.key = Self.fourCharacterCode(key)
        input.data8 = Self.readKeyInfoCommand
        let (output, kernResult) = call(input, connection: connection)
        guard kernResult == kIOReturnSuccess, let output, output.result == 0,
              output.keyInfo.dataSize > 0, output.keyInfo.dataSize <= 32 else {
            missingKeys.insert(key)
            return nil
        }
        keyInfoCache[key] = output.keyInfo
        return output.keyInfo
    }

    private func writeBytes(_ key: String, _ data: [UInt8], info: SMCKeyInfoData) -> SMCWriteStatus {
        var input = SMCParamStruct()
        input.key = Self.fourCharacterCode(key)
        input.keyInfo = info
        input.keyInfo.dataSize = UInt32(data.count)
        input.data8 = Self.writeBytesCommand
        input.bytes = Self.packBytes(data)
        let (output, kernResult) = call(input, connection: writeConnection)
        if Self.isPrivilegeError(kernResult) {
            return .notPrivileged
        }
        guard let output, kernResult == kIOReturnSuccess else { return .failed }
        if output.result == 0 {
            return .success
        }
        // Some Apple Silicon machines apply target writes despite 0x87.
        if output.result == Self.smcKeyNotWritable, key.hasSuffix("Tg") {
            return .acceptedWithWarning
        }
        return .rejected(output.result)
    }

    private func readValue(_ key: String) -> SMCValue? {
        guard let keyInfo = fetchKeyInfo(key) else { return nil }

        var input = SMCParamStruct()
        input.key = Self.fourCharacterCode(key)
        input.keyInfo.dataSize = keyInfo.dataSize
        input.data8 = Self.readBytesCommand

        let (output, kernResult) = call(input, connection: connection)
        guard let output, kernResult == kIOReturnSuccess, output.result == 0 else { return nil }
        let bytes = withUnsafeBytes(of: output.bytes) {
            Array($0.prefix(Int(keyInfo.dataSize)))
        }
        return SMCValue(type: Self.fourCharacterString(keyInfo.dataType), bytes: bytes)
    }

    private func call(_ request: SMCParamStruct, connection: io_connect_t) -> (SMCParamStruct?, kern_return_t) {
        var input = request
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride

        let result = IOConnectCallStructMethod(
            connection,
            Self.kernelSelector,
            &input,
            MemoryLayout<SMCParamStruct>.stride,
            &output,
            &outputSize
        )
        guard result == kIOReturnSuccess, outputSize >= MemoryLayout<SMCParamStruct>.size else {
            return (nil, result)
        }
        return (output, result)
    }

    private static func isPrivilegeError(_ result: kern_return_t) -> Bool {
        result == notPrivileged || result == notPermitted
    }

    private static func encodeNumber(_ value: Double, type: String) -> [UInt8]? {
        switch type {
        case "flt ", "flt":
            var bits = Float(value).bitPattern
            return withUnsafeBytes(of: &bits) { Array($0) }
        case "fpe2":
            let scaled = UInt16(clamping: Int((value * 4).rounded()))
            return [UInt8(scaled >> 8), UInt8(scaled & 0xff)]
        case "ui8 ", "flag":
            return [UInt8(clamping: Int(value.rounded()))]
        case "ui16":
            let raw = UInt16(clamping: Int(value.rounded()))
            return [UInt8(raw >> 8), UInt8(raw & 0xff)]
        case "ui32":
            let raw = UInt32(clamping: Int(value.rounded()))
            return [
                UInt8((raw >> 24) & 0xff),
                UInt8((raw >> 16) & 0xff),
                UInt8((raw >> 8) & 0xff),
                UInt8(raw & 0xff)
            ]
        default:
            return nil
        }
    }

    private static func packBytes(_ data: [UInt8]) -> SMCBytes32 {
        var packed: SMCBytes32 = (
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0
        )
        withUnsafeMutableBytes(of: &packed) { buffer in
            for (index, byte) in data.prefix(32).enumerated() {
                buffer[index] = byte
            }
        }
        return packed
    }

    private static func decodeNumber(_ value: SMCValue) -> Double? {
        let bytes = value.bytes
        switch value.type {
        case "flt ", "flt":
            guard bytes.count >= 4 else { return nil }
            var bits: UInt32 = 0
            withUnsafeMutableBytes(of: &bits) { destination in
                destination.copyBytes(from: bytes.prefix(4))
            }
            return Double(Float(bitPattern: bits))
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            let raw = Int16(bitPattern: bigEndianUInt16(bytes))
            return Double(raw) / 256.0
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            return Double(bigEndianUInt16(bytes)) / 4.0
        case "ui8 ":
            return bytes.first.map(Double.init)
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double(bigEndianUInt16(bytes))
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            return Double(bigEndianUInt32(bytes))
        default:
            return nil
        }
    }

    private static func bigEndianUInt16(_ bytes: [UInt8]) -> UInt16 {
        (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
    }

    private static func bigEndianUInt32(_ bytes: [UInt8]) -> UInt32 {
        (UInt32(bytes[0]) << 24) |
            (UInt32(bytes[1]) << 16) |
            (UInt32(bytes[2]) << 8) |
            UInt32(bytes[3])
    }

    private static func fourCharacterCode(_ string: String) -> UInt32 {
        string.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func fourCharacterString(_ value: UInt32) -> String {
        String(
            bytes: [
                UInt8((value >> 24) & 0xff),
                UInt8((value >> 16) & 0xff),
                UInt8((value >> 8) & 0xff),
                UInt8(value & 0xff)
            ],
            encoding: .ascii
        ) ?? "????"
    }
}

// MARK: - HID temperature services

@objc private protocol ThermometerHIDEvent: NSObjectProtocol {}

private typealias HIDCreateFunction = @convention(c) (CFAllocator?) -> Unmanaged<IOHIDEventSystemClient>?
private typealias HIDSetMatchingFunction = @convention(c) (
    IOHIDEventSystemClient?,
    CFDictionary?
) -> Void
private typealias HIDCopyEventFunction = @convention(c) (
    IOHIDServiceClient?,
    Int64,
    Int32,
    Int64
) -> Unmanaged<ThermometerHIDEvent>?
private typealias HIDGetFloatFunction = @convention(c) (
    ThermometerHIDEvent?,
    UInt32
) -> Double

private final class HIDTemperatureReader {
    private static let temperatureEventType: Int64 = 15
    private static let temperatureLevelField: UInt32 = 0x000f_0000

    private var frameworkHandle: UnsafeMutableRawPointer?
    private var client: IOHIDEventSystemClient?
    private var copyEvent: HIDCopyEventFunction?
    private var getFloatValue: HIDGetFloatFunction?
    private(set) var status = "unavailable"

    init() {
        let frameworkPath = "/System/Library/Frameworks/IOKit.framework/IOKit"
        guard let handle = dlopen(frameworkPath, RTLD_LAZY | RTLD_LOCAL) else {
            status = "IOKit dlopen failed"
            return
        }
        frameworkHandle = handle

        guard let createSymbol = dlsym(handle, "IOHIDEventSystemClientCreate"),
              let matchingSymbol = dlsym(handle, "IOHIDEventSystemClientSetMatching"),
              let copyEventSymbol = dlsym(handle, "IOHIDServiceClientCopyEvent"),
              let floatSymbol = dlsym(handle, "IOHIDEventGetFloatValue") else {
            status = "required HID symbols missing"
            return
        }

        let create = unsafeBitCast(createSymbol, to: HIDCreateFunction.self)
        let setMatching = unsafeBitCast(matchingSymbol, to: HIDSetMatchingFunction.self)
        copyEvent = unsafeBitCast(copyEventSymbol, to: HIDCopyEventFunction.self)
        getFloatValue = unsafeBitCast(floatSymbol, to: HIDGetFloatFunction.self)

        guard let client = create(kCFAllocatorDefault)?.takeRetainedValue() else {
            status = "HID client creation failed"
            return
        }
        self.client = client
        setMatching(
            client,
            [
                "PrimaryUsagePage": 0xff00,
                "PrimaryUsage": 5
            ] as CFDictionary
        )
        status = "ready"
    }

    func readTemperatures() -> [NamedTemperature] {
        guard let client, let copyEvent, let getFloatValue,
              let services = IOHIDEventSystemClientCopyServices(client) else {
            return []
        }

        var readings: [NamedTemperature] = []
        let count = CFArrayGetCount(services)
        readings.reserveCapacity(count)

        for index in 0..<count {
            guard let rawService = CFArrayGetValueAtIndex(services, index) else { continue }
            let service = Unmanaged<IOHIDServiceClient>
                .fromOpaque(rawService)
                .takeUnretainedValue()

            let name = IOHIDServiceClientCopyProperty(service, "Product" as CFString) as? String
            guard let name, !name.isEmpty,
                  let event = copyEvent(service, Self.temperatureEventType, 0, 0)?.takeRetainedValue() else {
                continue
            }

            let value = getFloatValue(event, Self.temperatureLevelField)
            guard HardwareSensorReader.isValidTemperature(value) else { continue }
            readings.append(NamedTemperature(name: name, value: value))
        }
        return readings
    }
}
