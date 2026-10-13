import AppKit
import ApplicationServices
import Darwin

enum WindowService {
    private typealias WindowIDFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let idFunction: WindowIDFunction? = {
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(pointer, to: WindowIDFunction.self)
    }()

    static func windowID(_ element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        guard let idFunction, idFunction(element, &id) == .success, id != 0 else { return nil }
        return id
    }

    static func scan() -> ScanResult {
        let service = SpacesService.shared
        let spaces = service.spaces()
        let cgWindows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var order: [CGWindowID: Int] = [:]
        for (index, info) in cgWindows.enumerated() { if let id = info[kCGWindowNumber as String] as? NSNumber { order[id.uint32Value] = index } }
        var output: [SwitchTarget] = []
        let applications = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() && !$0.isTerminated }
        if AXIsProcessTrusted() {
            for app in applications {
                let element = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(element, 0.5)
                let windows: [AXUIElement] = AX.value(element, kAXWindowsAttribute) ?? []
                for (index, window) in windows.enumerated() {
                    AXUIElementSetMessagingTimeout(window, 0.15)
                    guard (AX.value(window, kAXRoleAttribute) as String?) == kAXWindowRole else { continue }
                    let role: String = AX.value(window, kAXSubroleAttribute) ?? ""
                    guard role.isEmpty || role == kAXStandardWindowSubrole || role == kAXDialogSubrole else { continue }
                    if let frame = AX.frame(window), frame.width < 100 || frame.height < 60 { continue }
                    let minimized: Bool = AX.value(window, kAXMinimizedAttribute) ?? false
                    if minimized { continue }
                    let rawTitle: String = AX.value(window, kAXTitleAttribute) ?? ""
                    let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    let windowID = windowID(window) ?? matchWindow(window, title: title, pid: app.processIdentifier, candidates: cgWindows)
                    let spaceIDs = windowID.map(service.spaces(for:)) ?? []
                    guard let space = spaces.first(where: { $0.isFullscreen && spaceIDs.contains($0.id) }) else { continue }
                    let launch = Int(app.launchDate?.timeIntervalSince1970 ?? 0)
                    let key = "window:\(app.processIdentifier):\(launch):\(windowID.map(String.init) ?? "ax-\(index)-\(title)")"
                    output.append(SwitchTarget(id: key, originalTitle: title.isEmpty ? (app.localizedName ?? "未命名窗口") : title, appName: app.localizedName ?? "应用", kind: .fullscreen,
                                               processID: app.processIdentifier, windowID: windowID, element: window, space: space, icon: app.icon, isMinimized: minimized, order: windowID.flatMap { order[$0] } ?? 500))
                }
            }
            // Some apps omit windows on inactive fullscreen Spaces from AXWindows. Recover their real identities from WindowServer.
            let known = Set(output.compactMap(\.windowID))
            for info in cgWindows {
                guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value, !known.contains(id),
                      (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                      let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                      let app = applications.first(where: { $0.processIdentifier == pid }),
                      let bounds = info[kCGWindowBounds as String] as? [String: Any], let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), frame.width >= 100, frame.height >= 60 else { continue }
                let spaceIDs = service.spaces(for: id)
                guard let space = spaces.first(where: { $0.isFullscreen && spaceIDs.contains($0.id) }) else { continue }
                let title = (info[kCGWindowName as String] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if title.isEmpty {
                    let hasBetterWindow = cgWindows.contains { other in
                        guard let otherID = (other[kCGWindowNumber as String] as? NSNumber)?.uint32Value, otherID != id,
                              (other[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid, (other[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                              let bounds = other[kCGWindowBounds as String] as? [String: Any], let otherFrame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                              otherFrame.width >= 100, otherFrame.height >= 60, service.spaces(for: otherID).contains(space.id) else { return false }
                        let hasTitle = !(other[kCGWindowName as String] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        let larger = otherFrame.width * otherFrame.height > frame.width * frame.height
                        let sameSizeAndEarlier = otherFrame.size == frame.size && (order[otherID] ?? 0) < (order[id] ?? 0)
                        return hasTitle || larger || sameSizeAndEarlier
                    }
                    if hasBetterWindow { continue }
                }
                let launch = Int(app.launchDate?.timeIntervalSince1970 ?? 0)
                output.append(SwitchTarget(id: "window:\(pid):\(launch):\(id)", originalTitle: title.isEmpty ? (app.localizedName ?? "未命名窗口") : title, appName: app.localizedName ?? "应用",
                                           kind: .fullscreen, processID: pid, windowID: id, element: nil, space: space, icon: app.icon, isMinimized: false, order: order[id] ?? 500))
            }
        }
        // Match Mission Control's top strip: exactly one target per Space, in display/Space order.
        // A fullscreen Space may expose helper windows or a split view; use its largest window for identity and preview.
        func area(_ target: SwitchTarget) -> CGFloat {
            guard let id = target.windowID, let info = cgWindows.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }),
                  let bounds = info[kCGWindowBounds as String] as? [String: Any], let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return 0 }
            return frame.width * frame.height
        }
        let targets = spaces.map { space -> SwitchTarget in
            if space.isFullscreen, let representative = output.filter({ $0.space?.id == space.id }).sorted(by: {
                let left = area($0), right = area($1)
                return left == right ? $0.order < $1.order : left > right
            }).first { return representative }
            return SwitchTarget(id: space.aliasKey, originalTitle: space.isFullscreen ? "全屏空间 \(space.index + 1)" : "桌面 \(space.desktopNumber)", appName: space.isFullscreen ? "全屏空间" : "桌面空间",
                                kind: space.isFullscreen ? .fullscreen : .desktop, processID: nil, windowID: nil, element: nil, space: space, icon: nil, isMinimized: false, order: space.index)
        }
        return ScanResult(targets: targets, spaces: spaces, spacesAvailable: service.available && !spaces.isEmpty)
    }

    private static func matchWindow(_ element: AXUIElement, title: String, pid: pid_t, candidates: [[String: Any]]) -> CGWindowID? {
        let frame = AX.frame(element)
        let matches = candidates.filter { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid, (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { return false }
            let name = info[kCGWindowName as String] as? String ?? ""
            if !title.isEmpty && name == title { return true }
            if let frame, let bounds = info[kCGWindowBounds as String] as? [String: Any], let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) {
                return abs(frame.minX - rect.minX) < 2 && abs(frame.minY - rect.minY) < 2 && abs(frame.width - rect.width) < 2 && abs(frame.height - rect.height) < 2
            }
            return false
        }
        return matches.count == 1 ? (matches[0][kCGWindowNumber as String] as? NSNumber)?.uint32Value : nil
    }

    @MainActor
    static func activate(_ target: SwitchTarget) async throws {
        guard let space = target.space else { throw FlitFailure("找不到这个空间，请重新打开切换器。") }
        try await SpacesService.shared.activate(space)
    }
}
