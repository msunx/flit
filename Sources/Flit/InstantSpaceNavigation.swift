import AppKit
import Darwin

/// Empty desktops have no window to raise. Complete Dock gestures with near-zero travel instead of animated arrow keys.
/// Protocol adapted from jurplel/InstantSpaceSwitcher (MIT); see Resources/ThirdPartyNotices.txt.
@MainActor
enum InstantSpaceNavigation {
    static func jump(to target: SpaceInfo) throws {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }),
              (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == target.displayID else {
            throw FlitFailure("请先将指针移到目标桌面所在的屏幕。")
        }
        let spaces = SpacesService.shared.spaces().filter { $0.displayID == target.displayID }
        guard let origin = spaces.firstIndex(where: \.isCurrent), let destination = spaces.firstIndex(where: { $0.id == target.id }) else { throw FlitFailure("空间列表已变化，请重新选择。") }
        let distance = destination - origin
        if distance == 0 { return }
        let modern = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
        let natural = (UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection") as? Bool) ?? true
        let direction = distance > 0 ? 1.0 : -1.0
        let sign = modern ? direction * (natural ? -1 : 1) : direction
        // Prepare the complete, bounded burst before posting. Never retry partial gestures or infer a new delta mid-burst.
        var events: [CGEvent] = []
        for _ in 0..<abs(distance) {
            for phase in [1, 2, 4] {
                guard let event = CGEvent(source: nil) else { throw FlitFailure("无法创建桌面切换请求。") }
                integer(event, 55, 30)
                integer(event, 110, 23)
                integer(event, 132, Int64(phase))
                integer(event, 123, 1)
                decimal(event, 124, sign * 0.000016)
                event.setIntegerValueField(.eventSourceUserData, value: SpacesService.navigationEventTag)
                if modern {
                    integer(event, 134, Int64(phase))
                    decimal(event, 138, 3)
                    decimal(event, 169, Double(mach_absolute_time()))
                    decimal(event, 125, 0.1)
                    if phase == 4 { decimal(event, 129, sign * 9999) }
                    events.append(try augmented(event, phase: phase, sign: sign))
                    guard let companion = CGEvent(source: nil) else { throw FlitFailure("无法创建完整的桌面切换请求。") }
                    integer(companion, 55, 29)
                    companion.setIntegerValueField(.eventSourceUserData, value: SpacesService.navigationEventTag)
                    events.append(companion)
                } else {
                    decimal(event, 129, sign * 2000 * Double(abs(distance)))
                    decimal(event, 130, sign * 2000 * Double(abs(distance)))
                    events.append(event)
                }
            }
        }
        for event in events { event.post(tap: .cgSessionEventTap) }
    }

    private static func integer(_ event: CGEvent, _ field: UInt32, _ value: Int64) { event.setIntegerValueField(unsafeBitCast(field, to: CGEventField.self), value: value) }
    private static func decimal(_ event: CGEvent, _ field: UInt32, _ value: Double) { event.setDoubleValueField(unsafeBitCast(field, to: CGEventField.self), value: value) }

    /// macOS 27 requires the serialized IOHID child events as well as the CoreGraphics gesture fields.
    private static func augmented(_ event: CGEvent, phase: Int, sign: Double) throws -> CGEvent {
        guard let raw = event.data else { throw FlitFailure("无法编码桌面切换请求。") }
        var data = raw as Data
        guard data.starts(with: [0, 0, 0, 2]) else { throw FlitFailure("当前系统的桌面切换协议不受支持。") }
        let ended = phase == 4
        var payload = Data(count: ended ? 96 : 68)
        payload.withUnsafeMutableBytes { bytes in
            // IOHIDSystemQueueElementHeader: timestamp, sender, options, attribute length, event count.
            bytes.storeBytes(of: event.timestamp, toByteOffset: 0, as: UInt64.self)
            bytes.storeBytes(of: UInt32(ended ? 2 : 1), toByteOffset: 24, as: UInt32.self)
            // IOHIDFluidTouchGestureData: fixed 16.16 progress of one unit leaves no visible travel.
            bytes.storeBytes(of: UInt32(40), toByteOffset: 28, as: UInt32.self)
            bytes.storeBytes(of: UInt32(23), toByteOffset: 32, as: UInt32.self)
            bytes.storeBytes(of: UInt32(phase << 24), toByteOffset: 36, as: UInt32.self)
            bytes.storeBytes(of: Int32(6553), toByteOffset: 44, as: Int32.self)
            bytes.storeBytes(of: UInt16(1), toByteOffset: 60, as: UInt16.self)
            bytes.storeBytes(of: UInt16(3), toByteOffset: 62, as: UInt16.self)
            bytes.storeBytes(of: Int32(sign), toByteOffset: 64, as: Int32.self)
            if ended {
                // IOHIDVelocityEventData, depth 1. A complete ended phase closes the Dock's gesture state.
                bytes.storeBytes(of: UInt32(28), toByteOffset: 68, as: UInt32.self)
                bytes.storeBytes(of: UInt32(9), toByteOffset: 72, as: UInt32.self)
                bytes.storeBytes(of: UInt8(1), toByteOffset: 80, as: UInt8.self)
                bytes.storeBytes(of: Int32(sign * 9999 * 65536), toByteOffset: 84, as: Int32.self)
            }
        }
        data.append(contentsOf: [UInt8(payload.count >> 8), UInt8(payload.count & 255), 0x10, 0x6d])
        data.append(payload)
        guard let result = CGEvent(withDataAllocator: nil, data: data as CFData) else { throw FlitFailure("系统无法解析桌面切换请求。") }
        return result
    }
}
