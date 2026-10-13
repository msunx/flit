import AppKit
import SwiftUI

/// Renders the actual native views with fixed, synthetic content. Never reads user windows or enables the hotkey tap.
@MainActor
enum NativePreview {
    static func render(to directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("flit-preview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = SettingsStore(fileURL: scratch.appendingPathComponent("settings.json"))
        let model = AppModel(demo: true, store: store)
        model.accessibilityAllowed = true
        model.screenRecordingAllowed = true
        model.hotkeyRunning = true
        model.holding = true
        let content: [(String, String, TargetKind, String, NSColor)] = [
            ("桌面 1 · 日常", "桌面空间", .desktop, "rectangle.3.group", NSColor(calibratedRed: 0.4, green: 0.56, blue: 0.68, alpha: 1)),
            ("Flit · 开发", "Visual Studio Code", .fullscreen, "chevron.left.forwardslash.chevron.right", .systemBlue),
            ("产品设计", "Figma", .fullscreen, "square.stack.3d.up.fill", .systemPurple),
            ("阅读与灵感", "Safari", .fullscreen, "safari", .systemTeal),
            ("桌面 2 · 专注", "桌面空间", .desktop, "rectangle.3.group", NSColor(calibratedRed: 0.4, green: 0.56, blue: 0.68, alpha: 1)),
            ("本周计划", "备忘录", .fullscreen, "note.text", .systemYellow),
            ("接口开发", "Cursor", .fullscreen, "chevron.left.forwardslash.chevron.right", .darkGray),
            ("设计素材", "预览", .fullscreen, "photo", .systemBlue)
        ]
        for (index, item) in content.enumerated() {
            let id = "preview-\(index)"
            model.targets.append(SwitchTarget(id: id, originalTitle: item.0, appName: item.1, kind: item.2, processID: nil, windowID: nil, element: nil, space: nil,
                                              icon: item.2 == .desktop ? nil : icon(symbol: item.3, color: item.4), isMinimized: false, order: index))
            model.thumbnails[id] = thumbnail(index: index, title: item.0)
        }
        model.selectedID = "preview-1"
        try await capture(SwitcherView(model: model, size: CGSize(width: 1120, height: 650)), size: CGSize(width: 1120, height: 650), to: directory.appendingPathComponent("overview.png"))
        model.setPreferences { $0.mode = .list }
        try await capture(SwitcherView(model: model, size: CGSize(width: 660, height: 660)), size: CGSize(width: 660, height: 660), to: directory.appendingPathComponent("list.png"))
        try await capture(SettingsView(model: model), size: FlitUI.settingsSize, to: directory.appendingPathComponent("settings.png"))
        try await capture(SettingsView(model: model, initialTab: .permissions), size: FlitUI.settingsSize, to: directory.appendingPathComponent("settings-permissions.png"))
        let dockScreens = [
            DockScreen(id: "demo-main", displayID: 1, name: "Mi Monitor", bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440), isMain: true),
            DockScreen(id: "demo-side", displayID: 2, name: "PHL 276B9", bounds: CGRect(x: -1440, y: 0, width: 1440, height: 2560), isMain: false)
        ]
        model.dockLock.preview(screens: dockScreens, status: .off)
        try await capture(SettingsView(model: model, initialTab: .dock), size: FlitUI.settingsSize, to: directory.appendingPathComponent("settings-dock-off.png"))
        model.selectDockScreen(dockScreens[0])
        model.setDockLock(true)
        model.dockLock.preview(screens: dockScreens, status: DockLockStatus(title: "防换屏已开启", detail: "其他屏幕的底部不会再因鼠标停留而唤走 Dock。", guarding: true))
        try await capture(SettingsView(model: model, initialTab: .dock), size: FlitUI.settingsSize, to: directory.appendingPathComponent("settings-dock-on.png"))
        model.dockLock.preview(screens: [dockScreens[1]], status: DockLockStatus(title: "所选屏幕未连接", detail: "等待 Mi Monitor 接入，或选择下方其他屏幕。"))
        try await capture(SettingsView(model: model, initialTab: .dock), size: FlitUI.settingsSize, to: directory.appendingPathComponent("settings-dock-disconnected.png"))
        let savedDock = SettingsStore(fileURL: store.fileURL).state.preferences
        guard savedDock.dockLockEnabled && savedDock.dockDisplayUUID == dockScreens[0].id else { throw FlitFailure("Dock 设置保存后读回不一致") }
        let legacy = Data(#"{"preferences":{"enabled":false,"mode":"list","shortcut":{"keyCode":48,"modifiers":524288,"keyName":"Tab"}},"aliases":{"space:old":"工作"}}"#.utf8)
        let migrated = try JSONDecoder().decode(StoredState.self, from: legacy)
        guard !migrated.preferences.enabled && migrated.preferences.mode == .list && migrated.preferences.shortcut.modifiers == 524288,
              !migrated.preferences.dockLockEnabled && migrated.preferences.dockDisplayUUID == nil && migrated.aliases["space:old"] == "工作" else { throw FlitFailure("旧配置迁移改变了已有设置") }
        print("PASS: Dock preference save/reload; legacy settings preserve aliases, shortcut, mode and enabled state with Dock lock off.")
        model.accessibilityAllowed = false
        model.screenRecordingAllowed = false
        model.hotkeyRunning = false
        try await capture(SettingsView(model: model, initialTab: .permissions), size: FlitUI.settingsSize, to: directory.appendingPathComponent("settings-needs-permissions.png"))
        model.accessibilityAllowed = true
        model.screenRecordingAllowed = true
        model.hotkeyRunning = true
        let renderer = ImageRenderer(content: FlitAppIcon())
        renderer.scale = 2
        if let image = renderer.cgImage, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) { try data.write(to: directory.appendingPathComponent("app-icon.png")) }
        model.renameDraft = "Flit 开发空间"
        try await capture(RenameView(model: model), size: CGSize(width: 430, height: 260), to: directory.appendingPathComponent("rename.png"))
        model.setPreferences { $0.mode = .preview }
        model.screenRecordingAllowed = false
        model.thumbnails = [:]
        try await capture(SwitcherView(model: model, size: CGSize(width: 1120, height: 650)), size: CGSize(width: 1120, height: 650), to: directory.appendingPathComponent("permission.png"))
        model.query = "没有匹配的名称"
        model.searchChanged()
        try await capture(SwitcherView(model: model, size: CGSize(width: 660, height: 560)), size: CGSize(width: 660, height: 560), to: directory.appendingPathComponent("empty.png"))

        // Exercise the view model's save/reload and failure paths using a temporary file only.
        model.query = ""
        model.selectedID = "preview-1"
        model.rename()
        model.renameDraft = "开发空间"
        model.saveName()
        guard SettingsStore(fileURL: store.fileURL).state.aliases["preview-1"] == "开发空间" else { throw FlitFailure("名称保存后读回不一致") }
        model.rename()
        model.renameDraft = "  "
        model.saveName()
        guard model.renaming && model.renameError != nil && model.renameDraft == "  " else { throw FlitFailure("空名称错误状态未保留") }
        let invalidURL = scratch.appendingPathComponent("invalid.json")
        try Data("invalid".utf8).write(to: invalidURL)
        let failed = AppModel(demo: true, store: SettingsStore(fileURL: invalidURL))
        failed.targets = model.targets
        failed.selectedID = model.selectedID
        failed.rename()
        failed.renameDraft = "保留输入"
        failed.saveName()
        let preservedFile = try String(contentsOf: invalidURL, encoding: .utf8)
        guard failed.renaming && failed.renameError != nil && failed.renameDraft == "保留输入" && preservedFile == "invalid" else {
            throw FlitFailure("保存失败时输入或原文件丢失")
        }
        print("PASS: native views rendered; rename save/reload, invalid input and failed save preserved.")
    }

