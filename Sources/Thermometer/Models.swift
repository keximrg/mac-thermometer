import Foundation
import Combine

enum MetricKind: String, CaseIterable, Codable, Identifiable {
    case cpu
    case gpu
    case soc
    case storage
    case battery
    case fan

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .soc: return "SoC 整体"
        case .storage: return "硬盘"
        case .battery: return "电池"
        case .fan: return "风扇"
        }
    }

    var shortTitle: String {
        switch self {
        case .storage: return "SSD"
        case .battery: return "BAT"
        case .fan: return "FAN"
        case .soc: return "SOC"
        default: return title
        }
    }

    var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .gpu: return "square.stack.3d.up.fill"
        case .soc: return "circle.hexagongrid.fill"
        case .storage: return "internaldrive.fill"
        case .battery: return "battery.75percent"
        case .fan: return "fan.fill"
        }
    }
}

enum ChipViewMode: String, CaseIterable, Identifiable {
    case separate
    case combined
    case both

    var id: String { rawValue }
    var title: String {
        switch self {
        case .separate: return "CPU / GPU"
        case .combined: return "SoC 整体"
        case .both: return "全部"
        }
    }
}

enum MenuIconStyle: String, CaseIterable, Identifiable {
    case automatic
    case black
    case white
    case custom

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "自动黑白"
        case .black: return "固定黑色"
        case .white: return "固定白色"
        case .custom: return "自定义"
        }
    }
}

enum HUDLayoutStyle: String, CaseIterable, Identifiable {
    case compact
    case cards
    case vertical

    var id: String { rawValue }
    var title: String {
        switch self {
        case .compact: return "紧凑横条"
        case .cards: return "卡片面板"
        case .vertical: return "竖向列表"
        }
    }

    var symbol: String {
        switch self {
        case .compact: return "rectangle.split.3x1"
        case .cards: return "square.grid.2x2"
        case .vertical: return "list.bullet.rectangle"
        }
    }
}

enum HUDContentStyle: String, CaseIterable, Identifiable {
    case iconValue
    case nameValue
    case valueOnly

    var id: String { rawValue }
    var title: String {
        switch self {
        case .iconValue: return "图标 + 数值"
        case .nameValue: return "名称 + 数值"
        case .valueOnly: return "纯数值"
        }
    }
}

enum HUDAnchor: String, CaseIterable, Identifiable {
    case custom
    case topLeft
    case topCenter
    case topRight
    case centerLeft
    case centerRight
    case bottomLeft
    case bottomCenter
    case bottomRight

    var id: String { rawValue }
    var title: String {
        switch self {
        case .custom: return "自定义（拖动）"
        case .topLeft: return "左上"
        case .topCenter: return "顶部"
        case .topRight: return "右上"
        case .centerLeft: return "左侧"
        case .centerRight: return "右侧"
        case .bottomLeft: return "左下"
        case .bottomCenter: return "底部"
        case .bottomRight: return "右下"
        }
    }
}

enum TemperatureUnit: String, CaseIterable, Identifiable {
    case celsius
    case fahrenheit

    var id: String { rawValue }
    var title: String { self == .celsius ? "摄氏度 °C" : "华氏度 °F" }
}

enum FanControlMode: String, CaseIterable, Identifiable {
    case system
    case temperature
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "系统自动"
        case .temperature: return "按温度"
        case .manual: return "自定义"
        }
    }

    var subtitle: String {
        switch self {
        case .system: return "软件不改转速，由 macOS 自行调节"
        case .temperature: return "芯片够热后按温度曲线提高转速"
        case .manual: return "将风扇锁定为指定转速"
        }
    }
}

struct SensorSnapshot: Equatable {
    var cpuC: Double?
    var gpuC: Double?
    var storageC: Double?
    var batteryC: Double?
    var fans: [FanReading]
    var timestamp: Date
    var sensorCount: Int
    var sourceSummary: String
    var fanControlAvailable: Bool

    static let empty = SensorSnapshot(
        cpuC: nil,
        gpuC: nil,
        storageC: nil,
        batteryC: nil,
        fans: [],
        timestamp: .distantPast,
        sensorCount: 0,
        sourceSummary: "正在连接传感器",
        fanControlAvailable: false
    )

    func temperature(for metric: MetricKind) -> Double? {
        switch metric {
        case .cpu: return cpuC
        case .gpu: return gpuC
        case .soc:
            guard let cpuC, let gpuC else { return nil }
            return (cpuC + gpuC) / 2
        case .storage: return storageC
        case .battery: return batteryC
        case .fan: return nil
        }
    }

    var primaryFanRPM: Double? { fans.first?.rpm }

    var thermalControlTemperature: Double? {
        [cpuC, gpuC].compactMap { $0 }.max()
    }
}

final class AppPreferences: ObservableObject {
    private let defaults: UserDefaults

