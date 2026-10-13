import SwiftUI
import AppKit

struct GlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .aqua)
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) { }
}

struct TargetIcon: View {
    let target: SwitchTarget
    var size: CGFloat = 29
    var body: some View {
        Group {
            if let icon = target.icon { Image(nsImage: icon).resizable().interpolation(.high).scaledToFit() }
            else {
                Image(systemName: target.kind == .desktop ? "rectangle.3.group" : "macwindow")
                    .font(.system(size: size * 0.56, weight: .medium)).foregroundStyle(Palette.accent)
                    .frame(width: size, height: size).background(Palette.selection, in: RoundedRectangle(cornerRadius: size * 0.24))
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct KeyCap: View {
    let title: String
    var body: some View {
        Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted).padding(.horizontal, 5).frame(minWidth: 21, minHeight: 20)
            .background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 4)).overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.line, lineWidth: 1))
    }
}

struct SwitcherView: View {
    @ObservedObject var model: AppModel
    let size: CGSize
    @Namespace private var selectionNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool
    var animation: Animation? { reduceMotion ? nil : .snappy(duration: 0.2, extraBounce: 0) }
    var hasNotice: Bool { model.message != nil || !model.accessibilityAllowed || (!model.screenRecordingAllowed && model.preferences.mode == .preview) || !model.spacesAvailable }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Palette.muted)
                TextField("搜索名称或应用…", text: $model.query).textFieldStyle(.plain).font(.system(size: 13)).focused($searchFocused)
                    .onChange(of: model.query) { _, _ in model.searchChanged() }
                if !model.query.isEmpty { Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).help("清除搜索") }
            }.padding(.horizontal, 28).frame(height: 36).padding(.bottom, 12)
            if let message = model.message { notice(message, symbol: "exclamationmark.circle", action: nil) }
            else if !model.accessibilityAllowed { notice("开启辅助功能权限，才能切换全屏窗口与桌面。", symbol: "hand.raised", action: "去设置") }
            else if !model.screenRecordingAllowed && model.preferences.mode == .preview && !model.filtered.isEmpty { notice("开启屏幕录制权限后显示预览，仍可按名称切换。", symbol: "rectangle.dashed", action: "去设置") }
            else if !model.spacesAvailable { notice("当前系统的空间信息不可用，请重新读取或重启 Flit。", symbol: "rectangle.3.group", action: nil) }
            content
            footer
        }
        .frame(width: size.width, height: size.height)
        .background(Palette.surface.opacity(0.96)).background(GlassBackground())
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.9), lineWidth: 1))
        .foregroundStyle(Palette.ink).tint(Palette.accent).preferredColorScheme(.light)
        .sheet(isPresented: $model.renaming, onDismiss: { model.onRenameChanged?(false) }) { RenameView(model: model) }
        .onExitCommand { model.cancel() }
        .onSubmit { model.commit() }
        .onAppear { searchFocused = !model.holding }
    }

    private var header: some View {
        HStack(spacing: 14) {
            FlitMark()
            Text("桌面与全屏窗口").font(.system(size: 14, weight: .semibold))
            Text("\(model.filtered.count) 项").font(.system(size: 12)).foregroundStyle(Palette.muted)
            Spacer()
            ModePicker(selection: model.preferences.mode) { mode in model.setPreferences { $0.mode = mode }; model.capturePreviews() }
            KeyCap(title: model.preferences.shortcut.label)
            Button { model.onSettings?() } label: { Image(systemName: "gearshape").font(.system(size: 14)) }.buttonStyle(.plain).foregroundStyle(Palette.muted).frame(width: 28, height: 28).contentShape(Rectangle()).help("偏好设置").accessibilityLabel("偏好设置")
        }.padding(.horizontal, 28).frame(height: 70)
    }

    @ViewBuilder private var content: some View {
        if model.filtered.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: model.loading ? "arrow.triangle.2.circlepath" : "macwindow").font(.system(size: 34, weight: .light)).foregroundStyle(Palette.muted)
                Text(model.loading ? "正在读取窗口…" : (model.query.isEmpty ? "暂时没有可切换的窗口" : "没有匹配的空间或窗口")).font(.system(size: 16, weight: .medium))
                if !model.query.isEmpty { Button("清除搜索") { model.query = "" } }
                else if !model.accessibilityAllowed { Button("开启辅助功能") { model.requestAccessibility() } }
                else { Button("重新读取") { model.refresh() } }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    if model.preferences.mode == .preview {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: model.gridColumns), spacing: 16) {
                            ForEach(model.filtered) { target in item(target, list: false).id(target.id) }
                        }.padding(.horizontal, 27).padding(.vertical, 15)
                    } else {
                        LazyVStack(spacing: 3) { ForEach(model.filtered) { target in item(target, list: true).id(target.id) } }.padding(.horizontal, 18).padding(.vertical, 4)
                    }
                }.scrollIndicators(.automatic)
                    .onAppear { if let id = model.selectedID { proxy.scrollTo(id) } }
                    .onChange(of: model.selectedID) { _, id in if let id { withAnimation(animation) { proxy.scrollTo(id) } } }
            }.padding(.bottom, 18)
        }
    }

    private func item(_ target: SwitchTarget, list: Bool) -> some View {
        let selected = model.selectedID == target.id
        return Button { model.select(target.id); model.commit() } label: {
            Group {
                if list {
                    HStack(spacing: 12) {
                        Text(String(format: "%02d", (model.filtered.firstIndex(where: { $0.id == target.id }) ?? 0) + 1)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted).frame(width: 20)
                        TargetIcon(target: target)
                        identity(target, list: true)
                        Spacer(minLength: 6)
                        Text(target.isMinimized ? "最小化" : target.kind.label).font(.system(size: 11)).foregroundStyle(Palette.muted)
                        Image(systemName: "return").foregroundStyle(Palette.accent).opacity(selected ? 1 : 0)
                    }.padding(.horizontal, 13).frame(height: 55)
                } else if !model.screenRecordingAllowed && model.thumbnails[target.id] == nil {
                    VStack(alignment: .leading, spacing: 13) {
                        HStack { TargetIcon(target: target, size: 32); Spacer(); Text(target.kind.label).font(.system(size: 10)).foregroundStyle(Palette.muted) }
                        identity(target)
                    }.padding(18).frame(maxWidth: .infinity, minHeight: 122, alignment: .leading)
                        .background(selected ? Palette.selection : .white, in: RoundedRectangle(cornerRadius: 13))
                        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(selected ? Palette.focus : Palette.line, lineWidth: 1))
                } else {
                    VStack(alignment: .leading, spacing: 11) {
                        thumbnail(target)
                            .padding(3)
                            .background {
                                if selected {
                                    RoundedRectangle(cornerRadius: 11).fill(Palette.selection).overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Palette.line, lineWidth: 1))
                                        .padding(.horizontal, 8).offset(y: 7)
                                    RoundedRectangle(cornerRadius: 11).fill(.white).overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Palette.line, lineWidth: 1))
                                        .padding(.horizontal, 4).offset(y: 3)
                                }
                            }
                            .background(.white, in: RoundedRectangle(cornerRadius: 12))
                            .shadow(color: Palette.ink.opacity(selected ? 0.12 : 0.04), radius: selected ? 8 : 3, y: selected ? 4 : 2)
                            .overlay {
                                if selected { RoundedRectangle(cornerRadius: 11).strokeBorder(Palette.focus, lineWidth: 1.2).padding(-1).matchedGeometryEffect(id: "preview-selection", in: selectionNamespace) }
                            }
                            .overlay(alignment: .topTrailing) {
                                if selected { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white).frame(width: 17, height: 17).background(Palette.accent, in: Circle()).overlay(Circle().strokeBorder(.white, lineWidth: 1.5)).padding(8) }
                            }
                        HStack(spacing: 9) {
                            TargetIcon(target: target)
                            identity(target)
                            Spacer(minLength: 0)
                        }.padding(.horizontal, 2).padding(.bottom, 4)
                    }.padding(5).offset(y: selected && !reduceMotion ? -3 : 0)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    if selected && list {
                        RoundedRectangle(cornerRadius: 11).fill(Palette.selection)
                            .matchedGeometryEffect(id: "selection", in: selectionNamespace)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).animation(animation, value: model.selectedID)
            .help("\(model.title(target))\n\(target.originalTitle) · \(target.appName) · \(target.kind.label)")
            .accessibilityLabel("\(model.title(target))，\(target.appName)，\(target.kind.label)")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .contextMenu { Button("重命名…") { model.select(target.id); model.rename() }; Button("切换到此窗口") { model.select(target.id); model.commit() } }
    }

    private func identity(_ target: SwitchTarget, list: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.title(target)).font(.system(size: 13, weight: .semibold)).foregroundStyle(model.selectedID == target.id ? Palette.accent : Palette.ink).lineLimit(1).truncationMode(.middle)
            if !list || target.kind != .desktop { Text(target.appName).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func thumbnail(_ target: SwitchTarget) -> some View {
        (model.thumbnails[target.id] == nil ? Color.white.opacity(0.55) : Palette.inset).aspectRatio(hasNotice ? 2.05 : 1.65, contentMode: .fit)
            .overlay {
                if let image = model.thumbnails[target.id] { Image(nsImage: image).resizable().scaledToFit() }
                else {
                    VStack(spacing: 9) {
                        Image(systemName: target.kind == .desktop ? "rectangle.3.group" : "macwindow").font(.system(size: 24, weight: .ultraLight)).foregroundStyle(Palette.line)
                        if model.screenRecordingAllowed { Text(target.kind == .desktop ? "切换后生成预览" : "暂无预览").font(.system(size: 10)).foregroundStyle(Palette.muted) }
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Text(target.kind == .desktop && model.thumbnails[target.id] != nil ? "桌面空间 · 最近预览" : target.kind.label)
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(Palette.muted).padding(.horizontal, 6).padding(.vertical, 4)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4)).padding(6)
            }.clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(model.thumbnails[target.id] == nil ? Palette.line.opacity(0.65) : .clear, lineWidth: 1))
    }

    private var footer: some View {
        HStack(spacing: 18) {
            if !model.filtered.isEmpty {
            HStack(spacing: 6) { KeyCap(title: model.holding ? model.preferences.shortcut.releaseLabel : "↵"); Text(model.holding ? "松开切换" : "确认切换") }
            HStack(spacing: 5) { KeyCap(title: model.preferences.mode == .list ? "↑" : "←"); KeyCap(title: model.preferences.mode == .list ? "↓" : "→"); Text("选择") }
            }
            HStack(spacing: 6) { KeyCap(title: "esc"); Text("取消") }
            Spacer()
            Button { model.rename() } label: { HStack(spacing: 6) { Text("重命名"); KeyCap(title: "F2") } }.buttonStyle(.plain).disabled(model.selection == nil)
            Text("\((model.filtered.firstIndex(where: { $0.id == model.selectedID }).map { $0 + 1 }) ?? 0) / \(model.filtered.count)").monospacedDigit().frame(minWidth: 34)
        }.font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.horizontal, 26).frame(height: 49).overlay(alignment: .top) { Palette.line.frame(height: 1) }
    }

    private func notice(_ text: String, symbol: String, action: String?) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
            Text(text).lineLimit(3)
            Spacer(minLength: 4)
            if let action { Button(action) { model.onSettings?() }.buttonStyle(.plain).foregroundStyle(Palette.accent) }
        }.font(.system(size: 12)).foregroundStyle(Palette.muted).padding(12).background(Palette.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 9)).padding(.horizontal, 26).padding(.bottom, 12)
    }
}

