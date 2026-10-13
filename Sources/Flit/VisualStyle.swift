import AppKit
import SwiftUI

enum Palette {
    static let ink = Color(hex: 0x332C3E)
    static let muted = Color(hex: 0x71637E)
    static let accent = Color(hex: 0x7951D2)
    static let accentSoft = Color(hex: 0xBEA5F0)
    static let line = Color(hex: 0xE4DAEF)
    static let focus = Color(hex: 0x9E7BCB)
    static let surface = Color(hex: 0xFCFAFF)
    static let selection = Color(hex: 0xEEE6FA)
    static let inset = Color(hex: 0xF3EEF8)
    static let success = Color(hex: 0x407455)
    static let warning = Color(hex: 0x9A641E)
    static let danger = Color(hex: 0xB63C53)
    static let nsAccent = NSColor(calibratedRed: 0x79 / 255.0, green: 0x51 / 255.0, blue: 0xD2 / 255.0, alpha: 1)
    static let nsInk = NSColor(calibratedRed: 0x33 / 255.0, green: 0x2C / 255.0, blue: 0x3E / 255.0, alpha: 1)
    static let nsMuted = NSColor(calibratedRed: 0x71 / 255.0, green: 0x63 / 255.0, blue: 0x7E / 255.0, alpha: 1)
}

extension Color {
    init(hex: UInt32) { self.init(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255) }
}

enum FlitUI {
    static let settingsSize = CGSize(width: 820, height: 560)
    static let selectionDuration = 0.2
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.6" }
}

struct SlantedPane: Shape {
    func path(in rect: CGRect) -> Path {
        let transform = CGAffineTransform(scaleX: rect.width / 21, y: rect.height / 42)
        return Path { p in
            p.move(to: CGPoint(x: 0, y: 11))
            p.addQuadCurve(to: CGPoint(x: 4, y: 6), control: CGPoint(x: 0, y: 7))
            p.addLine(to: CGPoint(x: 17, y: 2))
            p.addQuadCurve(to: CGPoint(x: 21, y: 5), control: CGPoint(x: 21, y: 1))
            p.addLine(to: CGPoint(x: 21, y: 31))
            p.addQuadCurve(to: CGPoint(x: 17, y: 36), control: CGPoint(x: 21, y: 35))
            p.addLine(to: CGPoint(x: 4, y: 40))
            p.addQuadCurve(to: CGPoint(x: 0, y: 37), control: CGPoint(x: 0, y: 41))
            p.closeSubpath()
        }.applying(transform)
    }
}

struct FlitMark: View {
    var body: some View {
        ZStack {
            SlantedPane().fill(Palette.accent).frame(width: 14, height: 28).offset(x: -5, y: 3)
            SlantedPane().fill(Palette.accentSoft).frame(width: 14, height: 28).offset(x: 6, y: -3)
        }.frame(width: 30, height: 34).accessibilityHidden(true)
    }
}

struct FlitAppIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 106, style: .continuous).fill(Palette.surface)
                .overlay(RoundedRectangle(cornerRadius: 106, style: .continuous).stroke(.white, lineWidth: 3))
            FlitMark().scaleEffect(9)
        }.frame(width: 480, height: 480).shadow(color: Palette.ink.opacity(0.1), radius: 8, y: 5).frame(width: 512, height: 512)
    }
}

struct IrisButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal, 13).padding(.vertical, 8)
            .foregroundStyle(prominent ? .white : Palette.accent)
            .background(prominent ? Palette.accent : Palette.selection, in: RoundedRectangle(cornerRadius: 9))
            .opacity(configuration.isPressed ? 0.78 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct ModePicker: View {
    let selection: DisplayMode
    let onSelect: (DisplayMode) -> Void
    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 2) {
            ForEach(DisplayMode.allCases, id: \.self) { mode in
                Button { onSelect(mode) } label: {
                    Label(mode.label, systemImage: mode == .preview ? "square.grid.2x2" : "list.bullet")
                        .font(.system(size: 11, weight: .medium)).frame(width: 66, height: 28)
                        .foregroundStyle(selection == mode ? Palette.accent : Palette.muted)
                        .background {
                            if selection == mode { RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white).shadow(color: Palette.ink.opacity(0.07), radius: 2, y: 1).matchedGeometryEffect(id: "mode", in: namespace) }
                        }.contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }.buttonStyle(.plain).accessibilityLabel(mode.label).accessibilityAddTraits(selection == mode ? .isSelected : [])
            }
        }.padding(3).background(Palette.inset, in: RoundedRectangle(cornerRadius: 18, style: .continuous)).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .animation(reduceMotion ? nil : .snappy(duration: FlitUI.selectionDuration, extraBounce: 0), value: selection)
            .accessibilityElement(children: .contain).accessibilityLabel("显示方式")
    }
}

struct IrisToggleStyle: ToggleStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 9) {
            configuration.label
            Button { configuration.isOn.toggle() } label: {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(configuration.isOn ? Palette.accent : Palette.line)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) { Circle().fill(.white).shadow(color: Palette.ink.opacity(0.15), radius: 1, y: 1).frame(width: 16, height: 16).padding(3) }
                    .frame(width: 36, height: 22).clipShape(RoundedRectangle(cornerRadius: 11)).drawingGroup().frame(minHeight: 26).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }.animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isOn)
            .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch) }
    }
}