    @Published var menuCPU: Bool { didSet { save(menuCPU, "menuCPU") } }
    @Published var menuGPU: Bool { didSet { save(menuGPU, "menuGPU") } }
    @Published var menuSoC: Bool { didSet { save(menuSoC, "menuSoC") } }
    @Published var menuStorage: Bool { didSet { save(menuStorage, "menuStorage") } }
    @Published var menuBattery: Bool { didSet { save(menuBattery, "menuBattery") } }
    @Published var menuFan: Bool { didSet { save(menuFan, "menuFan") } }

    @Published var menuIconStyle: MenuIconStyle {
        didSet { save(menuIconStyle.rawValue, "menuIconStyle") }
    }
    @Published var customIconPath: String {
        didSet { save(customIconPath, "customIconPath") }
    }

    @Published var hudEnabled: Bool { didSet { save(hudEnabled, "hudEnabled") } }
    @Published var hudLayout: HUDLayoutStyle { didSet { save(hudLayout.rawValue, "hudLayout") } }
    @Published var hudContentStyle: HUDContentStyle { didSet { save(hudContentStyle.rawValue, "hudContentStyle") } }
    @Published var hudAnchor: HUDAnchor { didSet { save(hudAnchor.rawValue, "hudAnchor") } }
    @Published var hudScale: Double { didSet { save(hudScale, "hudScale") } }
    @Published var hudOpacity: Double { didSet { save(hudOpacity, "hudOpacity") } }
    @Published var hudBlur: Bool { didSet { save(hudBlur, "hudBlur") } }
    @Published var hudClickThrough: Bool { didSet { save(hudClickThrough, "hudClickThrough") } }
    @Published var hudAlwaysOnTop: Bool { didSet { save(hudAlwaysOnTop, "hudAlwaysOnTop") } }
    @Published var hudCPU: Bool { didSet { save(hudCPU, "hudCPU") } }
    @Published var hudGPU: Bool { didSet { save(hudGPU, "hudGPU") } }
    @Published var hudSoC: Bool { didSet { save(hudSoC, "hudSoC") } }
    @Published var hudStorage: Bool { didSet { save(hudStorage, "hudStorage") } }
    @Published var hudBattery: Bool { didSet { save(hudBattery, "hudBattery") } }
    @Published var hudFan: Bool { didSet { save(hudFan, "hudFan") } }

    @Published var temperatureUnit: TemperatureUnit { didSet { save(temperatureUnit.rawValue, "temperatureUnit") } }
    @Published var chipViewMode: ChipViewMode {
        didSet {
            save(chipViewMode.rawValue, "chipViewMode")
        }
    }
    @Published var refreshInterval: Double { didSet { save(refreshInterval, "refreshInterval") } }
    @Published var launchAtLogin: Bool { didSet { save(launchAtLogin, "launchAtLogin") } }

    @Published var fanControlMode: FanControlMode {
        didSet { save(fanControlMode.rawValue, "fanControlMode") }
    }
    @Published var fanManualPercent: Double {
        didSet { save(fanManualPercent.clamped(to: 0...1), "fanManualPercent") }
    }
    @Published var fanCurveStartC: Double { didSet { save(fanCurveStartC, "fanCurveStartC") } }
    @Published var fanCurveFullC: Double { didSet { save(fanCurveFullC, "fanCurveFullC") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "menuCPU": true,
            "menuGPU": true,
            "menuSoC": false,
            "menuStorage": false,
            "menuBattery": false,
            "menuFan": true,
            "menuIconStyle": MenuIconStyle.automatic.rawValue,
            "customIconPath": "",
            "hudEnabled": false,
            "hudLayout": HUDLayoutStyle.compact.rawValue,
            "hudContentStyle": HUDContentStyle.iconValue.rawValue,
            "hudAnchor": HUDAnchor.topRight.rawValue,
            "hudCustomX": 1.0,
            "hudCustomY": 1.0,
            "hudCustomScreenID": 0,
            "hudScale": 1.0,
            "hudOpacity": 0.88,
            "hudBlur": true,
            "hudClickThrough": true,
            "hudAlwaysOnTop": true,
            "hudCPU": true,
            "hudGPU": true,
            "hudSoC": false,
            "hudStorage": true,
            "hudBattery": false,
            "hudFan": true,
            "temperatureUnit": TemperatureUnit.celsius.rawValue,
            "chipViewMode": ChipViewMode.separate.rawValue,
            "refreshInterval": 2.0,
            "launchAtLogin": false,
            "fanControlMode": FanControlMode.system.rawValue,
            "fanManualPercent": 0.45,
            "fanCurveStartC": 55.0,
            "fanCurveFullC": 85.0
        ])

        menuCPU = defaults.bool(forKey: "menuCPU")
        menuGPU = defaults.bool(forKey: "menuGPU")
        menuSoC = defaults.bool(forKey: "menuSoC")
        menuStorage = defaults.bool(forKey: "menuStorage")
        menuBattery = defaults.bool(forKey: "menuBattery")
        menuFan = defaults.bool(forKey: "menuFan")
        menuIconStyle = MenuIconStyle(rawValue: defaults.string(forKey: "menuIconStyle") ?? "") ?? .automatic
        customIconPath = defaults.string(forKey: "customIconPath") ?? ""

