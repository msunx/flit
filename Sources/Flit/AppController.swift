import AppKit
import SwiftUI
import Combine

final class SwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    private let hotkeys = HotkeyService()
    private var statusItem: NSStatusItem!
    private var enabledItem: NSMenuItem!
    private var panel: SwitcherPanel?
    private var settingsWindow: NSWindow?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var subscriptions: Set<AnyCancellable> = []
    private var localMonitor: Any?
    private var outsideMonitor: Any?
    private var activationTask: Task<Void, Never>?
    private var panelGeneration = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
        model.onPreferencesChanged = { [weak self] in self?.applyPreferences() }
        model.onCommit = { [weak self] target in self?.activate(target) }
        model.onCancel = { [weak self] in self?.dismiss() }
        model.onSettings = { [weak self] in self?.openSettings() }
        model.onRenameChanged = { [weak self] editing in
            self?.hotkeys.editing = editing
            self?.hotkeys.holding = false
            self?.model.holding = false
        }
        model.$recordingShortcut.sink { [weak self] recording in self?.hotkeys.suspended = recording }.store(in: &subscriptions)
        hotkeys.canBegin = { [weak self] in
            guard let self else { return false }
            return self.model.accessibilityAllowed && !self.model.targets.isEmpty && !self.model.switching
        }
        // The event tap only queues UI work, keeping the system keyboard path responsive.
        hotkeys.onAction = { [weak self] action in
            DispatchQueue.main.async { self?.handle(action) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.model.visible, !self.model.renaming, !self.hotkeys.isRunning else { return event }
            switch event.keyCode {
            case 53: self.dismiss()
            case 36, 76: self.model.commit()
            case 123: self.model.step(-1)
            case 124: self.model.step(1)
            case 125: self.model.step(self.model.preferences.mode == .preview ? self.model.gridColumns : 1)
            case 126: self.model.step(self.model.preferences.mode == .preview ? -self.model.gridColumns : -1)
            case 120: self.model.rename()
            default: return event
            }
            return nil
        }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.model.visible, !self.model.renaming, !self.model.holding,
                  self.panel?.frame.contains(NSEvent.mouseLocation) != true else { return }
            self.dismiss()
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.model.refresh() }
            })
        }
        observers.append(workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.model.refresh(captureDesktop: true) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .flitShowSwitcher, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.show(holding: false) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applyPermissions() }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applyPermissions() }
        })
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.model.refresh()
                self.applyPermissions()
            }
        }
        model.refresh(captureDesktop: true)
        applyPreferences()
        if !model.accessibilityAllowed { openSettings() }
        if CommandLine.arguments.contains("--show") { show(holding: false) }
    }

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "Flit")
        statusItem.button?.toolTip = "Flit · 桌面与全屏窗口"
        let menu = NSMenu()
        menu.addItem(withTitle: "打开切换器", action: #selector(openSwitcher), keyEquivalent: "").target = self
        menu.addItem(withTitle: "偏好设置…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        enabledItem = menu.addItem(withTitle: "启用 Flit", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Flit", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu
    }

    private func applyPreferences() {
        hotkeys.shortcut = model.preferences.shortcut
        enabledItem?.state = model.preferences.enabled ? .on : .off
        applyPermissions()
        if model.visible { configurePanel(animated: true); model.capturePreviews() }
    }

    private func applyPermissions() {
        model.accessibilityAllowed = AXIsProcessTrusted()
        model.screenRecordingAllowed = CGPreflightScreenCaptureAccess()
        if model.preferences.enabled && model.accessibilityAllowed { model.hotkeyRunning = hotkeys.start() }
        else { if hotkeys.isRunning { dismiss() }; hotkeys.stop(); model.hotkeyRunning = false }
        statusItem.button?.appearsDisabled = !model.hotkeyRunning
        model.dockLock.configure(model.preferences, accessibility: model.accessibilityAllowed)
    }

    private func handle(_ action: SwitchAction) {
        switch action {
        case .begin(let reverse): show(holding: true, reverse: reverse)
        case .step(let distance): model.step(distance)
        case .row(let distance): model.step(distance * (model.preferences.mode == .preview ? model.gridColumns : 1))
        case .commit: model.commit()
        case .cancel: model.cancel()
        case .rename: model.rename()
        }
    }

    @objc private func openSwitcher() { show(holding: false) }
    @objc private func toggleEnabled() { model.setPreferences { $0.enabled.toggle() } }
    @objc private func quit() { NSApp.terminate(nil) }

    private func show(holding: Bool, reverse: Bool = false) {
        guard !model.switching else { return }
        if model.visible { return }
        panelGeneration += 1
        model.begin(holding: holding, reverse: reverse)
        hotkeys.visible = true
        hotkeys.holding = holding
        hotkeys.editing = false
        configurePanel(animated: false)
        guard let panel else { return }
        panel.alphaValue = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
            panel.animator().alphaValue = 1
        }
        if model.targets.isEmpty { model.refresh() }
    }

    private func configurePanel(animated: Bool) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        let available = screen.visibleFrame
        let width = min(model.preferences.mode == .preview ? 1120 : 660, available.width - 48)
        let height = min(model.preferences.mode == .preview ? 650 : 660, available.height - 72)
        model.gridColumns = width >= 940 ? 4 : width >= 690 ? 3 : 2
        let size = CGSize(width: width, height: height)
        let frame = CGRect(x: available.midX - width / 2, y: available.midY - height / 2, width: width, height: height)
        let panel = panel ?? {
            let panel = SwitcherPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.isFloatingPanel = true
            panel.isReleasedWhenClosed = false
            panel.animationBehavior = .none
            panel.delegate = self
            panel.appearance = NSAppearance(named: .aqua)
            self.panel = panel
            return panel
        }()
        if let host = panel.contentView as? NSHostingView<SwitcherView> { host.rootView = SwitcherView(model: model, size: size) }
        else { panel.contentView = NSHostingView(rootView: SwitcherView(model: model, size: size)) }
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in context.duration = 0.22; panel.animator().setFrame(frame, display: true) }
        } else { panel.setFrame(frame, display: true) }
    }

    private func dismiss(immediate: Bool = false) {
        guard model.visible else { return }
        model.end()
        hotkeys.visible = false
        hotkeys.holding = false
        hotkeys.editing = false
        let generation = panelGeneration
        guard let panel else { return }
        if immediate || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { panel.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup { context in context.duration = 0.12; panel.animator().alphaValue = 0 } completionHandler: { [weak self] in
            MainActor.assumeIsolated { if self?.panelGeneration == generation { panel.orderOut(nil) } }
        }
    }

    private func activate(_ target: SwitchTarget) {
        guard !model.switching else { return }
        dismiss(immediate: true)
        model.switching = true
        activationTask = Task {
            defer { model.switching = false; model.refresh(captureDesktop: true); activationTask = nil }
            do { try await WindowService.activate(target); model.didActivate(target) }
            catch {
                model.message = error.localizedDescription
                openSettings()
            }
        }
    }

    @objc private func openSettings() {
        dismiss(immediate: true)
        if settingsWindow == nil {
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: FlitUI.settingsSize), styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Flit · 偏好设置"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.backgroundColor = NSColor(Palette.surface)
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag && !model.visible { openSettings() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys.stop()
        model.dockLock.stop()
        timer?.invalidate()
        activationTask?.cancel()
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        for observer in observers { NotificationCenter.default.removeObserver(observer); NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}

@main
struct FlitMain {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--diagnose-dock") { DockLockService().diagnose(); return }
        if CommandLine.arguments.contains("--probe-spaces") {
            Task {
                do { try await SpaceProbe.run() }
                catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
                application.terminate(nil)
            }
            application.run()
            return
        }
        if CommandLine.arguments.contains("--diagnose") {
            let scan = WindowService.scan()
            print("Flit diagnostics · \(ProcessInfo.processInfo.operatingSystemVersionString)")
            print("Accessibility: \(AXIsProcessTrusted()) | Screen recording: \(CGPreflightScreenCaptureAccess())")
            print("Spaces API: \(scan.spacesAvailable) | Desktops: \(scan.spaces.filter { !$0.isFullscreen }.count) | Fullscreen spaces: \(scan.spaces.filter(\.isFullscreen).count)")
            print("Window targets: \(scan.targets.filter { $0.windowID != nil }.count)")
            print("Targets total: \(scan.targets.count) | AX windows: \(scan.targets.filter { $0.element != nil }.count)")
            let uniqueSpaces = Set(scan.targets.compactMap { $0.space?.id })
            print("Scope: desktops=\(scan.targets.filter { $0.kind == .desktop }.count), fullscreen=\(scan.targets.filter { $0.kind == .fullscreen }.count), ordinary windows=\(scan.targets.filter { $0.kind == .window }.count), unique spaces=\(uniqueSpaces.count)")
            print("One target per Space: \(scan.targets.count == scan.spaces.count && uniqueSpaces.count == scan.spaces.count)")
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != getpid() {
                let root = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(root, 0.5)
                var raw: CFTypeRef?
                let status = AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &raw)
                let windows = raw as? [AXUIElement] ?? []
                let roles = Dictionary(grouping: windows, by: { (AX.value($0, kAXSubroleAttribute) as String?) ?? "nil" }).map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: ",")
                print("\(app.bundleIdentifier ?? "unknown"): AX=\(status.rawValue), windows=\(windows.count), IDs=\(windows.filter { WindowService.windowID($0) != nil }.count), roles=[\(roles)]")
            }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-ui"), CommandLine.arguments.indices.contains(index + 1) {
            let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task {
                do { try await NativePreview.render(to: directory) }
                catch { fputs("Render failed: \(error)\n", stderr); exit(1) }
                application.terminate(nil)
            }
            application.run()
            return
        }
        let delegate = AppController()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
