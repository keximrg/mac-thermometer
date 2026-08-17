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
}

final class HardwareSensorReader {
    private let lock = NSLock()
    private let smc: SMCReader?
    private let hid: HIDTemperatureReader
    private let family: ChipFamily
    private var lastDiagnostics: [String]

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
            sourceSummary: sources.joined(separator: ", ")
        )
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
    private static let readKeyInfoCommand: UInt8 = 9

    private var connection: io_connect_t = 0
    private var keyInfoCache: [String: SMCKeyInfoData] = [:]
    private var missingKeys = Set<String>()
    private(set) var serviceName = "unavailable"

    init?() {
        guard MemoryLayout<SMCParamStruct>.stride == 80 else { return nil }

        for candidate in ["AppleSMCKeysEndpoint", "AppleSMC"] {
            guard let matching = IOServiceMatching(candidate) else { continue }
            let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
            guard service != 0 else { continue }
            defer { IOObjectRelease(service) }

            var candidateConnection: io_connect_t = 0
            let result = IOServiceOpen(service, mach_task_self_, 0, &candidateConnection)
            guard result == kIOReturnSuccess, candidateConnection != 0 else { continue }

            connection = candidateConnection
            serviceName = candidate
            return
        }
        return nil
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
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

    private func readValue(_ key: String) -> SMCValue? {
        guard key.utf8.count == 4, !missingKeys.contains(key) else { return nil }

        let keyInfo: SMCKeyInfoData
        if let cached = keyInfoCache[key] {
            keyInfo = cached
        } else {
            var input = SMCParamStruct()
            input.key = Self.fourCharacterCode(key)
            input.data8 = Self.readKeyInfoCommand

            guard let output = call(input), output.result == 0,
                  output.keyInfo.dataSize > 0, output.keyInfo.dataSize <= 32 else {
                missingKeys.insert(key)
                return nil
            }
            keyInfo = output.keyInfo
            keyInfoCache[key] = keyInfo
        }

        var input = SMCParamStruct()
        input.key = Self.fourCharacterCode(key)
        input.keyInfo.dataSize = keyInfo.dataSize
        input.data8 = Self.readBytesCommand

        guard let output = call(input), output.result == 0 else { return nil }
        let bytes = withUnsafeBytes(of: output.bytes) {
            Array($0.prefix(Int(keyInfo.dataSize)))
        }
        return SMCValue(type: Self.fourCharacterString(keyInfo.dataType), bytes: bytes)
    }

    private func call(_ request: SMCParamStruct) -> SMCParamStruct? {
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
            return nil
        }
        return output
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