        hudEnabled = defaults.bool(forKey: "hudEnabled")
        hudLayout = HUDLayoutStyle(rawValue: defaults.string(forKey: "hudLayout") ?? "") ?? .compact
        hudContentStyle = HUDContentStyle(rawValue: defaults.string(forKey: "hudContentStyle") ?? "") ?? .iconValue
        hudAnchor = HUDAnchor(rawValue: defaults.string(forKey: "hudAnchor") ?? "") ?? .topRight
        hudScale = defaults.double(forKey: "hudScale").clamped(to: 0...1.0)
        hudOpacity = defaults.double(forKey: "hudOpacity").clamped(to: 0...1.0)
        hudBlur = defaults.bool(forKey: "hudBlur")
        hudClickThrough = defaults.bool(forKey: "hudClickThrough")
        hudAlwaysOnTop = defaults.bool(forKey: "hudAlwaysOnTop")
        hudCPU = defaults.bool(forKey: "hudCPU")
        hudGPU = defaults.bool(forKey: "hudGPU")
        hudSoC = defaults.bool(forKey: "hudSoC")
        hudStorage = defaults.bool(forKey: "hudStorage")
        hudBattery = defaults.bool(forKey: "hudBattery")
        hudFan = defaults.bool(forKey: "hudFan")

        temperatureUnit = TemperatureUnit(rawValue: defaults.string(forKey: "temperatureUnit") ?? "") ?? .celsius
        chipViewMode = ChipViewMode(rawValue: defaults.string(forKey: "chipViewMode") ?? "") ?? .separate
        refreshInterval = defaults.double(forKey: "refreshInterval").clamped(to: 1.0...10.0)
        launchAtLogin = defaults.bool(forKey: "launchAtLogin")
        fanControlMode = FanControlMode(rawValue: defaults.string(forKey: "fanControlMode") ?? "") ?? .system
        fanManualPercent = defaults.double(forKey: "fanManualPercent").clamped(to: 0...1)
        fanCurveStartC = defaults.double(forKey: "fanCurveStartC").clamped(to: 35...90)
        fanCurveFullC = defaults.double(forKey: "fanCurveFullC").clamped(to: 50...105)
        if fanCurveFullC <= fanCurveStartC {
            fanCurveFullC = min(105, fanCurveStartC + 10)
        }

        // Earlier builds coupled the overview mode to menu/HUD selections.
        // Migrate that state once, then keep all three surfaces independent.
        if !defaults.bool(forKey: "chipMetricSelectionDecoupledV1") {
            if menuSoC && !menuCPU && !menuGPU {
                menuCPU = true
                menuGPU = true
            }
            if hudSoC && !hudCPU && !hudGPU {
                hudCPU = true
                hudGPU = true
            }
            defaults.set(true, forKey: "chipMetricSelectionDecoupledV1")
        }
    }

    var menuMetrics: [MetricKind] {
        MetricKind.allCases.filter(isMenuEnabled)
    }

    var hudMetrics: [MetricKind] {
        MetricKind.allCases.filter(isHUDEnabled)
    }

    func isMenuEnabled(_ metric: MetricKind) -> Bool {
        switch metric {
        case .cpu: return menuCPU
        case .gpu: return menuGPU
        case .soc: return menuSoC
        case .storage: return menuStorage
        case .battery: return menuBattery
        case .fan: return menuFan
        }
    }

    func setMenuEnabled(_ enabled: Bool, for metric: MetricKind) {
        switch metric {
        case .cpu: menuCPU = enabled
        case .gpu: menuGPU = enabled
        case .soc: menuSoC = enabled
        case .storage: menuStorage = enabled
        case .battery: menuBattery = enabled
        case .fan: menuFan = enabled
        }
    }

    func isHUDEnabled(_ metric: MetricKind) -> Bool {
        switch metric {
        case .cpu: return hudCPU
        case .gpu: return hudGPU
        case .soc: return hudSoC
        case .storage: return hudStorage
        case .battery: return hudBattery
        case .fan: return hudFan
        }
    }

    func setHUDEnabled(_ enabled: Bool, for metric: MetricKind) {
        switch metric {
        case .cpu: hudCPU = enabled
        case .gpu: hudGPU = enabled
        case .soc: hudSoC = enabled
        case .storage: hudStorage = enabled
        case .battery: hudBattery = enabled
        case .fan: hudFan = enabled
        }
    }

    var hudCustomX: Double {
        defaults.double(forKey: "hudCustomX").clamped(to: 0...1)
    }

    var hudCustomY: Double {
        defaults.double(forKey: "hudCustomY").clamped(to: 0...1)
    }

    var hudCustomScreenID: Int {
        defaults.integer(forKey: "hudCustomScreenID")
    }

    func saveHUDCustomPosition(x: Double, y: Double, screenID: Int) {
        defaults.set(x.clamped(to: 0...1), forKey: "hudCustomX")
        defaults.set(y.clamped(to: 0...1), forKey: "hudCustomY")
        defaults.set(screenID, forKey: "hudCustomScreenID")
        if hudAnchor != .custom {
            hudAnchor = .custom
        }
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }

}

extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