    static func capture<V: View>(_ view: V, size: CGSize, to url: URL) async throws {
        let frame = CGRect(origin: .zero, size: size)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .white
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.setFrameOrigin(CGPoint(x: -4000, y: -4000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        host.frame = frame
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(180))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw FlitFailure("无法建立界面图像") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw FlitFailure("无法导出 PNG") }
        try data.write(to: url)
    }

    private static func icon(symbol: String, color: NSColor) -> NSImage {
        NSImage(size: CGSize(width: 64, height: 64), flipped: false) { rect in
            color.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 4, dy: 4), xRadius: 13, yRadius: 13).fill()
            if let symbol = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 29, weight: .medium)) {
                let image = symbol.copy() as! NSImage
                image.isTemplate = false
                image.draw(in: rect.insetBy(dx: 16, dy: 16))
            }
            return true
        }
    }

    private static func thumbnail(index: Int, title: String) -> NSImage {
        NSImage(size: CGSize(width: 560, height: 340), flipped: false) { rect in
            let dark = index == 1 || index == 6
            let desktop = index == 0 || index == 4
            (dark ? NSColor(calibratedWhite: 0.12, alpha: 1) : NSColor(calibratedRed: 0.96, green: 0.97, blue: 0.99, alpha: 1)).setFill()
            rect.fill()
            if desktop {
                NSGradient(starting: NSColor(calibratedRed: 0.68, green: 0.79, blue: 0.87, alpha: 1), ending: NSColor(calibratedRed: 0.88, green: 0.92, blue: 0.94, alpha: 1))?.draw(in: rect, angle: -30)
                for i in 0..<2 {
                    NSColor.white.withAlphaComponent(0.85).setFill()
                    NSBezierPath(roundedRect: CGRect(x: 45 + i * 190, y: 50 + i * 45, width: 265, height: 190), xRadius: 8, yRadius: 8).fill()
                }
            } else if index == 2 {
                NSColor(calibratedRed: 0.91, green: 0.93, blue: 0.97, alpha: 1).setFill()
                CGRect(x: 65, y: 0, width: 435, height: 310).fill()
                for i in 0..<3 {
                    NSColor.white.setFill()
                    NSBezierPath(roundedRect: CGRect(x: 92 + i * 130, y: 58, width: 110, height: 196), xRadius: 8, yRadius: 8).fill()
                    NSColor(calibratedRed: 0.35, green: 0.52, blue: 0.65, alpha: 1).setFill()
                    NSBezierPath(roundedRect: CGRect(x: 105 + i * 130, y: 176, width: 84, height: 48), xRadius: 5, yRadius: 5).fill()
                }
            } else {
                (dark ? NSColor(calibratedWhite: 0.17, alpha: 1) : NSColor(calibratedWhite: 0.93, alpha: 1)).setFill()
                CGRect(x: 0, y: 0, width: 105, height: 310).fill()
                let lines = dark ? ["import SwiftUI", "", "struct WorkspaceView: View {", "    @State private var selected = 0", "", "    var body: some View {", "        WindowGrid(selection: $selected)", "            .animation(.snappy)", "    }", "}"] : [title, "", "把工作放在顺手的位置。", "", "窗口、桌面与正在进行的事", "在清晰的空间里继续。", "", "Today · 10:30", "Design / Develop / Explore"]
                for (i, line) in lines.enumerated() {
                    let color = dark ? NSColor(calibratedRed: 0.63, green: 0.78, blue: 0.84, alpha: 1) : NSColor(calibratedWhite: 0.35, alpha: 1)
                    (line as NSString).draw(at: CGPoint(x: 127, y: 274 - i * 23), withAttributes: [.font: dark ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) : NSFont.systemFont(ofSize: i == 0 ? 18 : 12), .foregroundColor: color])
                }
            }
            (dark ? NSColor(calibratedWhite: 0.2, alpha: 1) : NSColor.white).setFill()
            CGRect(x: 0, y: 310, width: 560, height: 30).fill()
            for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                color.withAlphaComponent(0.7).setFill()
                NSBezierPath(ovalIn: CGRect(x: 12 + i * 17, y: 319, width: 9, height: 9)).fill()
            }
            return true
        }
    }
}
