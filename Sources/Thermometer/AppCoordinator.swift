import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let preferences = AppPreferences()
    private lazy var model = AppModel(preferences: preferences)
    private let actions = AppActions()

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var hudController: FloatingHUDController!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureActions()
        configureStatusItem()
        configurePopover()

        hudController = FloatingHUDController(model: model, preferences: preferences)
        observeChanges()
        model.start()
        updateStatusItem()
        hudController.sync()

        if CommandLine.arguments.contains("--preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.togglePopover(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    guard let windowNumber = self?.popover.contentViewController?.view.window?.windowNumber else { return }
                    try? String(windowNumber).write(
                        to: URL(fileURLWithPath: "/tmp/thermometer-preview-window-id"),
                        atomically: true,
                        encoding: .utf8
                    )
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    self?.writePreviewImage()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }

    private func configureActions() {
        actions.chooseCustomIconHandler = { [weak self] in self?.chooseCustomIcon() }
        actions.quitHandler = { NSApp.terminate(nil) }
        actions.showAboutHandler = { [weak self] in self?.showAbout() }
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = "Thermometer · Mac 硬件温度"
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func configurePopover() {
        popover.behavior = CommandLine.arguments.contains("--preview") ? .applicationDefined : .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: 430, height: 650)
        popover.contentViewController = NSHostingController(
            rootView: DashboardPopoverView()
                .environmentObject(model)
                .environmentObject(actions)
        )
    }

    private func observeChanges() {
        model.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItem()
                self?.hudController?.syncContent()
            }
            .store(in: &cancellables)

        preferences.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateStatusItem()
                    self?.hudController?.sync()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.hudController?.positionPanel() }
            .store(in: &cancellables)
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            model.forceRefresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        button.image = menuBarImage()

        let metrics = preferences.menuMetrics
        let parts = metrics.map { metric -> String in
            if metric == .fan {
                guard let rpm = model.snapshot.primaryFanRPM else { return "FAN —" }
                return "FAN \(Int(rpm.rounded()))"
            }
            guard let value = model.snapshot.temperature(for: metric) else {
                return "\(metric.shortTitle) —"
            }
            return "\(metric.shortTitle) \(model.formatTemperature(value, includeUnit: false))"
        }
        let title = parts.joined(separator: "  ")
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        button.attributedTitle = NSAttributedString(
            string: title.isEmpty ? "" : " \(title)",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
        )
        statusItem.length = NSStatusItem.variableLength
    }

    private func menuBarImage() -> NSImage? {
        let style = preferences.menuIconStyle
        if style == .custom,
           !preferences.customIconPath.isEmpty,
           let custom = NSImage(contentsOfFile: preferences.customIconPath) {
            custom.size = NSSize(width: 18, height: 18)
            custom.isTemplate = false
            return custom
        }

        guard let symbol = NSImage(systemSymbolName: "thermometer.medium", accessibilityDescription: "Thermometer") else {
            return nil
        }
        symbol.size = NSSize(width: 17, height: 17)

        switch style {
        case .automatic, .custom:
            symbol.isTemplate = true
            return symbol
        case .black:
            let configured = symbol.withSymbolConfiguration(.init(paletteColors: [.black])) ?? symbol
            configured.isTemplate = false
            return configured
        case .white:
            let configured = symbol.withSymbolConfiguration(.init(paletteColors: [.white])) ?? symbol
            configured.isTemplate = false
            return configured
        }
    }

    private func chooseCustomIcon() {
        let panel = NSOpenPanel()
        panel.title = "选择菜单栏图标"
        panel.message = "推荐使用透明背景的正方形 PNG；应用会保存一份独立副本。"
        panel.prompt = "使用此图标"
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .gif, .bmp, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        panel.begin { [weak self] result in
            guard result == .OK, let source = panel.url, let self else { return }
            do {
                let directory = try FileManager.default.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                ).appendingPathComponent("Thermometer", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension
                let destination = directory.appendingPathComponent("CustomMenuIcon.\(ext)")
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: source, to: destination)
                self.preferences.customIconPath = destination.path
                self.preferences.menuIconStyle = .custom
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "无法使用这个图标"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Thermometer"
        alert.informativeText = "原生 Mac 硬件温度与风扇监视器\n\nUniversal 2 · macOS 13+\n传感器数据只在本机读取，不上传网络。"
        if let icon = NSImage(named: "AppIcon") { alert.icon = icon }
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func writePreviewImage() {
        guard let view = popover.contentViewController?.view else { return }
        view.layoutSubtreeIfNeeded()
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: "/tmp/thermometer-preview.png"), options: .atomic)
    }
}

