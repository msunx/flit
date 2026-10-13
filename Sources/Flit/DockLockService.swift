import AppKit
import Combine

struct DockScreen: Identifiable, Equatable {
    let id: String
    let displayID: CGDirectDisplayID
    let name: String
    let bounds: CGRect
    let isMain: Bool

    static func connected() -> [DockScreen] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
            return DockScreen(id: CFUUIDCreateString(nil, uuid) as String, displayID: number.uint32Value, name: screen.localizedName,
                              bounds: CGDisplayBounds(number.uint32Value), isMain: number.uint32Value == CGMainDisplayID())
        }
    }
}

/// Only exposed bottom edges can summon the Dock. Shared display edges remain traversable.
enum DockEdges {
    static let inset: CGFloat = 3

    static func exposed(on screen: DockScreen, among screens: [DockScreen]) -> [CGRect] {
        var spans = [screen.bounds.minX..<screen.bounds.maxX]
        for neighbor in screens where neighbor.id != screen.id && abs(neighbor.bounds.minY - screen.bounds.maxY) < 1 {
            let covered = neighbor.bounds.minX..<neighbor.bounds.maxX
            spans = spans.flatMap { span -> [Range<CGFloat>] in
                guard span.overlaps(covered) else { return [span] }
                var remainder: [Range<CGFloat>] = []
                if span.lowerBound < covered.lowerBound { remainder.append(span.lowerBound..<min(span.upperBound, covered.lowerBound)) }
                if span.upperBound > covered.upperBound { remainder.append(max(span.lowerBound, covered.upperBound)..<span.upperBound) }
                return remainder
            }
        }
        return spans.map { CGRect(x: $0.lowerBound, y: screen.bounds.maxY - inset, width: $0.upperBound - $0.lowerBound, height: inset) }
    }
}

struct DockLockStatus: Equatable {
    let title: String
    let detail: String
    var guarding = false
    static let off = DockLockStatus(title: "跟随系统", detail: "开启后，Dock 只响应所选屏幕的底部边缘。")
}

/// All access is on the main run loop, including the tap callback. The callback only reads cached rectangles.
final class DockLockService: ObservableObject {
    @Published private(set) var screens: [DockScreen] = []
    @Published private(set) var status = DockLockStatus.off
    private let demo: Bool
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var blockedEdges: [CGRect] = []
    private var locationTask: Task<Void, Never>?
    private var targetID: String?

    init(demo: Bool = false) { self.demo = demo }
    deinit { stop() }

    func configure(_ preferences: Preferences, accessibility: Bool) {
        guard !demo else { return }
        let connected = DockScreen.connected()
        if screens != connected { screens = connected }
        guard preferences.dockLockEnabled else { pause(.off); return }
        guard preferences.enabled else { pause(DockLockStatus(title: "已随 Flit 暂停", detail: "重新启用 Flit 后恢复 Dock 固定。")); return }
        guard accessibility else { pause(DockLockStatus(title: "等待辅助功能权限", detail: "在「权限与启动」中开启辅助功能即可，无需额外的录屏权限。")); return }
        guard let target = screens.first(where: { $0.id == preferences.dockDisplayUUID }) else {
            pause(DockLockStatus(title: "所选屏幕未连接", detail: "等待 \(preferences.dockDisplayName ?? "目标屏幕") 接入，或选择下方其他屏幕。")); return
        }
        guard screens.count > 1 else { pause(DockLockStatus(title: "当前只有一个屏幕", detail: "无需限制；接入其他屏幕后自动恢复。")); return }
        guard NSScreen.screensHaveSeparateSpaces else { pause(DockLockStatus(title: "系统已限制 Dock 所在屏幕", detail: "当前未使用独立显示器空间，Dock 由系统放在主屏幕。")); return }
        guard Self.orientation == "bottom" else { pause(DockLockStatus(title: "请将 Dock 放在底部", detail: "此功能适用于底部 Dock；在系统设置中改为底部后自动恢复。")); return }
        guard !DockEdges.exposed(on: target, among: screens).isEmpty else {
            pause(DockLockStatus(title: "所选屏幕没有独立底边", detail: "下方屏幕覆盖了整个底边，请选择其他屏幕或调整系统显示器排列。")); return
        }
        let edges = screens.filter { $0.id != target.id }.flatMap { DockEdges.exposed(on: $0, among: screens) }
        guard !edges.isEmpty else { pause(DockLockStatus(title: "当前排列无需限制", detail: "其他屏幕没有可唤出 Dock 的独立底边。")); return }
        guard start() else { pause(DockLockStatus(title: "鼠标监听未启动", detail: "请在系统设置检查 Flit 的辅助功能与输入监控权限，再重新开启。")); return }
        blockedEdges = edges
        if targetID != target.id || !status.guarding {
            updateStatus(DockLockStatus(title: "防换屏已开启", detail: "其他屏幕的底部不会再因鼠标停留而唤走 Dock。", guarding: true))
        }
        targetID = target.id
        // Dock AX requests can stall. Keep them off the event tap's main run loop.
        guard locationTask == nil else { return }
        let snapshot = screens
        locationTask = Task { @MainActor [weak self] in
            let location = await Task.detached(priority: .utility) { Self.detectDockScreen(in: snapshot) }.value
            guard let self else { return }
            defer { self.locationTask = nil }
            guard !Task.isCancelled, self.targetID == target.id, self.tap != nil else { return }
            if let location, location.id != target.id {
                self.updateStatus(DockLockStatus(title: "请在所选屏幕唤出一次 Dock", detail: "将鼠标移到 \(target.name) 的底部并继续向下，Dock 到达后就会留在那里。", guarding: true))
            } else {
                self.updateStatus(DockLockStatus(title: "防换屏已开启", detail: "其他屏幕的底部不会再因鼠标停留而唤走 Dock。", guarding: true))
            }
        }
    }

