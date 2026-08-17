import AppKit
import SwiftUI

struct DashboardPopoverView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var appActions: AppActions
    @State private var selection: DashboardSection = .overview

    var body: some View {
        VStack(spacing: 0) {
            header
            sectionPicker

            Group {
                switch selection {
                case .overview:
                    OverviewSection(appModel: appModel, preferences: appModel.preferences)
                case .menuBar:
                    MenuBarSection(
                        appModel: appModel,
                        preferences: appModel.preferences,
                        chooseCustomIcon: appActions.chooseCustomIcon
                    )
                case .floating:
                    FloatingSettingsSection(
                        appModel: appModel,
                        preferences: appModel.preferences
                    )
                case .fans:
                    FanControlSection(
                        appModel: appModel,
                        preferences: appModel.preferences
                    )
                case .settings:
                    GeneralSettingsSection(
                        appModel: appModel,
                        preferences: appModel.preferences,
                        showAbout: appActions.showAbout,
                        quit: appActions.quit
                    )
                }
            }
            .id(selection)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 430, height: 650)
        .background(popoverBackground)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.cyan.opacity(0.96), Color.indigo.opacity(0.9)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: .cyan.opacity(0.32), radius: 12, y: 4)

                Image(systemName: "thermometer.medium")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text("Thermometer")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("LIVE")
                        .font(.system(size: 8, weight: .heavy, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(Color.black.opacity(0.82))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(appModel.healthColor, in: Capsule())
                }

                HStack(spacing: 6) {
                    Circle()
                        .fill(appModel.healthColor)
                        .frame(width: 6, height: 6)
                        .shadow(color: appModel.healthColor, radius: 4)
                    Text(appModel.healthLabel)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(updateDescription)
                        .foregroundStyle(.tertiary)
                }
                .font(.system(size: 11, weight: .medium))
            }

            Spacer(minLength: 8)

            Button(action: appModel.forceRefresh) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.075))
                    Circle()
                        .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)

                    if appModel.isSampling {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.cyan)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.82))
                    }
                }
                .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .help("立即刷新")
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 13)
    }

    private var sectionPicker: some View {
        HStack(spacing: 4) {
            ForEach(DashboardSection.allCases) { section in
                Button {
                    guard selection != section else { return }
                    selection = section
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: section.symbol)
                            .font(.system(size: 11, weight: .semibold))
                        Text(section.title)
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(selection == section ? Color.white : Color.white.opacity(0.45))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background {
                        if selection == section {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(0.1))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.08))
                                }
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .animation(.easeOut(duration: 0.1), value: selection)
                .accessibilityLabel(section.title)
            }
        }
        .padding(4)
        .background(Color.black.opacity(0.19), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var updateDescription: String {
        guard appModel.snapshot.timestamp != .distantPast else { return "等待首次读数" }
        return appModel.snapshot.timestamp.formatted(date: .omitted, time: .standard)
    }

    private var popoverBackground: some View {
        ZStack {
            Color(nsColor: NSColor(calibratedRed: 0.045, green: 0.055, blue: 0.075, alpha: 1))
            RadialGradient(
                colors: [Color.indigo.opacity(0.2), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 330
            )
            RadialGradient(
                colors: [Color.cyan.opacity(0.08), .clear],
                center: .bottomLeading,
                startRadius: 0,
                endRadius: 260
            )
        }
        .ignoresSafeArea()
    }
}

struct FloatingHUDView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        FloatingHUDSurface(
            appModel: appModel,
            preferences: appModel.preferences,
            previewMode: false
        )
    }
}

private enum DashboardSection: String, CaseIterable, Identifiable {
    case overview
    case menuBar
    case floating
    case fans
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "概览"
        case .menuBar: return "菜单栏"
        case .floating: return "悬浮"
        case .fans: return "风扇"
        case .settings: return "设置"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "waveform.path.ecg"
        case .menuBar: return "menubar.rectangle"
        case .floating: return "macwindow.on.rectangle"
        case .fans: return "fan.fill"
        case .settings: return "slider.horizontal.3"
        }
    }
}

