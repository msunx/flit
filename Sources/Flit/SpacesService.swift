import AppKit
import ApplicationServices
import Darwin

/// Space topology is read-only; navigation focuses a specific window on the destination Space.
final class SpacesService: @unchecked Sendable {
    static let shared = SpacesService()
    static let navigationEventTag: Int64 = 0x464C4954
    private typealias Connection = @convention(c) () -> Int32
    private typealias CopyDisplays = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopyWindowSpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias IsDisplayAnimating = @convention(c) (Int32, CFString) -> Bool
    private let library: UnsafeMutableRawPointer?
    private let connection: Connection?
    private let copyDisplays: CopyDisplays?
    private let copyWindowSpaces: CopyWindowSpaces?
    private let isDisplayAnimating: IsDisplayAnimating?

    private init() {
        let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        self.library = library
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let library, let pointer = dlsym(library, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        connection = symbol("SLSMainConnectionID", Connection.self)
        copyDisplays = symbol("SLSCopyManagedDisplaySpaces", CopyDisplays.self)
        copyWindowSpaces = symbol("SLSCopySpacesForWindows", CopyWindowSpaces.self)
        isDisplayAnimating = symbol("SLSManagedDisplayIsAnimating", IsDisplayAnimating.self)
    }

    var available: Bool { connection != nil && copyDisplays != nil }

    func spaces() -> [SpaceInfo] {
        guard let connection, let copyDisplays, let data = copyDisplays(connection())?.takeRetainedValue() as? [[String: Any]] else { return [] }
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount)
        let displays = displayIDs.map { id -> (String, CGDirectDisplayID) in
            let uuid = CGDisplayCreateUUIDFromDisplayID(id).takeRetainedValue()
            return (CFUUIDCreateString(nil, uuid) as String, id)
        }
        var output: [SpaceInfo] = []
        var desktopNumber = 0
        for display in data {
            let displayUUID = display["Display Identifier"] as? String ?? "Main"
            let displayID = displays.first { $0.0 == displayUUID }?.1 ?? CGMainDisplayID()
            let current = ((display["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?.uint64Value
            for (index, space) in (display["Spaces"] as? [[String: Any]] ?? []).enumerated() {
                guard let id = (space["id64"] as? NSNumber)?.uint64Value else { continue }
                let type = (space["type"] as? NSNumber)?.intValue ?? 0
                if type != 0 && type != 4 { continue }
                if type == 0 { desktopNumber += 1 }
                output.append(SpaceInfo(id: id, uuid: space["uuid"] as? String ?? "", displayUUID: displayUUID, displayID: displayID, index: index,
                                        desktopNumber: desktopNumber, isFullscreen: type == 4, isCurrent: id == current))
            }
        }
        return output
    }

    func spaces(for window: CGWindowID) -> [UInt64] {
        guard let connection, let copyWindowSpaces, let result = copyWindowSpaces(connection(), 7, [NSNumber(value: window)] as CFArray)?.takeRetainedValue() else { return [] }
        return (result as? [NSNumber] ?? []).map(\.uint64Value)
    }

    @MainActor
    func activate(_ original: SpaceInfo, usingInstantNavigation: Bool = false) async throws {
        guard AXIsProcessTrusted() else { throw FlitFailure("需要辅助功能权限才能切换桌面空间。") }
        let displaySpaces = spaces().filter { $0.displayUUID == original.displayUUID }
        guard let target = displaySpaces.first(where: { $0.id == original.id }) else { throw FlitFailure("这个桌面空间已经关闭，请重新选择。") }
        if target.isCurrent { return }
        try Task.checkCancellation()
        let window = SpaceFocus.window(on: target)
        if let window, !usingInstantNavigation {
            try SpaceFocus.focus(window)
            await SpaceFocus.raise(window)
        } else {
            try InstantSpaceNavigation.jump(to: target)
        }
        // Verify the destination after direct activation or the empty-desktop gesture burst. Never open Mission Control.
        try await waitUntilSettled(target)
    }

    private func waitUntilSettled(_ target: SpaceInfo) async throws {
        let deadline = Date().addingTimeInterval(2.5)
        var stableSince: Date?
        while Date() < deadline {
            try Task.checkCancellation()
            let active = spaces().contains { $0.id == target.id && $0.displayUUID == target.displayUUID && $0.isCurrent }
            let animating = connection.flatMap { connection in isDisplayAnimating.map { $0(connection(), target.displayUUID as CFString) } }
            if active && animating != true {
                // The readonly animation flag is preferred; older systems use a short stable-state observation.
                if let stableSince, Date().timeIntervalSince(stableSince) >= (animating == false ? 0.12 : 0.25) { return }
                if stableSince == nil { stableSince = Date() }
            } else {
                stableSince = nil
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw FlitFailure("系统没有切换到目标空间，请重新选择。")
    }
}