final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class HUDDragSurfaceView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }
}

final class FloatingHUDController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let preferences: AppPreferences
    private let panel: HUDPanel
    private let hostingController: NSHostingController<AnyView>
    private let containerView: NSView
    private let effectView: NSVisualEffectView
    private var glassEffectView: NSView?
    private let dragSurfaceView: HUDDragSurfaceView
    private var isApplyingPosition = false

    init(model: AppModel, preferences: AppPreferences) {
        self.model = model
        self.preferences = preferences
        self.panel = HUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 88),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.hostingController = NSHostingController(rootView: AnyView(EmptyView()))
        self.containerView = NSView(frame: .zero)
        self.effectView = NSVisualEffectView(frame: .zero)
        self.dragSurfaceView = HUDDragSurfaceView(frame: .zero)
        super.init()

        panel.delegate = self
        panel.contentView = containerView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .utilityWindow

        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.appearance = NSAppearance(named: .aqua)
        effectView.wantsLayer = true
        effectView.translatesAutoresizingMaskIntoConstraints = false

        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        dragSurfaceView.translatesAutoresizingMaskIntoConstraints = false

        if #available(macOS 26.0, *) {
            let glassView = NSGlassEffectView(frame: .zero)
            glassView.style = .regular
            glassView.cornerRadius = 15
            glassView.tintColor = NSColor(calibratedWhite: 1, alpha: 0.14)
            glassView.appearance = NSAppearance(named: .aqua)
            glassView.contentView = NSView(frame: .zero)
            glassView.translatesAutoresizingMaskIntoConstraints = false
            glassEffectView = glassView
            containerView.addSubview(glassView)
        } else {
            containerView.addSubview(effectView)
        }
        containerView.addSubview(hostingController.view)
        containerView.addSubview(dragSurfaceView)
        var constraints = [
            hostingController.view.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: containerView.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            dragSurfaceView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            dragSurfaceView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            dragSurfaceView.topAnchor.constraint(equalTo: containerView.topAnchor),
            dragSurfaceView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ]
        if let glassEffectView {
            constraints.append(contentsOf: [
                glassEffectView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
                glassEffectView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
                glassEffectView.topAnchor.constraint(equalTo: containerView.topAnchor),
                glassEffectView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
            ])
        } else {
            constraints.append(contentsOf: [
                effectView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
                effectView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
                effectView.topAnchor.constraint(equalTo: containerView.topAnchor),
                effectView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
            ])
        }
        NSLayoutConstraint.activate(constraints)
        syncContent()
    }

    func sync() {
        syncContent()
        resizePanel()
        panel.ignoresMouseEvents = preferences.hudClickThrough
        dragSurfaceView.isHidden = preferences.hudClickThrough
        panel.level = preferences.hudAlwaysOnTop ? .floating : .normal
        panel.hasShadow = preferences.hudOpacity > 0.001
        syncGlassAppearance()
        positionPanel()

        if preferences.hudEnabled {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    func syncContent() {
        hostingController.rootView = AnyView(
            FloatingHUDView()
                .environmentObject(model)
                .environmentObject(model.preferences)
                .environment(\.colorScheme, preferences.hudBlur ? .light : .dark)
        )
    }

    private func syncGlassAppearance() {
        let cornerRadius = CGFloat(15 * preferences.hudScale)
        if #available(macOS 26.0, *),
           let glassView = glassEffectView as? NSGlassEffectView {
            glassView.isHidden = !preferences.hudBlur
            glassView.cornerRadius = cornerRadius
            glassView.style = .regular

            // Keep the glass dynamic while using a restrained light tint for
            // black text. The content is a sibling, so it always remains opaque.
            let strength = CGFloat(preferences.hudOpacity.clamped(to: 0...1.0))
            glassView.alphaValue = strength
            glassView.tintColor = NSColor(
                calibratedWhite: 1,
                alpha: 0.16
            )
        } else {
            effectView.isHidden = !preferences.hudBlur
            effectView.alphaValue = CGFloat(preferences.hudOpacity.clamped(to: 0...1.0))
            effectView.layer?.cornerRadius = cornerRadius
            effectView.layer?.masksToBounds = true
        }
    }

    func positionPanel() {
        guard let screen = preferredScreen() else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let margin: CGFloat = 18
        let x: CGFloat
        let y: CGFloat

        switch preferences.hudAnchor {
        case .custom:
            x = frame.minX + max(frame.width - size.width, 0) * CGFloat(preferences.hudCustomX)
        case .topLeft, .centerLeft, .bottomLeft:
            x = frame.minX + margin
        case .topCenter, .bottomCenter:
            x = frame.midX - size.width / 2
        case .topRight, .centerRight, .bottomRight:
            x = frame.maxX - size.width - margin
        }

        switch preferences.hudAnchor {
        case .custom:
            y = frame.minY + max(frame.height - size.height, 0) * CGFloat(preferences.hudCustomY)
        case .topLeft, .topCenter, .topRight:
            y = frame.maxY - size.height - margin
        case .centerLeft, .centerRight:
            y = frame.midY - size.height / 2
        case .bottomLeft, .bottomCenter, .bottomRight:
            y = frame.minY + margin
        }

        isApplyingPosition = true
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        isApplyingPosition = false
    }

    func windowDidMove(_ notification: Notification) {
        guard !isApplyingPosition,
              panel.isVisible,
              !preferences.hudClickThrough,
              let screen = screenContainingPanel() else { return }

        let frame = screen.visibleFrame
        let availableWidth = max(frame.width - panel.frame.width, 1)
        let availableHeight = max(frame.height - panel.frame.height, 1)
        let normalizedX = Double((panel.frame.minX - frame.minX) / availableWidth).clamped(to: 0...1)
        let normalizedY = Double((panel.frame.minY - frame.minY) / availableHeight).clamped(to: 0...1)
        preferences.saveHUDCustomPosition(
            x: normalizedX,
            y: normalizedY,
            screenID: screenIdentifier(screen)
        )
    }

    private func resizePanel() {
        let metricCount = max(preferences.hudMetrics.count, 1)
        let base: NSSize
        switch preferences.hudLayout {
        case .compact:
            base = NSSize(width: max(270, 76 * metricCount + 58), height: 82)
        case .cards:
            base = NSSize(width: 354, height: metricCount > 3 ? 218 : 174)
        case .vertical:
            base = NSSize(width: 252, height: CGFloat(58 + metricCount * 46))
        }
        let size = NSSize(
            width: base.width * preferences.hudScale,
            height: base.height * preferences.hudScale
        )
        panel.setContentSize(size)
    }

    private func preferredScreen() -> NSScreen? {
        if preferences.hudAnchor == .custom,
           preferences.hudCustomScreenID != 0,
           let savedScreen = NSScreen.screens.first(where: {
               screenIdentifier($0) == preferences.hudCustomScreenID
           }) {
            return savedScreen
        }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func screenContainingPanel() -> NSScreen? {
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        return NSScreen.screens.first(where: { NSMouseInRect(center, $0.frame, false) })
            ?? preferredScreen()
    }

    private func screenIdentifier(_ screen: NSScreen) -> Int {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.intValue ?? 0
    }
}