private struct OverviewSection: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var preferences: AppPreferences

    private var temperatureMetrics: [MetricKind] {
        let chipMetrics: [MetricKind]
        switch preferences.chipViewMode {
        case .separate: chipMetrics = [.cpu, .gpu]
        case .combined: chipMetrics = [.soc]
        case .both: chipMetrics = [.soc, .cpu, .gpu]
        }
        return chipMetrics + [.storage, .battery]
    }
    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Label("芯片温度", systemImage: "cpu")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $preferences.chipViewMode) {
                        ForEach(ChipViewMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                .padding(8)
                .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))

                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(temperatureMetrics) { metric in
                        TemperatureCard(
                            metric: metric,
                            value: appModel.snapshot.temperature(for: metric),
                            formattedValue: appModel.formatValue(for: metric),
                            history: appModel.history[metric] ?? [],
                            stateLabel: appModel.healthLabel(for: metric),
                            stateColor: appModel.healthColor(for: metric)
                        )
                    }
                }

                FanCard(
                    fans: appModel.snapshot.fans,
                    formattedValue: appModel.formatValue(for: .fan),
                    history: appModel.history[.fan] ?? [],
                    mode: preferences.fanControlMode,
                    targets: appModel.fanTargets
                )

                HStack(spacing: 8) {
                    Label("\(appModel.snapshot.sensorCount) 个有效读数", systemImage: "sensor.tag.radiowaves.forward")
                    Spacer()
                    Text(appModel.snapshot.sourceSummary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 4)

                if let error = appModel.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(11)
                        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
    }
}

private struct TemperatureCard: View {
    let metric: MetricKind
    let value: Double?
    let formattedValue: String
    let history: [Double]
    let stateLabel: String
    let stateColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: metric.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(metric.tint)
                    .frame(width: 28, height: 28)
                    .background(metric.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 1) {
                    Text(metric.title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(metric.detailTitle)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 3)

                Text(stateLabel)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(stateColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(stateColor.opacity(0.1), in: Capsule())
            }

            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(formattedValue)
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 4)
                Text(history.count > 1 ? "近 \(history.count) 次" : "实时")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.quaternary)
            }

            SparklineView(values: history, color: metric.tint)
                .frame(height: 28)
        }
        .padding(12)
        .frame(minHeight: 130)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.055))
                .overlay(alignment: .topLeading) {
                    RadialGradient(
                        colors: [metric.tint.opacity(0.12), .clear],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: 120
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.075))
                }
        }
    }

}

private struct FanCard: View {
    let fans: [FanReading]
    let formattedValue: String
    let history: [Double]
    let mode: FanControlMode
    let targets: [Int: Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(MetricKind.fan.tint.opacity(0.14))
                    Image(systemName: MetricKind.fan.symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(MetricKind.fan.tint)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 2) {
                    Text("散热风扇")
                        .font(.system(size: 13, weight: .semibold))
                    Text(fans.isEmpty ? "未检测到可读风扇" : "\(fans.count) 个风扇 · \(mode.title)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Text(formattedValue)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }

            if fans.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "info.circle")
                    Text("部分无风扇机型会显示为不可用")
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            } else {
                ForEach(fans) { fan in
                    FanProgressRow(fan: fan, targetRPM: targets[fan.index])
                }
            }

            SparklineView(values: history, color: MetricKind.fan.tint)
                .frame(height: 23)
        }
        .padding(14)
        .background(PanelShape())
    }
}

private struct FanProgressRow: View {
    let fan: FanReading
    var targetRPM: Double? = nil

    var body: some View {
        HStack(spacing: 9) {
            Text(fan.name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.07))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.cyan, .blue],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: proxy.size.width * progress)
                        .shadow(color: .cyan.opacity(0.25), radius: 4)
                }
            }
            .frame(height: 5)

            VStack(alignment: .trailing, spacing: 1) {
                Text("\(Int(fan.rpm.rounded()))")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                if let targetRPM {
                    Text("目标 \(Int(targetRPM.rounded()))")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 58, alignment: .trailing)
        }
    }

    private var progress: CGFloat {
        let maximum = fan.maxRPM ?? max(fan.rpm, 1)
        return CGFloat((fan.rpm / max(maximum, 1)).clamped(to: 0...1))
    }
}

