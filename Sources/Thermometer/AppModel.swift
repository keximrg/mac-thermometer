import Foundation
import Combine
import SwiftUI
import AppKit
import ServiceManagement

final class AppModel: ObservableObject {
    let preferences: AppPreferences

    @Published private(set) var snapshot: SensorSnapshot = .empty
    @Published private(set) var history: [MetricKind: [Double]] = [:]
    @Published private(set) var isSampling = false
    @Published private(set) var lastError: String?
    @Published private(set) var fanTargets: [Int: Double] = [:]
    @Published private(set) var fanControlError: String?
    @Published private(set) var fanControlNeedsAuthorization = false

    private let sensorQueue = DispatchQueue(label: "com.thermometer.sensors", qos: .utility)
    private var reader: HardwareSensorReader?
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var pendingRefresh = false
    private var privilegePromptAttempted = false

    init(preferences: AppPreferences = AppPreferences()) {
        self.preferences = preferences
        MetricKind.allCases.forEach { history[$0] = [] }

        if #available(macOS 13.0, *) {
            let loginItemIsEnabled = SMAppService.mainApp.status == .enabled
            if preferences.launchAtLogin != loginItemIsEnabled {
                preferences.launchAtLogin = loginItemIsEnabled
            }
        }

        preferences.$refreshInterval
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleTimer() }
            .store(in: &cancellables)

        preferences.$launchAtLogin
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] enabled in self?.setLaunchAtLogin(enabled) }
            .store(in: &cancellables)

        preferences.$fanControlMode
            .dropFirst()
            .sink { [weak self] _ in self?.privilegePromptAttempted = false }
            .store(in: &cancellables)

        preferences.$fanControlMode
            .combineLatest(
                preferences.$fanManualPercent,
                preferences.$fanCurveStartC,
                preferences.$fanCurveFullC
            )
            .dropFirst()
            .debounce(for: .milliseconds(80), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.forceRefresh() }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in self?.resetReaderAndRefresh() }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in self?.restoreAutomaticFans() }
            .store(in: &cancellables)
    }

    deinit {
        timer?.invalidate()
    }

    func start() {
        scheduleTimer()
        forceRefresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        restoreAutomaticFans()
    }

    func forceRefresh() {
        if isSampling {
            pendingRefresh = true
            return
        }
        isSampling = true
        let mode = preferences.fanControlMode
        let manualPercent = preferences.fanManualPercent
        let curveStartC = preferences.fanCurveStartC
        let curveFullC = preferences.fanCurveFullC

        sensorQueue.async { [weak self] in
            guard let self else { return }
            if self.reader == nil {
                self.reader = HardwareSensorReader()
            }
            let raw = self.reader?.sample()
            let outcome = raw.flatMap { snapshot in
                self.applyFanControlOnQueue(
                    mode: mode,
                    manualPercent: manualPercent,
                    curveStartC: curveStartC,
                    curveFullC: curveFullC,
                    snapshot: snapshot
                )
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isSampling = false
                if let raw {
                    let value = SensorSnapshot(
                        cpuC: raw.cpuC,
                        gpuC: raw.gpuC,
                        storageC: raw.storageC,
                        batteryC: raw.batteryC,
                        fans: raw.fans,
                        timestamp: Date(),
                        sensorCount: raw.sensorCount,
                        sourceSummary: raw.sourceSummary,
                        fanControlAvailable: raw.fanControlAvailable
                    )
                    self.snapshot = value
                    self.lastError = nil
                    self.fanTargets = outcome?.targets ?? [:]
                    self.fanControlError = outcome?.error
                    if outcome?.needsPrivilege == true {
                        self.requestFanAuthorizationIfNeeded()
                    } else if outcome?.error == nil {
                        self.fanControlNeedsAuthorization = false
                    }
                    self.appendHistory(value)
                } else {
                    self.lastError = "暂时无法连接硬件传感器"
                    self.fanTargets = [:]
                }
                if self.pendingRefresh {
                    self.pendingRefresh = false
                    self.forceRefresh()
                }
            }
        }
    }

    func formatValue(for metric: MetricKind) -> String {
        if metric == .fan {
            guard let rpm = snapshot.primaryFanRPM else { return "—" }
            return "\(Int(rpm.rounded())) RPM"
        }
        guard let value = snapshot.temperature(for: metric) else { return "—" }
        return formatTemperature(value)
    }

    func formatTemperature(_ celsius: Double, includeUnit: Bool = true) -> String {
        let converted: Double
        let suffix: String
        switch preferences.temperatureUnit {
        case .celsius:
            converted = celsius
            suffix = "°C"
        case .fahrenheit:
            converted = celsius * 9 / 5 + 32
            suffix = "°F"
        }
        return String(format: includeUnit ? "%.0f%@" : "%.0f°", converted, suffix)
    }

    var healthLabel: String {
        guard snapshot.timestamp != .distantPast else { return "正在读取" }
        let cpu = snapshot.cpuC ?? 0
        let gpu = snapshot.gpuC ?? 0
        let battery = snapshot.batteryC ?? 0
        let storage = snapshot.storageC ?? 0
        if cpu >= 95 || gpu >= 95 || battery >= 50 || storage >= 80 { return "温度过高" }
        if cpu >= 80 || gpu >= 82 || battery >= 43 || storage >= 65 { return "偏热" }
        if cpu >= 65 || gpu >= 68 || battery >= 38 || storage >= 55 { return "温暖" }
        return "状态清凉"
    }

    var healthColor: Color {
        switch healthLabel {
        case "温度过高": return Color(red: 1.0, green: 0.22, blue: 0.30)
        case "偏热": return Color(red: 1.0, green: 0.48, blue: 0.18)
        case "温暖": return Color(red: 0.98, green: 0.72, blue: 0.22)
        default: return Color(red: 0.25, green: 0.88, blue: 0.78)
        }
    }

    func healthLabel(for metric: MetricKind) -> String {
        if metric == .fan {
            guard let rpm = snapshot.primaryFanRPM else { return "不可用" }
            return rpm == 0 ? "静音停转" : "运行中"
        }
        guard let value = snapshot.temperature(for: metric) else { return "不可用" }
        let warning: Double
        let hot: Double
        switch metric {
        case .battery:
            warning = 40; hot = 46
        case .storage:
            warning = 60; hot = 75
        default:
            warning = 72; hot = 88
        }
        if value >= hot { return "高温" }
        if value >= warning { return "偏热" }
        return "正常"
    }

    func healthColor(for metric: MetricKind) -> Color {
        switch healthLabel(for: metric) {
        case "高温": return Color(red: 1.0, green: 0.22, blue: 0.30)
        case "偏热": return Color(red: 1.0, green: 0.56, blue: 0.18)
        case "不可用": return .secondary
        default: return Color(red: 0.24, green: 0.84, blue: 0.74)
        }
    }

    func estimatedFanRPM(for fan: FanReading, percent: Double) -> Double {
        let minimum = fan.minRPM ?? 0
        let maximum = fan.maxRPM ?? max(fan.rpm, 4_000)
        let ceiling = max(maximum, minimum)
        return (minimum + percent.clamped(to: 0...1) * (ceiling - minimum)).clamped(to: minimum...ceiling)
    }

    func temperatureCurvePercent(for temperature: Double) -> Double {
        let start = preferences.fanCurveStartC
        let full = max(preferences.fanCurveFullC, start + 1)
        if temperature <= start { return 0 }
        if temperature >= full { return 1 }
        return (temperature - start) / (full - start)
    }

    func authorizeFanControl() {
        privilegePromptAttempted = false
        requestFanAuthorizationIfNeeded()
    }

    func diagnosticLines(completion: @escaping ([String]) -> Void) {
        sensorQueue.async { [weak self] in
            let lines = self?.reader?.diagnosticLines() ?? ["传感器尚未初始化"]
            DispatchQueue.main.async { completion(lines) }
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: preferences.refreshInterval, repeats: true) { [weak self] _ in
            self?.forceRefresh()
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func applyFanControlOnQueue(
        mode: FanControlMode,
        manualPercent: Double,
        curveStartC: Double,
        curveFullC: Double,
        snapshot: RawSensorSnapshot
    ) -> FanControlOutcome? {
        if mode != .system, SMCHelperService.isRunning() {
            return SMCHelperService.apply(
                mode: mode,
                manualPercent: manualPercent,
                curveStartC: curveStartC,
                curveFullC: curveFullC
            )
        }
        return reader?.applyFanControl(
            mode: mode,
            manualPercent: manualPercent,
            curveStartC: curveStartC,
            curveFullC: curveFullC,
            controlTemperature: [snapshot.cpuC, snapshot.gpuC].compactMap { $0 }.max(),
            fans: snapshot.fans
        )
    }

    private func requestFanAuthorizationIfNeeded() {
        fanControlNeedsAuthorization = true
        guard !privilegePromptAttempted else { return }
        privilegePromptAttempted = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if SMCHelperService.authorizeAndStart() {
                self.fanControlNeedsAuthorization = false
                self.fanControlError = nil
                self.forceRefresh()
            } else {
                self.fanControlError = "需要管理员密码才能调节风扇"
            }
        }
    }

    private func restoreAutomaticFans() {
        let fanCount = max(snapshot.fans.count, 1)
        sensorQueue.sync {
            if SMCHelperService.isRunning() {
                SMCHelperService.restore(fanCount: fanCount)
                if self.timer == nil {
                    SMCHelperService.shutdown()
                }
            }
            self.reader?.restoreAutomaticFans(fanCount: fanCount)
        }
        fanTargets = [:]
        fanControlError = nil
    }

    private func resetReaderAndRefresh() {
        let fanCount = max(snapshot.fans.count, 1)
        sensorQueue.async { [weak self] in
            if SMCHelperService.isRunning() {
                SMCHelperService.restore(fanCount: fanCount)
            }
            self?.reader?.restoreAutomaticFans(fanCount: fanCount)
            self?.reader = nil
            DispatchQueue.main.async { self?.forceRefresh() }
        }
    }

    private func appendHistory(_ value: SensorSnapshot) {
        let samples: [(MetricKind, Double?)] = [
            (.cpu, value.cpuC),
            (.gpu, value.gpuC),
            (.soc, value.temperature(for: .soc)),
            (.storage, value.storageC),
            (.battery, value.batteryC),
            (.fan, value.primaryFanRPM)
        ]
        for (kind, sample) in samples {
            guard let sample else { continue }
            var values = history[kind] ?? []
            values.append(sample)
            if values.count > 60 { values.removeFirst(values.count - 60) }
            history[kind] = values
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = "登录启动设置失败：\(error.localizedDescription)"
            let actualState = SMAppService.mainApp.status == .enabled
            if preferences.launchAtLogin != actualState {
                preferences.launchAtLogin = actualState
            }
        }
    }
}

final class AppActions: ObservableObject {
    var chooseCustomIconHandler: (() -> Void)?
    var quitHandler: (() -> Void)?
    var showAboutHandler: (() -> Void)?

    func chooseCustomIcon() { chooseCustomIconHandler?() }
    func quit() { quitHandler?() }
    func showAbout() { showAboutHandler?() }
}