    func initialTarget() -> DockScreen? { (demo ? nil : currentDockScreen()) ?? screens.first(where: \.isMain) ?? screens.first }

    func currentDockScreen() -> DockScreen? { Self.detectDockScreen(in: screens) }

    private static func detectDockScreen(in screens: [DockScreen]) -> DockScreen? {
        guard AXIsProcessTrusted(), let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let root = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.15)
        let windows: [AXUIElement] = AX.value(root, kAXWindowsAttribute) ?? []
        // Newer Dock versions expose the icon list directly under the application instead of AXWindows.
        for window in windows + AX.children(root) {
            guard let frame = AX.frame(window), frame.width > 0, frame.height > 0 else { continue }
            // An auto-hidden Dock may extend beyond the display. Accept only a unique nearby bottom edge.
            let matches = screens.filter { frame.midX >= $0.bounds.minX && frame.midX < $0.bounds.maxX && abs(frame.minY - $0.bounds.maxY) <= max(160, frame.height + 12) }
            if matches.count == 1 { return matches[0] }
        }
        return nil
    }

    static var orientation: String { CFPreferencesCopyAppValue("orientation" as CFString, "com.apple.dock" as CFString) as? String ?? "bottom" }

    private func updateStatus(_ value: DockLockStatus) { if status != value { status = value } }
    private func pause(_ value: DockLockStatus) { stop(); updateStatus(value) }

    private func start() -> Bool {
        if let tap, CFMachPortIsValid(tap) { CGEvent.tapEnable(tap: tap, enable: true); return true }
        if tap != nil { stop() }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, pointer in
            guard let pointer else { return Unmanaged.passUnretained(event) }
            let service = Unmanaged<DockLockService>.fromOpaque(pointer).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = service.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            } else if let edge = service.blockedEdges.first(where: { $0.contains(event.location) }) {
                event.location = CGPoint(x: event.location.x, y: edge.minY)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()), let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else { return false }
        tap = port
        source = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        blockedEdges = []
        targetID = nil
        locationTask?.cancel()
    }

    func preview(screens: [DockScreen], status: DockLockStatus) {
        guard demo else { return }
        self.screens = screens
        self.status = status
    }

    func diagnose() {
        let preferences = SettingsStore().state.preferences
        screens = DockScreen.connected()
        print("Dock: orientation=\(Self.orientation), separateSpaces=\(NSScreen.screensHaveSeparateSpaces), accessibility=\(AXIsProcessTrusted())")
        print("Preference: enabled=\(preferences.dockLockEnabled), targetConnected=\(screens.contains { $0.id == preferences.dockDisplayUUID })")
        print("Current Dock display: \(currentDockScreen()?.name ?? "not detectable")")
        for screen in screens {
            print("Display: \(screen.name), main=\(screen.isMain), bounds=\(screen.bounds), exposedBottom=\(DockEdges.exposed(on: screen, among: screens))")
        }
        print("Read-only diagnosis: no event tap installed, no cursor movement.")
    }
}