private struct FanControlSection: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                SettingsPanel(title: "控制方式", subtitle: "默认交给系统；只有选中后才会改写风扇转速") {
                    VStack(spacing: 10) {
                        HStack(spacing: 7) {
                            ForEach(FanControlMode.allCases) { mode in
                                FanModeButton(
                                    mode: mode,
                                    selected: preferences.fanControlMode == mode,
                                    enabled: mode == .system || !appModel.snapshot.fans.isEmpty
                                ) {
                                    preferences.fanControlMode = mode
                                }
                            }
                        }

                        Text(preferences.fanControlMode.subtitle)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if !appModel.snapshot.fans.isEmpty {
                    FanCard(
                        fans: appModel.snapshot.fans,
                        formattedValue: appModel.formatValue(for: .fan),
                        history: appModel.history[.fan] ?? [],
                        mode: preferences.fanControlMode,
                        targets: appModel.fanTargets
                    )
                }

                if preferences.fanControlMode == .temperature {
                    SettingsPanel(title: "温度曲线", subtitle: "芯片温度超过启动温度后开始加速，达到满速温度时拉到最高转速") {
                        VStack(spacing: 13) {
                            ValueSlider(
                                title: "启动温度",
                                symbol: "thermometer.low",
                                value: startTemperatureBinding,
                                range: 35...90,
                                valueText: String(format: "%.0f °C", preferences.fanCurveStartC)
                            )

                            ValueSlider(
                                title: "满速温度",
                                symbol: "thermometer.high",
                                value: fullTemperatureBinding,
                                range: 50...105,
                                valueText: String(format: "%.0f °C", preferences.fanCurveFullC)
                            )

                            Divider().opacity(0.35)

                            InformationRow(title: "当前芯片", value: currentChipText)
                            Divider().opacity(0.35)
                            InformationRow(title: "曲线位置", value: curvePositionText)
                            Divider().opacity(0.35)
                            InformationRow(title: "目标转速", value: targetRPMText)
                        }
                    }
                }

                if preferences.fanControlMode == .manual {
                    SettingsPanel(title: "自定义转速", subtitle: "按每个风扇自己的最低到最高转速范围锁定") {
                        VStack(spacing: 13) {
                            ValueSlider(
                                title: "转速",
                                symbol: "speedometer",
                                value: $preferences.fanManualPercent,
                                range: 0...1,
                                valueText: String(format: "%.0f%%", preferences.fanManualPercent * 100)
                            )

                            Divider().opacity(0.35)

                            ForEach(appModel.snapshot.fans) { fan in
                                InformationRow(
                                    title: fan.name,
                                    value: "\(Int(appModel.estimatedFanRPM(for: fan, percent: preferences.fanManualPercent).rounded())) RPM"
                                )
                            }
                        }
                    }
                }

                if let error = appModel.fanControlError {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.orange)
                        if appModel.fanControlNeedsAuthorization {
                            Button("授权控制风扇") {
                                appModel.authorizeFanControl()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(11)
                    .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
                }

                SettingsPanel(title: "说明", subtitle: nil) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(statusText)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("转速始终限制在硬件报告的最低与最高之间。首次手动控制需要管理员密码。退出应用、睡眠或改回系统自动时，会把控制权交还给 macOS。")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
    }

    private var startTemperatureBinding: Binding<Double> {
        Binding(
            get: { preferences.fanCurveStartC },
            set: { newValue in
                preferences.fanCurveStartC = newValue
                if preferences.fanCurveFullC <= newValue {
                    preferences.fanCurveFullC = min(105, newValue + 10)
                }
            }
        )
    }

    private var fullTemperatureBinding: Binding<Double> {
        Binding(
            get: { preferences.fanCurveFullC },
            set: { newValue in
                preferences.fanCurveFullC = max(newValue, preferences.fanCurveStartC + 1)
            }
        )
    }

    private var currentChipText: String {
        guard let temperature = appModel.snapshot.thermalControlTemperature else { return "—" }
        return appModel.formatTemperature(temperature)
    }

    private var curvePositionText: String {
        guard let temperature = appModel.snapshot.thermalControlTemperature else { return "等待温度" }
        let percent = appModel.temperatureCurvePercent(for: temperature)
        if percent <= 0 { return "低于启动温度 · 最低转速" }
        if percent >= 1 { return "达到满速温度 · 最高转速" }
        return String(format: "加速中 · %.0f%%", percent * 100)
    }

    private var targetRPMText: String {
        if let first = appModel.snapshot.fans.first, let target = appModel.fanTargets[first.index] {
            return "\(Int(target.rounded())) RPM"
        }
        guard let first = appModel.snapshot.fans.first,
              let temperature = appModel.snapshot.thermalControlTemperature else {
            return "—"
        }
        let rpm = appModel.estimatedFanRPM(
            for: first,
            percent: appModel.temperatureCurvePercent(for: temperature)
        )
        return "\(Int(rpm.rounded())) RPM"
    }

    private var statusText: String {
        if appModel.snapshot.fans.isEmpty {
            return "没有检测到可控制的风扇。无风扇机型（例如部分 MacBook Air）会保持这个状态。"
        }
        if appModel.fanControlNeedsAuthorization {
            return "Apple Silicon 改转速需要一次管理员授权。授权后会保持到退出应用。"
        }
        if !appModel.snapshot.fanControlAvailable {
            return "已读到风扇转速，但当前机型不允许软件改写转速。"
        }
        switch preferences.fanControlMode {
        case .system:
            return "当前由 macOS 控制风扇，Thermometer 只显示转速。"
        case .temperature:
            return "当前按 CPU/GPU 较高的一侧温度调节风扇。"
        case .manual:
            return "当前使用自定义转速，直到改回系统自动或退出应用。"
        }
    }
}

private struct FanModeButton: View {
    let mode: FanControlMode
    let selected: Bool
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? Color.cyan : Color.white.opacity(0.55))
                Text(mode.title)
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(selected ? Color.cyan.opacity(0.12) : Color.white.opacity(0.035))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.cyan.opacity(0.5) : Color.white.opacity(0.055))
            }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }

    private var symbol: String {
        switch mode {
        case .system: return "gearshape"
        case .temperature: return "thermometer.medium"
        case .manual: return "slider.horizontal.3"
        }
    }
}

