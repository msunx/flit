import SwiftUI
import AppKit

enum SettingsTab: String, CaseIterable {
    case switching = "切换方式", dock = "Dock 固定", permissions = "权限与启动"
    var symbol: String {
        switch self { case .switching: return "keyboard"; case .dock: return "display"; case .permissions: return "checkmark.shield" }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var tab: SettingsTab
    @Namespace private var tabNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: AppModel, initialTab: SettingsTab = .switching) { self.model = model; _tab = State(initialValue: initialTab) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Text("Flit · 偏好设置").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.muted)
                Spacer()
            }.frame(height: 44).overlay(alignment: .trailing) { FlitMark().scaleEffect(0.7).padding(.trailing, 22) }
            HStack(spacing: 8) {
                ForEach(SettingsTab.allCases, id: \.self) { item in
                    Button { tab = item } label: {
                        Label(item.rawValue, systemImage: item.symbol).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(tab == item ? Palette.accent : Palette.muted).padding(.horizontal, 23).frame(height: 36)
                            .background { if tab == item { RoundedRectangle(cornerRadius: 10).fill(Palette.selection).matchedGeometryEffect(id: "settings-tab", in: tabNamespace) } }
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain).accessibilityAddTraits(tab == item ? .isSelected : [])
                }
            }.frame(height: 46)
            ScrollView {
                VStack(spacing: 0) {
                    if tab == .switching { switchingContent }
                    else if tab == .dock { DockSettingsView(model: model, service: model.dockLock) }
                    else { permissionsContent }
                    if let message = model.message {
                        Label(message, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(Palette.danger)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 16)
                    }
                }.padding(.horizontal, 42).padding(.top, 14).padding(.bottom, 15).frame(maxWidth: .infinity)
            }.scrollIndicators(.automatic)
            footer
        }.frame(width: FlitUI.settingsSize.width, height: FlitUI.settingsSize.height)
            .background(Palette.surface).foregroundStyle(Palette.ink).tint(Palette.accent).preferredColorScheme(.light)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: tab)
            .onChange(of: tab) { _, _ in NSApp.keyWindow?.makeFirstResponder(nil) }
    }

    private var switchingContent: some View {
        VStack(spacing: 0) {
            Text("你的切换快捷键").font(.system(size: 21, weight: .semibold, design: .rounded))
            Text("按住选择，松开即达。").font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.top, 6)
            ShortcutRecorder(shortcut: model.preferences.shortcut, recording: $model.recordingShortcut) { shortcut in model.setPreferences { $0.shortcut = shortcut } }
                .frame(width: 490, height: 82).padding(.top, 13)
            Text(model.recordingShortcut ? "按下新的组合键，Esc 取消录制" : "点击按键录制新组合 · ⇧ 反向选择 · Esc 取消")
                .font(.system(size: 11)).foregroundStyle(model.recordingShortcut ? Palette.accent : Palette.muted).frame(height: 22)
            HStack(spacing: 18) {
                ForEach(DisplayMode.allCases, id: \.self) { mode in
                    ModeChoice(mode: mode, selected: model.preferences.mode == mode) { model.setPreferences { $0.mode = mode }; model.capturePreviews() }
                }
            }.padding(.top, 19)
            HStack(spacing: 24) {
                Toggle("启用 Flit", isOn: Binding(get: { model.preferences.enabled }, set: { value in model.setPreferences { $0.enabled = value } }))
                    .toggleStyle(IrisToggleStyle()).fixedSize()
                Toggle("登录后启动", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) })).toggleStyle(IrisToggleStyle()).fixedSize()
                Spacer()
                Button { model.onCancel?(); NotificationCenter.default.post(name: .flitShowSwitcher, object: nil) } label: { Label("打开切换器", systemImage: "arrow.up.forward") }
                    .buttonStyle(IrisButtonStyle())
            }.font(.system(size: 12)).padding(.top, 21)
        }
    }

    private var permissionsContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "checkmark.shield").font(.system(size: 26, weight: .light)).foregroundStyle(Palette.accent)
                    .frame(width: 53, height: 53).background(Palette.selection, in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 5) {
                    Text("让 Flit 随时就绪").font(.system(size: 21, weight: .semibold, design: .rounded))
                }
            }.padding(.bottom, 25)
            permissionRow("辅助功能", detail: "响应全局快捷键，直接切换到桌面与全屏窗口。", symbol: "hand.raised", enabled: model.accessibilityAllowed, action: model.requestAccessibility)
            Divider().overlay(Palette.line).padding(.vertical, 18)
            permissionRow("屏幕录制", detail: "显示窗口画面；未开启时仍可按名称切换。", symbol: "rectangle.on.rectangle", enabled: model.screenRecordingAllowed, action: model.requestRecording)
            Divider().overlay(Palette.line).padding(.vertical, 18)
            HStack {
                VStack(alignment: .leading, spacing: 5) { Text("登录后启动").font(.system(size: 13, weight: .medium)); Text("下次开机时，Flit 自动就绪。").font(.system(size: 12)).foregroundStyle(Palette.muted) }
                Spacer()
                Toggle(isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) })) { EmptyView() }.toggleStyle(IrisToggleStyle()).accessibilityLabel("登录后启动")
            }
            if model.accessibilityAllowed && model.preferences.enabled && !model.hotkeyRunning {
                HStack(spacing: 12) {
                    Label("快捷键监听未启动，请检查输入监控权限。", systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(Palette.warning)
                    Spacer()
                    Button("检查权限") { model.openPrivacy("Privacy_ListenEvent") }.buttonStyle(IrisButtonStyle())
                }.padding(.top, 22)
            }
        }.padding(.top, 6)
    }

    private func permissionRow(_ title: String, detail: String, symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 13) {
            Image(systemName: symbol).font(.system(size: 18, weight: .regular)).foregroundStyle(Palette.accent).frame(width: 28)
            VStack(alignment: .leading, spacing: 6) { Text(title).font(.system(size: 14, weight: .medium)); Text(detail).font(.system(size: 12)).foregroundStyle(Palette.muted) }
            Spacer(minLength: 20)
            if enabled { Label("已开启", systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(Palette.success) }
            else { Button("前往开启", action: action).buttonStyle(IrisButtonStyle(prominent: true)).font(.system(size: 12)) }
        }.frame(minHeight: 49)
    }

    private var footer: some View {
        HStack(spacing: 17) {
            Button { tab = .permissions } label: { Label(model.accessibilityAllowed ? "辅助功能已开启" : "辅助功能未开启", systemImage: model.accessibilityAllowed ? "checkmark" : "exclamationmark.circle") }
            Button { tab = .permissions } label: { Label(model.screenRecordingAllowed ? "屏幕录制已开启" : "屏幕录制未开启", systemImage: model.screenRecordingAllowed ? "checkmark" : "exclamationmark.circle") }
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(model.hotkeyRunning ? Palette.success : Palette.warning).frame(width: 5, height: 5)
                Text(model.hotkeyRunning ? "已就绪" : model.preferences.enabled ? "等待权限" : "已暂停")
            }
            Text("Flit \(FlitUI.version)")
        }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.horizontal, 42).frame(height: 48)
            .overlay(alignment: .top) { Palette.line.frame(height: 1).padding(.horizontal, 42) }
    }
}

