import AppKit
import ApplicationServices
import CoreServices
import Darwin

/// Focus by WindowServer ID, including windows omitted by AXWindows on inactive fullscreen Spaces.
/// ABI references: AltTab's SkyLight.framework.swift and yabai's misc/extern.h.
@MainActor
enum SpaceFocus {
    typealias Window = (id: CGWindowID, pid: pid_t)
    private static let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private typealias ProcessLookup = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    private typealias FrontWindow = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    private typealias PostRecord = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
    private typealias RemoteElement = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
    private static let processLookup: ProcessLookup? = symbol("GetProcessForPID", handle: UnsafeMutableRawPointer(bitPattern: -2))
    private static let frontWindow: FrontWindow? = symbol("_SLPSSetFrontProcessWithOptions")
    private static let postRecord: PostRecord? = symbol("SLPSPostEventRecordTo")
    private static let remoteElement: RemoteElement? = symbol("_AXUIElementCreateWithRemoteToken", handle: UnsafeMutableRawPointer(bitPattern: -2))
    private static var elements: [CGWindowID: AXUIElement] = [:]

    private static func symbol<T>(_ name: String, handle: UnsafeMutableRawPointer? = nil) -> T? {
        guard let handle = handle ?? library, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    static func window(on space: SpaceInfo) -> Window? {
        let apps = Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated }.map(\.processIdentifier))
        let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let candidates = windows.compactMap { info -> (Window, CGFloat)? in
            guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != getpid(), apps.contains(pid),
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any], let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width >= 100, frame.height >= 60, SpacesService.shared.spaces(for: id) == [space.id] else { return nil }
            return ((id, pid), frame.width * frame.height)
        }
        // Fullscreen helpers are smaller than the main surface; desktops retain WindowServer's front-to-back order.
        return space.isFullscreen ? candidates.max(by: { $0.1 < $1.1 })?.0 : candidates.first?.0
    }

    static func focus(_ window: Window) throws {
        guard let processLookup, let frontWindow, let postRecord else { throw FlitFailure("当前系统不支持直接激活窗口。") }
        var process = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: 0)
        guard processLookup(window.pid, &process) == noErr, frontWindow(&process, window.id, 2) == .success else {
            throw FlitFailure("未能激活目标窗口，请重新打开切换器。")
        }
        // Window-directed activation record; it contains no mouse click or pointer movement.
        var record = [UInt8](repeating: 0, count: 256)
        record.withUnsafeMutableBytes { bytes in
            bytes.storeBytes(of: UInt32(248), toByteOffset: 4, as: UInt32.self)
            bytes.storeBytes(of: UInt32(13), toByteOffset: 8, as: UInt32.self)
            bytes.storeBytes(of: UInt8(2), toByteOffset: 32, as: UInt8.self)
            bytes.storeBytes(of: UInt8(128), toByteOffset: 58, as: UInt8.self)
            bytes.storeBytes(of: window.id, toByteOffset: 60, as: CGWindowID.self)
        }
        guard postRecord(&process, &record) == .success else { throw FlitFailure("未能将焦点交给目标窗口。") }
    }

    static func raise(_ window: Window) async {
        let resolver = remoteElement
        let cached = Element(value: elements[window.id])
        let resolved = await Task.detached(priority: .userInitiated) {
            resolveAndRaise(window, cached: cached, remoteElement: resolver)
        }.value
        elements[window.id] = resolved.value
    }

    private struct Element: @unchecked Sendable { let value: AXUIElement? }

    nonisolated private static func resolveAndRaise(_ window: Window, cached: Element, remoteElement: RemoteElement?) -> Element {
        let app = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        let windows: [AXUIElement] = AX.value(app, kAXWindowsAttribute) ?? []
        var element = windows.first(where: { WindowService.windowID($0) == window.id })
        if element == nil, let cached = cached.value {
            var pid: pid_t = 0
            if AXUIElementGetPid(cached, &pid) == .success, pid == window.pid, WindowService.windowID(cached) == window.id,
               (AX.value(cached, kAXRoleAttribute) as String?) == kAXWindowRole { element = cached }
        }
        if element == nil, let remoteElement {
            let deadline = ProcessInfo.processInfo.systemUptime + 1.5
            for identifier: UInt64 in 0..<2048 {
                if ProcessInfo.processInfo.systemUptime >= deadline { break }
                var token = Data(count: 20)
                token.withUnsafeMutableBytes { bytes in
                    bytes.storeBytes(of: window.pid, toByteOffset: 0, as: pid_t.self)
                    bytes.storeBytes(of: UInt32(0x636f636f), toByteOffset: 8, as: UInt32.self)
                    bytes.storeBytes(of: identifier, toByteOffset: 12, as: UInt64.self)
                }
                guard let candidate = remoteElement(token as CFData)?.takeRetainedValue() else { continue }
                AXUIElementSetMessagingTimeout(candidate, 0.02)
                guard (AX.value(candidate, kAXRoleAttribute) as String?) == kAXWindowRole, let id = WindowService.windowID(candidate) else { continue }
                if id == window.id { element = candidate; break }
            }
        }
        if let element {
            AXUIElementSetMessagingTimeout(element, 0.15)
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        }
        return Element(value: element)
    }

}
