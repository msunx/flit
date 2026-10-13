import AppKit

enum SwitchAction { case begin(Bool), step(Int), row(Int), commit, cancel, rename }

final class HotkeyService {
    var shortcut = Shortcut()
    var onAction: ((SwitchAction) -> Void)?
    var canBegin: (() -> Bool)?
    var visible = false
    var holding = false
    var editing = false
    var suspended = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var swallowed: Set<Int64> = []
    var isRunning: Bool { tap != nil }
    private let modifierMask: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

    func start() -> Bool {
        if tap != nil { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, pointer in
            guard let pointer else { return Unmanaged.passUnretained(event) }
            let service = Unmanaged<HotkeyService>.fromOpaque(pointer).takeUnretainedValue()
            return service.handle(type, event) ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: CGEventMask(mask), callback: callback,
                                         userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        swallowed.removeAll()
        visible = false
        holding = false
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if event.getIntegerValueField(.eventSourceUserData) == SpacesService.navigationEventTag { return false }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            holding = false
            onAction?(.cancel)
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp, swallowed.remove(key) != nil { return true }
        if suspended { return false }
        if type == .flagsChanged, holding, !event.flags.contains(shortcut.flags) {
            holding = false
            onAction?(.commit)
            return false
        }
        guard type == .keyDown else { return false }
        if editing { return false }
        let actual = event.flags.intersection(modifierMask)
        let compared = shortcut.flags.contains(.maskShift) ? actual : actual.subtracting(.maskShift)
        if key == Int64(shortcut.keyCode), compared == shortcut.flags {
            if !visible && canBegin?() != true { return false }
            let reverse = actual.contains(.maskShift) && !shortcut.flags.contains(.maskShift)
            if visible { onAction?(.step(reverse ? -1 : 1)) }
            else { holding = true; visible = true; onAction?(.begin(reverse)) }
            swallowed.insert(key)
            return true
        }
        guard visible else { return false }
        let action: SwitchAction?
        switch key {
        case 123: action = .step(-1)
        case 124: action = .step(1)
        case 125: action = .row(1)
        case 126: action = .row(-1)
        case 36, 76: holding = false; action = .commit
        case 53: holding = false; action = .cancel
        case 120: holding = false; action = .rename
        default: action = nil
        }
        if let action { onAction?(action); swallowed.insert(key); return true }
        return false
    }
}
