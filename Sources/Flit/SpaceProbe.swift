import AppKit

/// Optional native integration check. Verifies target identity and route, then restores the original Space and front application.
@MainActor
enum SpaceProbe {
    static func run() async throws {
        let spaces = SpacesService.shared.spaces()
        guard let original = spaces.first(where: { $0.isCurrent && $0.displayID == CGMainDisplayID() }),
              let destination = spaces.filter({ $0.displayID == original.displayID && !$0.isCurrent && $0.isFullscreen != original.isFullscreen }).max(by: {
                  abs($0.index - original.index) < abs($1.index - original.index)
              }) else {
            throw FlitFailure("需要同一屏幕上至少一个桌面空间和一个全屏空间才能往返验证。")
        }
        let front = NSWorkspace.shared.frontmostApplication
        guard !overviewVisible() else { throw FlitFailure("请先退出调度中心，再进行无调度中心切换验证。") }
        let monitor = Task { @MainActor in
            var observed = false
            while !Task.isCancelled {
                observed = observed || overviewVisible()
                do { try await Task.sleep(for: .milliseconds(40)) } catch { break }
            }
            return observed
        }
        do {
            try await jump(to: destination)
            print("PASS: switched from \(original.isFullscreen ? "fullscreen" : "desktop") to \(destination.isFullscreen ? "fullscreen" : "desktop")")
            if let distant = spaces.filter({ $0.displayID == original.displayID }).max(by: { abs($0.index - destination.index) < abs($1.index - destination.index) }), distant.id != original.id {
                try await jump(to: distant)
                print("PASS: distant target activated directly")
            }
            let fullscreens = spaces.filter { $0.isFullscreen && $0.displayID == original.displayID }
            if let first = fullscreens.first {
                try await jump(to: first)
                let latest = SpacesService.shared.spaces().filter { $0.isFullscreen && $0.displayID == original.displayID }
                let owner = SpaceFocus.window(on: first)?.pid
                if let distant = latest.last(where: { $0.id != first.id && SpaceFocus.window(on: $0)?.pid == owner }) {
                    try await jump(to: distant)
                    print("PASS: same-app fullscreen targets activated directly")
                }
            }
            if CommandLine.arguments.contains("--probe-instant-navigation"), let desktop = spaces.first(where: { !$0.isFullscreen && $0.displayID == original.displayID }) {
                try await jump(to: desktop)
                if let fullscreen = SpacesService.shared.spaces().last(where: { $0.isFullscreen && $0.displayID == original.displayID }) {
                    try await jump(to: fullscreen, usingInstantNavigation: true)
                    try await jump(to: desktop)
                    print("PASS: far fullscreen → desktop activated directly")
                    try await jump(to: fullscreen, usingInstantNavigation: true)
                }
                try await jump(to: desktop, usingInstantNavigation: true)
                print("PASS: empty-desktop instant navigation path")
            }
            try await jump(to: original)
            front?.activate(options: [])
            print("PASS: original Space restored")
            monitor.cancel()
            guard await !monitor.value else { throw FlitFailure("切换过程中观察到调度中心界面。") }
            print("PASS: no Mission Control overview observed during the round trip")
        } catch {
            monitor.cancel()
            if !SpacesService.shared.spaces().contains(where: { $0.id == original.id && $0.isCurrent }) { try? await SpacesService.shared.activate(original) }
            front?.activate(options: [])
            throw error
        }
    }

    private static func jump(to target: SpaceInfo, usingInstantNavigation: Bool = false) async throws {
        let service = SpacesService.shared
        let layout = service.spaces().filter { $0.displayID == target.displayID }
        let positions = Dictionary(uniqueKeysWithValues: layout.map { ($0.id, $0.index + 1) })
        guard let origin = layout.first(where: \.isCurrent), let targetPosition = positions[target.id] else { throw FlitFailure("无法读取验证起点。") }
        if origin.id == target.id { return }
        let start = ProcessInfo.processInfo.systemUptime
        let sampling = Task { @MainActor in
            var trace = [origin]
            while !Task.isCancelled {
                if let current = service.spaces().first(where: { $0.displayID == target.displayID && $0.isCurrent }), trace.last?.id != current.id { trace.append(current) }
                do { try await Task.sleep(for: .milliseconds(5)) } catch { break }
            }
            return trace
        }
        do { try await service.activate(target, usingInstantNavigation: usingInstantNavigation) }
        catch {
            sampling.cancel()
            let trace = await sampling.value
            print("Failed jump \(origin.index + 1) → \(targetPosition); observed destinations: \(trace.map { String(positions[$0.id] ?? -1) }.joined(separator: " → "))")
            throw error
        }
        sampling.cancel()
        let trace = await sampling.value
        let elapsed = Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
        print("Jump \(origin.index + 1) → \(targetPosition): \(elapsed) ms; observed destinations: \(trace.map { String(positions[$0.id] ?? -1) }.joined(separator: " → "))")
        if usingInstantNavigation {
            guard elapsed < 700 else { throw FlitFailure("瞬时跳转耗时超过预期。") }
        } else {
            guard !trace.contains(where: { $0.id != origin.id && $0.id != target.id }) else { throw FlitFailure("跳转经过了中间空间。") }
        }
        if let window = SpaceFocus.window(on: target) {
            let visible = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
            guard visible.contains(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == window.id }) else { throw FlitFailure("目标窗口尚未实际显示。") }
        }
    }

    private static func overviewVisible() -> Bool {
        for app in NSWorkspace.shared.runningApplications where ["com.apple.WindowManager", "com.apple.dock"].contains(app.bundleIdentifier ?? "") {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.1)
            if !AX.find(root, depth: 4, predicate: { (AX.value($0, kAXIdentifierAttribute) as String?) == "mc.display" }).isEmpty { return true }
        }
        return false
    }
}
