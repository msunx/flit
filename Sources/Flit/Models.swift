import AppKit
import ApplicationServices

enum TargetKind: String, Codable {
    case desktop, fullscreen, window
    var label: String {
        switch self { case .desktop: return "桌面空间"; case .fullscreen: return "全屏窗口"; case .window: return "窗口" }
    }
}

struct SpaceInfo: Identifiable, @unchecked Sendable {
    let id: UInt64
    let uuid: String
    let displayUUID: String
    let displayID: CGDirectDisplayID
    let index: Int
    let desktopNumber: Int
    let isFullscreen: Bool
    let isCurrent: Bool
    var aliasKey: String { "space:\(displayUUID):\(uuid.isEmpty ? "session-\(id)" : uuid)" }
}

struct SwitchTarget: Identifiable, @unchecked Sendable {
    let id: String
    let originalTitle: String
    let appName: String
    let kind: TargetKind
    let processID: pid_t?
    let windowID: CGWindowID?
    let element: AXUIElement?
    let space: SpaceInfo?
    let icon: NSImage?
    let isMinimized: Bool
    let order: Int
}

struct ScanResult: @unchecked Sendable {
    let targets: [SwitchTarget]
    let spaces: [SpaceInfo]
    let spacesAvailable: Bool
}

enum DisplayMode: String, Codable, CaseIterable {
    case preview, list
    var label: String { self == .preview ? "预览" : "列表" }
}

struct Shortcut: Codable, Equatable {
    var keyCode: UInt16 = 48
    var modifiers: UInt64 = CGEventFlags.maskCommand.rawValue
    var keyName: String = "Tab"
    var flags: CGEventFlags { CGEventFlags(rawValue: modifiers) }
    var label: String {
        let pairs: [(CGEventFlags, String)] = [(.maskControl, "⌃"), (.maskAlternate, "⌥"), (.maskShift, "⇧"), (.maskCommand, "⌘")]
        return pairs.filter { flags.contains($0.0) }.map(\.1).joined() + " " + keyName
    }
    var releaseLabel: String {
        if flags.contains(.maskCommand) { return "⌘" }
        if flags.contains(.maskAlternate) { return "⌥" }
        if flags.contains(.maskControl) { return "⌃" }
        return "⇧"
    }
}

struct Preferences: Codable {
    var enabled = true
    var mode: DisplayMode = .preview
    var shortcut = Shortcut()
    var dockLockEnabled = false
    var dockDisplayUUID: String?
    var dockDisplayName: String?

    private enum CodingKeys: String, CodingKey { case enabled, mode, shortcut, dockLockEnabled, dockDisplayUUID, dockDisplayName }
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        mode = try values.decodeIfPresent(DisplayMode.self, forKey: .mode) ?? .preview
        shortcut = try values.decodeIfPresent(Shortcut.self, forKey: .shortcut) ?? Shortcut()
        dockLockEnabled = try values.decodeIfPresent(Bool.self, forKey: .dockLockEnabled) ?? false
        dockDisplayUUID = try values.decodeIfPresent(String.self, forKey: .dockDisplayUUID)
        dockDisplayName = try values.decodeIfPresent(String.self, forKey: .dockDisplayName)
    }
}

struct StoredState: Codable {
    var preferences = Preferences()
    var aliases: [String: String] = [:]
}

struct FlitFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

final class SettingsStore {
    private(set) var state = StoredState()
    private(set) var loadError: String?
    let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Flit/settings.json")
        guard FileManager.default.fileExists(atPath: self.fileURL.path) else { return }
        do { state = try JSONDecoder().decode(StoredState.self, from: Data(contentsOf: self.fileURL)) }
        catch { loadError = "无法读取已保存的设置：\(error.localizedDescription)。原文件已保留。" }
    }

    func save(_ state: StoredState) throws {
        if loadError != nil { throw FlitFailure("设置文件无法读取。请先备份并修复 \(fileURL.path)，防止覆盖已有名称。") }
        let data = try JSONEncoder().encode(state)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        self.state = state
    }
}

enum AX {
    static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result as? T
    }
    static func children(_ element: AXUIElement) -> [AXUIElement] { value(element, kAXChildrenAttribute) ?? [] }
    static func frame(_ element: AXUIElement) -> CGRect? {
        var position = CGPoint.zero
        var size = CGSize.zero
        guard let p: AXValue = value(element, kAXPositionAttribute), let s: AXValue = value(element, kAXSizeAttribute),
              AXValueGetValue(p, .cgPoint, &position), AXValueGetValue(s, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }
    static func find(_ root: AXUIElement, depth: Int = 6, predicate: (AXUIElement) -> Bool) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var cursor = 0
        while cursor < queue.count && cursor < 500 {
            let (element, level) = queue[cursor]
            cursor += 1
            if predicate(element) { result.append(element); continue }
            if level < depth { queue += children(element).map { ($0, level + 1) } }
        }
        return result
    }
}