private struct MenuBarSection: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var preferences: AppPreferences
    let chooseCustomIcon: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                SettingsPanel(title: "菜单栏预览", subtitle: "所选指标将跟随系统状态实时更新") {
                    MenuBarPreview(appModel: appModel, preferences: preferences)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }

                SettingsPanel(title: "显示指标", subtitle: "至少选择一个，避免菜单栏只显示图标") {
                    VStack(spacing: 0) {
                        ForEach(MetricKind.allCases) { metric in
                            MetricToggleRow(
                                metric: metric,
                                isOn: Binding(
                                    get: { preferences.isMenuEnabled(metric) },
                                    set: { preferences.setMenuEnabled($0, for: metric) }
                                ),
                                trailingText: appModel.formatValue(for: metric)
                            )

                            if metric != MetricKind.allCases.last {
                                Divider().opacity(0.35).padding(.leading, 38)
                            }
                        }
                    }
                }

                SettingsPanel(title: "菜单栏图标", subtitle: "自动模式会适配 macOS 的浅色和深色菜单栏") {
                    VStack(spacing: 11) {
                        HStack(spacing: 7) {
                            ForEach(MenuIconStyle.allCases) { style in
                                IconStyleButton(
                                    style: style,
                                    selected: preferences.menuIconStyle == style
                                ) {
                                    preferences.menuIconStyle = style
                                }
                            }
                        }

                        if preferences.menuIconStyle == .custom {
                            Button(action: chooseCustomIcon) {
                                HStack(spacing: 10) {
                                    CustomIconThumbnail(path: preferences.customIconPath)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(preferences.customIconPath.isEmpty ? "选择自定义图标" : "更换自定义图标")
                                            .font(.system(size: 11, weight: .semibold))
                                        Text(customIconDescription)
                                            .font(.system(size: 9, weight: .medium))
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(9)
                                .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
    }

    private var customIconDescription: String {
        guard !preferences.customIconPath.isEmpty else { return "支持 PNG、JPEG、TIFF 与 ICNS" }
        return URL(fileURLWithPath: preferences.customIconPath).lastPathComponent
    }
}

private struct FloatingSettingsSection: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                SettingsPanel(title: "桌面悬浮窗", subtitle: "只展示硬件状态，不打断当前应用") {
                    VStack(spacing: 12) {
                        Toggle(isOn: $preferences.hudEnabled) {
                            HStack(spacing: 10) {
                                SettingGlyph(symbol: "macwindow.on.rectangle", color: .cyan)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("显示悬浮监控")
                                        .font(.system(size: 12, weight: .semibold))
                                    Text(preferences.hudEnabled ? "已显示在 \(preferences.hudAnchor.title)" : "悬浮窗已关闭")
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .toggleStyle(.switch)
                        .tint(.cyan)

                        Divider().opacity(0.35)

                        GeometryReader { proxy in
                            ZStack {
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .fill(Color.black.opacity(0.25))
                                DotGrid().opacity(0.23)
                                FloatingHUDSurface(
                                    appModel: appModel,
                                    preferences: preferences,
                                    previewMode: true
                                )
                                .environment(\.colorScheme, preferences.hudBlur ? .light : .dark)
                                .scaleEffect(0.86)
                            }
                            .frame(width: proxy.size.width, height: proxy.size.height)
                        }
                        .frame(height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.06))
                        }
                    }
                }

                SettingsPanel(title: "展示形式", subtitle: "选择适合当前桌面布局的外观") {
                    HStack(spacing: 8) {
                        ForEach(HUDLayoutStyle.allCases) { style in
                            LayoutStyleButton(
                                style: style,
                                selected: preferences.hudLayout == style
                            ) {
                                preferences.hudLayout = style
                            }
                        }
                    }
                }

                SettingsPanel(title: "内容与位置", subtitle: nil) {
                    VStack(spacing: 13) {
                        LabeledPicker(title: "内容样式", symbol: "textformat") {
                            Picker("", selection: $preferences.hudContentStyle) {
                                ForEach(HUDContentStyle.allCases) { style in
                                    Text(style.title).tag(style)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 150)
                        }

                        Divider().opacity(0.35)

                        LabeledPicker(title: "屏幕位置", symbol: "rectangle.inset.filled") {
                            Picker("", selection: $preferences.hudAnchor) {
                                ForEach(HUDAnchor.allCases) { anchor in
                                    Text(anchor.title).tag(anchor)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 150)
                        }

                        Divider().opacity(0.35)

                        ValueSlider(
                            title: "展示大小",
                            symbol: "arrow.up.left.and.arrow.down.right",
                            value: $preferences.hudScale,
                            range: 0...1.0,
                            valueText: String(format: "%.0f%%", preferences.hudScale * 100)
                        )

                        ValueSlider(
                            title: "透明度",
                            symbol: "circle.lefthalf.filled",
                            value: $preferences.hudOpacity,
                            range: 0...1.0,
                            valueText: String(format: "%.0f%%", preferences.hudOpacity * 100)
                        )
                    }
                }

                SettingsPanel(title: "悬浮指标", subtitle: "CPU、GPU 与 SoC 整体可独立选择并同时显示") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(MetricKind.allCases) { metric in
                            SelectableMetricChip(
                                metric: metric,
                                selected: preferences.isHUDEnabled(metric)
                            ) {
                                preferences.setHUDEnabled(!preferences.isHUDEnabled(metric), for: metric)
                            }
                        }
                    }
                }

                SettingsPanel(title: "窗口行为", subtitle: nil) {
                    VStack(spacing: 10) {
                        CompactToggle(
                            title: "毛玻璃背景",
                            subtitle: "让桌面内容自然透出",
                            symbol: "drop.fill",
                            isOn: $preferences.hudBlur
                        )
                        Divider().opacity(0.35)
                        CompactToggle(
                            title: "鼠标点击穿透",
                            subtitle: preferences.hudClickThrough
                                ? "关闭后可直接拖动悬浮窗调整位置"
                                : "现在可拖动悬浮窗；位置会自动保存",
                            symbol: "cursorarrow.motionlines",
                            isOn: $preferences.hudClickThrough
                        )
                        Divider().opacity(0.35)
                        CompactToggle(
                            title: "始终位于最前",
                            subtitle: "切换应用后继续保持可见",
                            symbol: "square.3.layers.3d.top.filled",
                            isOn: $preferences.hudAlwaysOnTop
                        )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
    }
}

private struct GeneralSettingsSection: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var preferences: AppPreferences
    let showAbout: () -> Void
    let quit: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                SettingsPanel(title: "温度与刷新", subtitle: "调整单位和硬件采样频率") {
                    VStack(spacing: 12) {
                        LabeledPicker(title: "温度单位", symbol: "thermometer.medium") {
                            Picker("", selection: $preferences.temperatureUnit) {
                                ForEach(TemperatureUnit.allCases) { unit in
                                    Text(unit.title).tag(unit)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 150)
                        }

                        Divider().opacity(0.35)

                        LabeledPicker(title: "刷新间隔", symbol: "clock.arrow.circlepath") {
                            Picker("", selection: $preferences.refreshInterval) {
                                Text("1 秒").tag(1.0)
                                Text("2 秒").tag(2.0)
                                Text("3 秒").tag(3.0)
                                Text("5 秒").tag(5.0)
                                Text("10 秒").tag(10.0)
                            }
                            .labelsHidden()
                            .frame(width: 150)
                        }
                    }
                }

                SettingsPanel(title: "系统", subtitle: nil) {
                    CompactToggle(
                        title: "登录时自动启动",
                        subtitle: "开机后自动在菜单栏运行",
                        symbol: "power",
                        isOn: $preferences.launchAtLogin
                    )
                }

                SettingsPanel(title: "传感器状态", subtitle: nil) {
                    VStack(spacing: 10) {
                        InformationRow(title: "有效读数", value: "\(appModel.snapshot.sensorCount)")
                        Divider().opacity(0.35)
                        InformationRow(title: "数据来源", value: appModel.snapshot.sourceSummary)
                        Divider().opacity(0.35)
                        InformationRow(title: "采样状态", value: appModel.isSampling ? "正在更新" : "运行正常")
                    }
                }

                SettingsPanel(title: "Thermometer", subtitle: "原生 macOS 硬件温度与风扇监控") {
                    VStack(spacing: 9) {
                        Button(action: showAbout) {
                            SettingsActionRow(title: "关于 Thermometer", symbol: "info.circle")
                        }
                        .buttonStyle(.plain)

                        Divider().opacity(0.35)

                        Button(action: quit) {
                            SettingsActionRow(title: "退出 Thermometer", symbol: "power", destructive: true)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text("温度数据来自 macOS 可访问的硬件传感器。不同机型可提供的传感器数量可能不同。")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.quaternary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
    }
}

private struct FloatingHUDSurface: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var preferences: AppPreferences
    let previewMode: Bool

    private var metrics: [MetricKind] {
        preferences.hudMetrics
    }

    private var scale: CGFloat {
        previewMode ? 1 : CGFloat(preferences.hudScale)
    }

    private var usesSystemLiquidGlass: Bool {
        guard !previewMode, preferences.hudBlur else { return false }
        if #available(macOS 26.0, *) { return true }
        return false
    }

    var body: some View {
        Group {
            if metrics.isEmpty {
                Label("未选择指标", systemImage: "eye.slash")
                    .font(.system(size: 11 * scale, weight: .semibold))
                    .foregroundStyle(
                        preferences.hudBlur
                            ? Color.black.opacity(0.72)
                            : Color.white.opacity(0.72)
                    )
            } else {
                layout
            }
        }
        .padding(.horizontal, 12 * scale)
        .padding(.vertical, 10 * scale)
        .background(hudBackground)
        .overlay { glassRim }
        .overlay(alignment: .top) {
            if !previewMode && !preferences.hudClickThrough {
                Capsule()
                    .fill(
                        preferences.hudBlur
                            ? Color.black.opacity(0.24)
                            : Color.white.opacity(0.32)
                    )
                    .frame(width: 28 * scale, height: 3 * scale)
                    .padding(.top, 4 * scale)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 15 * scale, style: .continuous))
        .shadow(
            color: previewMode ? Color.black.opacity(0.2 * preferences.hudOpacity) : .clear,
            radius: previewMode ? 18 * scale : 0,
            y: previewMode ? 8 * scale : 0
        )
        .fixedSize()
        .allowsHitTesting(previewMode || !preferences.hudClickThrough)
        .animation(.easeInOut(duration: 0.2), value: preferences.hudLayout)
        .animation(.easeInOut(duration: 0.2), value: metrics)
    }

    @ViewBuilder
    private var layout: some View {
        switch preferences.hudLayout {
        case .compact:
            HStack(spacing: 11 * scale) {
                ForEach(metrics) { metric in
                    HUDMetricItem(
                        metric: metric,
                        value: appModel.formatValue(for: metric),
                        contentStyle: preferences.hudContentStyle,
                        layout: .compact,
                        scale: scale,
                        darkText: preferences.hudBlur
                    )
                }
            }

        case .cards:
            LazyVGrid(
                columns: [
                    GridItem(.fixed(92 * scale), spacing: 7 * scale),
                    GridItem(.fixed(92 * scale), spacing: 7 * scale)
                ],
                spacing: 7 * scale
            ) {
                ForEach(metrics) { metric in
                    HUDMetricItem(
                        metric: metric,
                        value: appModel.formatValue(for: metric),
                        contentStyle: preferences.hudContentStyle,
                        layout: .cards,
                        scale: scale,
                        darkText: preferences.hudBlur
                    )
                }
            }

        case .vertical:
            VStack(spacing: 7 * scale) {
                ForEach(metrics) { metric in
                    HUDMetricItem(
                        metric: metric,
                        value: appModel.formatValue(for: metric),
                        contentStyle: preferences.hudContentStyle,
                        layout: .vertical,
                        scale: scale,
                        darkText: preferences.hudBlur
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var hudBackground: some View {
        if preferences.hudBlur {
            if usesSystemLiquidGlass {
                Color.clear
            } else {
                ZStack {
                    if previewMode {
                        RoundedRectangle(cornerRadius: 15 * scale, style: .continuous)
                            .fill(.ultraThinMaterial)
                    }

                    RoundedRectangle(cornerRadius: 15 * scale, style: .continuous)
                        .fill(Color.white.opacity(0.16))

                    RoundedRectangle(cornerRadius: 15 * scale, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.16), .clear, Color.black.opacity(0.035)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
                .opacity(preferences.hudOpacity)
            }
        } else {
            RoundedRectangle(cornerRadius: 15 * scale, style: .continuous)
                .fill(Color.black.opacity(0.9 * preferences.hudOpacity))
        }
    }

    private var glassRim: some View {
        RoundedRectangle(cornerRadius: 15 * scale, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: usesSystemLiquidGlass
                        ? [Color.white.opacity(0.52), Color.black.opacity(0.07)]
                        : preferences.hudBlur
                            ? [Color.white.opacity(0.5), Color.black.opacity(0.065)]
                            : [Color.white.opacity(0.34), Color.white.opacity(0.08)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: usesSystemLiquidGlass ? 0.65 : 0.9
            )
            .opacity(preferences.hudOpacity)
    }
}

private struct HUDMetricItem: View {
    let metric: MetricKind
    let value: String
    let contentStyle: HUDContentStyle
    let layout: HUDLayoutStyle
    let scale: CGFloat
    let darkText: Bool

    private var textColor: Color {
        darkText ? Color.black.opacity(0.84) : .white
    }

    var body: some View {
        Group {
            switch layout {
            case .compact:
                HStack(spacing: 5 * scale) {
                    label
                    Text(value)
                        .font(.system(size: 11 * scale, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }

            case .cards:
                VStack(alignment: .leading, spacing: 6 * scale) {
                    HStack {
                        label
                        Spacer(minLength: 2)
                    }
                    Text(value)
                        .font(.system(size: 14 * scale, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                .padding(8 * scale)
                .frame(width: 92 * scale, alignment: .leading)
                .background(metric.tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 9 * scale))

            case .vertical:
                HStack(spacing: 8 * scale) {
                    label
                    Spacer(minLength: 15 * scale)
                    Text(value)
                        .font(.system(size: 12 * scale, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
                .frame(minWidth: 145 * scale)
            }
        }
        .foregroundStyle(textColor)
    }

    @ViewBuilder
    private var label: some View {
        switch contentStyle {
        case .iconValue:
            Image(systemName: metric.symbol)
                .font(.system(size: 10 * scale, weight: .semibold))
                .foregroundStyle(metric.tint)
        case .nameValue:
            Text(metric.shortTitle)
                .font(.system(size: 9 * scale, weight: .bold, design: .rounded))
                .foregroundStyle(darkText ? Color.black.opacity(0.76) : metric.tint)
        case .valueOnly:
            EmptyView()
        }
    }
}

private struct MenuBarPreview: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                CustomIconThumbnail(path: preferences.menuIconStyle == .custom ? preferences.customIconPath : "", compact: true)

                if preferences.menuMetrics.isEmpty {
                    Text("Thermometer")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(preferences.menuMetrics) { metric in
                        HStack(spacing: 3) {
                            Text(metric.shortTitle)
                                .foregroundStyle(.secondary)
                            Text(appModel.formatValue(for: metric))
                                .foregroundStyle(.white)
                                .monospacedDigit()
                        }
                    }
                }
            }
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(Color.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.07))
            }
        }
    }
}

private struct MetricToggleRow: View {
    let metric: MetricKind
    @Binding var isOn: Bool
    let trailingText: String

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 9) {
                SettingGlyph(symbol: metric.symbol, color: metric.tint, size: 29)
                VStack(alignment: .leading, spacing: 2) {
                    Text(metric.title)
                        .font(.system(size: 11, weight: .semibold))
                    Text(metric == .fan ? "实时转速" : metric.detailTitle)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text(trailingText)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 6)
            }
        }
        .toggleStyle(.switch)
        .tint(metric.tint)
        .padding(.vertical, 7)
    }
}

private struct IconStyleButton: View {
    let style: MenuIconStyle
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(iconBackground)
                    Image(systemName: style == .custom ? "photo" : "thermometer.medium")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(iconColor)
                }
                .frame(width: 30, height: 30)

                Text(style.title)
                    .font(.system(size: 8, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(selected ? Color.cyan.opacity(0.13) : Color.white.opacity(0.035))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.cyan.opacity(0.52) : Color.white.opacity(0.055))
            }
        }
        .buttonStyle(.plain)
    }

    private var iconBackground: Color {
        switch style {
        case .automatic: return Color.white.opacity(0.1)
        case .black: return Color.white.opacity(0.9)
        case .white: return Color.black.opacity(0.72)
        case .custom: return Color.indigo.opacity(0.3)
        }
    }

    private var iconColor: Color {
        switch style {
        case .automatic: return .cyan
        case .black: return .black
        case .white: return .white
        case .custom: return .purple
        }
    }
}

private struct CustomIconThumbnail: View {
    let path: String
    var compact = false

    var body: some View {
        Group {
            if !path.isEmpty, let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "thermometer.medium")
                    .font(.system(size: compact ? 11 : 14, weight: .bold))
                    .foregroundStyle(.cyan)
            }
        }
        .frame(width: compact ? 14 : 30, height: compact ? 14 : 30)
        .background(compact ? Color.clear : Color.cyan.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: compact ? 3 : 8))
    }
}

private struct LayoutStyleButton: View {
    let style: HUDLayoutStyle
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: style.symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(selected ? Color.cyan : Color.white.opacity(0.55))
                Text(style.title)
                    .font(.system(size: 9, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(selected ? Color.cyan.opacity(0.12) : Color.white.opacity(0.035))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.cyan.opacity(0.5) : Color.white.opacity(0.055))
            }
        }
        .buttonStyle(.plain)
    }
}

private struct SelectableMetricChip: View {
    let metric: MetricKind
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: metric.symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(selected ? metric.tint : Color.secondary)
                Text(metric.title)
                    .font(.system(size: 10, weight: .semibold))
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selected ? metric.tint : Color.white.opacity(0.2))
            }
            .padding(.horizontal, 9)
            .frame(height: 34)
            .background(selected ? metric.tint.opacity(0.1) : Color.white.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(selected ? metric.tint.opacity(0.26) : Color.white.opacity(0.04))
            }
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsPanel<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: Content

    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }

            content
        }
        .padding(13)
        .background(PanelShape())
    }
}

