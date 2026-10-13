import SwiftUI

struct DockSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var service: DockLockService

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("给 Dock 一个固定的位置").font(.system(size: 21, weight: .semibold, design: .rounded))
                    Text("鼠标自由跨屏，常用应用留在手边。").font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Toggle("固定 Dock", isOn: Binding(get: { model.preferences.dockLockEnabled }, set: { model.setDockLock($0) }))
                    .toggleStyle(IrisToggleStyle()).font(.system(size: 12)).fixedSize()
            }.padding(.top, 6)

            HStack {
                Text("选择屏幕").font(.system(size: 12, weight: .medium))
                Spacer()
                Text("已连接 \(service.screens.count) 个").font(.system(size: 11)).foregroundStyle(Palette.muted)
            }.padding(.top, 24).padding(.bottom, 11)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 14)], spacing: 14) {
                ForEach(Array(service.screens.enumerated()), id: \.element.id) { index, screen in
                    DockScreenChoice(screen: screen, number: index + 1, selected: screen.id == model.preferences.dockDisplayUUID) { model.selectDockScreen(screen) }
                }
            }
            if service.screens.isEmpty { Text("暂未检测到显示器，请稍后重试。").font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.vertical, 20) }

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: service.status.guarding ? "pin.circle.fill" : model.preferences.dockLockEnabled ? "pause.circle" : "info.circle")
                    .font(.system(size: 16)).foregroundStyle(service.status.guarding ? Palette.accent : Palette.muted).padding(.top, 1)
                VStack(alignment: .leading, spacing: 5) {
                    Text(service.status.title).font(.system(size: 12, weight: .medium))
                    Text(service.status.detail).font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(.top, 18).accessibilityElement(children: .combine)

            Text(model.preferences.dockDisplayUUID == nil ? "首次开启默认选择 Dock 当前所在屏幕。" : "更换屏幕后，在所选屏幕底部唤出一次 Dock。")
                .font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.top, 15)
            Text("适用于底部 Dock。其他屏幕的最底部 3 个逻辑像素将保留；关闭即恢复。")
                .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 5)
        }
    }
}

private struct DockScreenChoice: View {
    let screen: DockScreen
    let number: Int
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 6).fill(.white)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Palette.focus : Palette.line, lineWidth: 1.5))
                        .overlay { Text(String(number)).font(.system(size: 22, weight: .light, design: .rounded)).foregroundStyle(selected ? Palette.accent : Palette.muted.opacity(0.7)) }
                    if selected {
                        HStack(spacing: 3) { ForEach(0..<5) { index in RoundedRectangle(cornerRadius: 2).fill(index == 2 ? Palette.accent : Palette.accentSoft).frame(width: 5, height: 5) } }
                            .padding(4).background(Palette.selection, in: RoundedRectangle(cornerRadius: 5)).padding(.bottom, 5)
                    }
                }.frame(width: screen.bounds.width < screen.bounds.height ? 45 : 110, height: screen.bounds.width < screen.bounds.height ? 78 : 68)
                    .frame(height: 78).shadow(color: Palette.accent.opacity(0.06), radius: 5, y: 4).accessibilityHidden(true)
                HStack(spacing: 6) {
                    Text(screen.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if screen.isMain { Text("主屏幕").font(.system(size: 10)).foregroundStyle(Palette.muted).padding(.horizontal, 6).padding(.vertical, 3).background(.white.opacity(0.85), in: Capsule()) }
                }
            }.padding(.vertical, 16).padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: 142)
                .background(selected ? Palette.selection.opacity(0.5) : .white.opacity(hovering ? 1 : 0.65), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? Palette.focus : Palette.line, lineWidth: selected ? 1.2 : 1))
                .overlay(alignment: .topTrailing) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.system(size: 13)).foregroundStyle(selected ? Palette.accent : Palette.line).padding(12)
                }.contentShape(RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain).onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: selected)
            .accessibilityLabel("屏幕 \(number)，\(screen.name)\(screen.isMain ? "，主屏幕" : "")").accessibilityAddTraits(selected ? .isSelected : [])
    }
}