struct ModeChoice: View {
    let mode: DisplayMode
    let selected: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 15) {
                ModeDiagram(mode: mode).frame(width: 134, height: 79).padding(7).background(.white, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line, lineWidth: 1))
                    .rotationEffect(.degrees(mode == .preview ? -3 : 2)).shadow(color: Palette.accent.opacity(0.055), radius: 4, y: 3).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(mode == .preview ? "窗口预览" : "紧凑列表").font(.system(size: 13, weight: .semibold))
                    Text(mode == .preview ? "通过画面与名称\n识别窗口" : "只看名称\n快速定位")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(15).frame(maxWidth: .infinity, minHeight: 121)
                .background(selected ? Palette.selection.opacity(0.32) : .white.opacity(hovering ? 1 : 0.65), in: RoundedRectangle(cornerRadius: 15))
                .overlay(RoundedRectangle(cornerRadius: 15).stroke(selected ? Palette.focus : Palette.line, lineWidth: selected ? 1.2 : 1))
                .overlay(alignment: .topTrailing) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.system(size: 13)).foregroundStyle(selected ? Palette.accent : Palette.line).padding(12)
                }.contentShape(RoundedRectangle(cornerRadius: 15))
        }.buttonStyle(.plain).onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: selected)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: hovering)
            .accessibilityLabel(mode == .preview ? "窗口预览" : "紧凑列表").accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ModeDiagram: View {
    let mode: DisplayMode
    var body: some View {
        Group {
            if mode == .preview {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(0..<4) { index in
                        VStack(alignment: .leading, spacing: 3) {
                            RoundedRectangle(cornerRadius: 2).fill(index == 1 ? Palette.accent.opacity(0.7) : Palette.muted.opacity(0.19)).frame(height: 4)
                            HStack(spacing: 3) { RoundedRectangle(cornerRadius: 2).fill(Palette.line).frame(width: 12); VStack(spacing: 3) { ForEach(0..<3) { _ in Capsule().fill(Palette.muted.opacity(0.24)).frame(height: 2) } } }
                        }.padding(5).frame(height: 34).background(index == 1 ? Palette.selection : Palette.inset, in: RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(index == 1 ? Palette.accent : .clear, lineWidth: 1))
                    }
                }
            } else {
                VStack(spacing: 5) {
                    ForEach(0..<3) { index in
                        HStack(spacing: 6) { RoundedRectangle(cornerRadius: 3).fill(index == 1 ? Palette.accent : Palette.accentSoft).frame(width: 10, height: 10); Capsule().fill(Palette.muted.opacity(0.42)).frame(width: 66, height: 3); Spacer(minLength: 0) }
                            .padding(5).background(index == 1 ? Palette.selection : .clear, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
        }
    }
}

extension Notification.Name { static let flitShowSwitcher = Notification.Name("FlitShowSwitcher") }

struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: Shortcut
    @Binding var recording: Bool
    let onChange: (Shortcut) -> Void
    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel("全局快捷键")
        view.setAccessibilityHelp("点击后按下新的组合键，Esc 取消")
        view.onRecord = { recording = $0 }
        view.onChange = onChange
        return view
    }
    func updateNSView(_ view: RecorderView, context: Context) { view.shortcut = shortcut; view.setAccessibilityValue(shortcut.label); view.needsDisplay = true }
}

final class RecorderView: NSView {
    var shortcut = Shortcut()
    var onRecord: ((Bool) -> Void)?
    var onChange: ((Shortcut) -> Void)?
    private var recording = false
    private var hint: String?
    override var acceptsFirstResponder: Bool { true }
    private func beginRecording() { window?.makeFirstResponder(self); recording = true; hint = nil; onRecord?(true); needsDisplay = true }
    override func accessibilityPerformPress() -> Bool { beginRecording(); return true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return false }
        keyDown(with: event)
        return true
    }
    override func mouseDown(with event: NSEvent) { beginRecording() }
    override func resignFirstResponder() -> Bool { recording = false; onRecord?(false); needsDisplay = true; return true }
    override func keyDown(with event: NSEvent) {
        guard recording else { if event.keyCode == 36 || event.keyCode == 49 { beginRecording() }; return }
        if event.keyCode == 53 { window?.makeFirstResponder(nil); return }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.intersection([.command, .option, .control]).isEmpty else { hint = "请同时按 ⌘、⌥ 或 ⌃"; needsDisplay = true; return }
        let names: [UInt16: String] = [48: "Tab", 49: "Space", 36: "Return", 51: "Delete", 123: "←", 124: "→", 125: "↓", 126: "↑", 120: "F2"]
        let name = names[event.keyCode] ?? (event.charactersIgnoringModifiers?.uppercased().trimmingCharacters(in: .controlCharacters) ?? "")
        guard !name.isEmpty else { hint = "请选择其他按键"; needsDisplay = true; return }
        let shortcut = Shortcut(keyCode: event.keyCode, modifiers: UInt64(flags.rawValue), keyName: name)
        self.shortcut = shortcut
        onChange?(shortcut)
        window?.makeFirstResponder(nil)
    }
    override func draw(_ dirtyRect: NSRect) {
        let values = shortcut.label.split(separator: " ", maxSplits: 1).map(String.init)
        let parts = (values.first ?? "⌘").map(String.init) + [values.count > 1 ? values[1] : shortcut.keyName]
        let gap: CGFloat = 12
        let widths = parts.enumerated().map { index, value -> CGFloat in
            let font = NSFont.systemFont(ofSize: index == parts.count - 1 ? 24 : 29, weight: .regular)
            let size = (value as NSString).size(withAttributes: [.font: font])
            return max(index == parts.count - 1 ? 88 : 66, size.width + 32)
        }
        let total = widths.reduce(0, +) + gap * CGFloat(max(0, parts.count - 1))
        var x = (bounds.width - total) / 2
        for (index, value) in parts.enumerated() {
            let rect = CGRect(x: x, y: 10, width: widths[index], height: 64)
            NSColor(calibratedRed: 0.90, green: 0.87, blue: 0.94, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect.offsetBy(dx: 0, dy: -4), xRadius: 12, yRadius: 12).fill()
            NSColor.white.setFill()
            let key = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
            key.fill()
            (recording ? Palette.nsAccent : NSColor(calibratedRed: 0.86, green: 0.82, blue: 0.92, alpha: 1)).setStroke()
            key.lineWidth = recording ? 1.5 : 1
            key.stroke()
            let font = NSFont.systemFont(ofSize: index == parts.count - 1 ? 24 : 29, weight: .regular)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Palette.nsAccent]
            let size = (value as NSString).size(withAttributes: attrs)
            (value as NSString).draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)
            x += widths[index] + gap
        }
        if let hint {
            NSColor.white.withAlphaComponent(0.97).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 40, dy: 5), xRadius: 12, yRadius: 12).fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: Palette.nsAccent]
            let size = (hint as NSString).size(withAttributes: attrs)
            (hint as NSString).draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attrs)
        }
    }
}