struct RenameView: View {
    @ObservedObject var model: AppModel
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("重命名").font(.system(size: 19, weight: .semibold))
            Text("名称显示在 Flit 中，原来的标题保持不变。").font(.system(size: 12)).foregroundStyle(Palette.muted)
            Text("显示名称").font(.system(size: 12)).padding(.top, 10)
            TextField("显示名称", text: $model.renameDraft).textFieldStyle(.plain).font(.system(size: 13)).padding(.horizontal, 10).frame(height: 35)
                .background(.white, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? Palette.focus : Palette.line, lineWidth: 1)).focused($focused).onSubmit { model.saveName() }
            if let error = model.renameError { Text(error).font(.system(size: 12)).foregroundStyle(Palette.danger).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("使用原标题") { model.renameDraft = model.selection?.originalTitle ?? "" }.buttonStyle(.plain).foregroundStyle(Palette.muted)
                Spacer()
                Button("取消") { model.cancelRename() }.keyboardShortcut(.cancelAction).buttonStyle(IrisButtonStyle())
                Button("保存名称") { model.saveName() }.keyboardShortcut(.defaultAction).buttonStyle(IrisButtonStyle(prominent: true))
            }.font(.system(size: 12)).padding(.top, 10)
        }.padding(28).frame(width: 430).background(Palette.surface).tint(Palette.accent).preferredColorScheme(.light).onAppear { focused = true }
    }
}