private struct PanelShape: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 15, style: .continuous)
            .fill(Color.white.opacity(0.052))
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.07))
            }
    }
}

private struct SettingGlyph: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: size * 0.28))
    }
}

private struct LabeledPicker<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 9) {
            SettingGlyph(symbol: symbol, color: .cyan, size: 29)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            Spacer()
            content
        }
    }
}

private struct ValueSlider: View {
    let title: String
    let symbol: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let valueText: String

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 9) {
                SettingGlyph(symbol: symbol, color: .cyan, size: 29)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(valueText)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
                .tint(.cyan)
        }
    }
}

private struct CompactToggle: View {
    let title: String
    let subtitle: String
    let symbol: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 9) {
                SettingGlyph(symbol: symbol, color: .cyan, size: 29)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .toggleStyle(.switch)
        .tint(.cyan)
    }
}

private struct InformationRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

private struct SettingsActionRow: View {
    let title: String
    let symbol: String
    var destructive = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(destructive ? Color.red : Color.cyan)
                .frame(width: 22)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(destructive ? Color.red : Color.primary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

private struct SparklineView: View {
    let values: [Double]
    let color: Color

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                Divider().opacity(0.12)
                Spacer()
                Divider().opacity(0.08)
            }

            if values.count > 1 {
                SparklineFill(values: values)
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.25), color.opacity(0.01)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                SparklineLine(values: values)
                    .stroke(
                        LinearGradient(
                            colors: [color.opacity(0.55), color],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)
                    )
                    .shadow(color: color.opacity(0.25), radius: 3)
            } else {
                Capsule()
                    .fill(color.opacity(0.22))
                    .frame(height: 1)
            }
        }
        .animation(.easeOut(duration: 0.35), value: values)
    }
}

private struct SparklineLine: Shape {
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        let points = sparklinePoints(values: values, in: rect)
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        return path
    }
}

private struct SparklineFill: Shape {
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        let points = sparklinePoints(values: values, in: rect)
        var path = Path()
        guard let first = points.first, let last = points.last else { return path }
        path.move(to: CGPoint(x: first.x, y: rect.maxY))
        path.addLine(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        path.addLine(to: CGPoint(x: last.x, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct DotGrid: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 14
            var path = Path()
            var x: CGFloat = spacing / 2
            while x < size.width {
                var y: CGFloat = spacing / 2
                while y < size.height {
                    path.addEllipse(in: CGRect(x: x, y: y, width: 1.2, height: 1.2))
                    y += spacing
                }
                x += spacing
            }
            context.fill(path, with: .color(.white))
        }
    }
}

private func sparklinePoints(values: [Double], in rect: CGRect) -> [CGPoint] {
    guard !values.isEmpty else { return [] }
    let minimum = values.min() ?? 0
    let maximum = values.max() ?? 1
    let spread = max(maximum - minimum, 0.001)
    let insetRect = rect.insetBy(dx: 1, dy: 2)

    return values.enumerated().map { index, value in
        let fraction = values.count == 1 ? 0.5 : Double(index) / Double(values.count - 1)
        let normalized = (value - minimum) / spread
        return CGPoint(
            x: insetRect.minX + insetRect.width * CGFloat(fraction),
            y: insetRect.maxY - insetRect.height * CGFloat(normalized)
        )
    }
}

private extension MetricKind {
    var tint: Color {
        switch self {
        case .cpu: return Color(red: 0.31, green: 0.88, blue: 0.78)
        case .gpu: return Color(red: 0.57, green: 0.48, blue: 1.0)
        case .soc: return Color(red: 1.0, green: 0.38, blue: 0.56)
        case .storage: return Color(red: 0.25, green: 0.68, blue: 1.0)
        case .battery: return Color(red: 0.56, green: 0.91, blue: 0.32)
        case .fan: return Color(red: 0.24, green: 0.82, blue: 1.0)
        }
    }

    var detailTitle: String {
        switch self {
        case .cpu: return "处理器核心"
        case .gpu: return "图形处理器"
        case .soc: return "CPU + GPU 聚合"
        case .storage: return "内部存储"
        case .battery: return "电池组"
        case .fan: return "散热转速"
        }
    }
}
