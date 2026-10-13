import AppKit
import SwiftUI
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var preferences: Preferences
    @Published private(set) var aliases: [String: String]
    @Published var targets: [SwitchTarget] = []
    @Published var thumbnails: [String: NSImage] = [:]
    @Published var selectedID: String?
    @Published var query = ""
    @Published var accessibilityAllowed = AXIsProcessTrusted()
    @Published var screenRecordingAllowed = CGPreflightScreenCaptureAccess()
    @Published var hotkeyRunning = false
    @Published var spacesAvailable = true
    @Published var loading = false
    @Published var visible = false
    @Published var switching = false
    @Published var holding = false
    @Published var message: String?
    @Published var renaming = false
    @Published var renameDraft = ""
    @Published var renameError: String?
    @Published var recordingShortcut = false
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    var onPreferencesChanged: (() -> Void)?
    var onCommit: ((SwitchTarget) -> Void)?
    var onCancel: (() -> Void)?
    var onSettings: (() -> Void)?
    var onRenameChanged: ((Bool) -> Void)?
    var gridColumns = 4
    let demo: Bool
    let store: SettingsStore
    let dockLock: DockLockService
    private let previews = PreviewService()
    private var scanTask: Task<Void, Never>?
    private var spaces: [SpaceInfo] = []
    private var recentTargetKeys: [String] = []
    private var activationRevision = 0

    init(demo: Bool = false, store: SettingsStore = SettingsStore()) {
        self.demo = demo
        self.store = store
        dockLock = DockLockService(demo: demo)
        preferences = store.state.preferences
        aliases = store.state.aliases
        message = store.loadError
        previews.onImage = { [weak self] id, image in self?.thumbnails[id] = image }
        previews.onFailure = { [weak self] message in self?.message = message }
    }

    var filtered: [SwitchTarget] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return targets.filter { text.isEmpty || title($0).localizedCaseInsensitiveContains(text) || $0.originalTitle.localizedCaseInsensitiveContains(text) || $0.appName.localizedCaseInsensitiveContains(text) }
    }
    var selection: SwitchTarget? { filtered.first { $0.id == selectedID } }
    func title(_ target: SwitchTarget) -> String { aliases[target.id] ?? target.originalTitle }

    func setPreferences(_ change: (inout Preferences) -> Void) {
        var state = store.state
        change(&state.preferences)
        do {
            try store.save(state)
            preferences = state.preferences
            onPreferencesChanged?()
            if !visible { refresh() }
        } catch { message = "设置未保存：\(error.localizedDescription)" }
    }

    func refresh(captureDesktop: Bool = false) {
        guard !demo, scanTask == nil, !switching else { return }
        accessibilityAllowed = AXIsProcessTrusted()
        screenRecordingAllowed = CGPreflightScreenCaptureAccess()
        loading = targets.isEmpty
        let revision = activationRevision
        scanTask = Task {
            let result = await Task.detached(priority: .userInitiated) { WindowService.scan() }.value
            guard !Task.isCancelled else { scanTask = nil; return }
            guard !switching, revision == activationRevision else { scanTask = nil; loading = false; refresh(captureDesktop: captureDesktop); return }
            spacesAvailable = result.spacesAvailable
            spaces = result.spaces
            if !visible || targets.isEmpty {
                let keys = Set(result.targets.map(recencyKey))
                recentTargetKeys.removeAll { !keys.contains($0) }
                targets = orderedTargets(result.targets)
                let ids = Set(targets.map(\.id))
                thumbnails = thumbnails.filter { ids.contains($0.key) }
                for item in targets { if let image = previews.image(for: item.id) { thumbnails[item.id] = image } }
                if visible && selectedID == nil { selectedID = targets.first?.id }
            }
            loading = false
            scanTask = nil
            if visible { capturePreviews() }
            else if captureDesktop { previews.capture([], spaces: spaces) }
        }
    }

    func setDockLock(_ enabled: Bool) {
        let initial = enabled && preferences.dockDisplayUUID == nil ? dockLock.initialTarget() : nil
        setPreferences {
            $0.dockLockEnabled = enabled
            if enabled && $0.dockDisplayUUID == nil, let initial { $0.dockDisplayUUID = initial.id; $0.dockDisplayName = initial.name }
        }
    }

    func selectDockScreen(_ screen: DockScreen) {
        setPreferences { $0.dockDisplayUUID = screen.id; $0.dockDisplayName = screen.name }
    }

    func begin(holding: Bool, reverse: Bool = false) {
        query = ""
        self.holding = holding
        message = store.loadError
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let displayID = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        let currentSpace = SpacesService.shared.spaces().first { $0.isCurrent && $0.displayID == displayID }
        // Seed the first interaction from the current Space. Later openings must preserve the last successful switch, even when the pointer is on another display.
        if recentTargetKeys.isEmpty, let current = targets.first(where: { $0.space?.id == currentSpace?.id && $0.space?.displayUUID == currentSpace?.displayUUID }) { didActivate(current) }
        visible = true
        let index = holding && targets.count > 1 ? (reverse ? targets.count - 1 : 1) : 0
        selectedID = targets.indices.contains(index) ? targets[index].id : nil
        capturePreviews()
    }

    /// Called only after successful activation, or when seeding the first interaction from the already-active Space.
    func didActivate(_ target: SwitchTarget) {
        activationRevision += 1
        let key = recencyKey(target)
        recentTargetKeys.removeAll { $0 == key }
        recentTargetKeys.insert(key, at: 0)
        if !visible { targets = orderedTargets(targets) }
    }

    private func recencyKey(_ target: SwitchTarget) -> String { target.space?.aliasKey ?? target.id }

    private func orderedTargets(_ items: [SwitchTarget]) -> [SwitchTarget] {
        // Space identity stays stable even when its representative window or AX fallback changes.
        let ranks = Dictionary(uniqueKeysWithValues: recentTargetKeys.enumerated().map { ($0.element, $0.offset) })
        return items.enumerated().sorted { left, right in
            let leftRank = ranks[recencyKey(left.element)] ?? Int.max
            let rightRank = ranks[recencyKey(right.element)] ?? Int.max
            return leftRank == rightRank ? left.offset < right.offset : leftRank < rightRank
        }.map(\.element)
    }

    func capturePreviews() {
        guard !demo, preferences.mode == .preview else { return }
        let selected = selection.map { [$0] } ?? []
        previews.capture(selected + filtered.filter { $0.id != selectedID }, spaces: spaces)
    }

    func end() {
        visible = false
        holding = false
        renaming = false
        query = ""
        previews.stop()
    }

    func select(_ id: String) { selectedID = id }
    func step(_ distance: Int) {
        let items = filtered
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selectedID } ?? 0
        selectedID = items[((current + distance) % items.count + items.count) % items.count].id
    }
    func searchChanged() { if !filtered.contains(where: { $0.id == selectedID }) { selectedID = filtered.first?.id } }
    func commit() { guard !renaming, let selection else { return }; onCommit?(selection) }
    func cancel() { if renaming { cancelRename() } else { onCancel?() } }

    func rename() {
        guard let selection else { return }
        holding = false
        renameDraft = title(selection)
        renameError = nil
        renaming = true
        onRenameChanged?(true)
    }
    func cancelRename() { renaming = false; renameError = nil; onRenameChanged?(false) }
    func saveName() {
        guard let selection else { return }
        let value = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { renameError = "请输入一个名称"; return }
        guard value.count <= 60 else { renameError = "名称最多 60 个字符"; return }
        var state = store.state
        if value == selection.originalTitle { state.aliases.removeValue(forKey: selection.id) } else { state.aliases[selection.id] = value }
        do { try store.save(state); aliases = state.aliases; cancelRename(); searchChanged() }
        catch { renameError = "名称未保存：\(error.localizedDescription)" }
    }

    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
        } catch { message = "登录启动未更改：\(error.localizedDescription)" }
    }
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openPrivacy("Privacy_Accessibility")
    }
    func requestRecording() { _ = CGRequestScreenCaptureAccess(); openPrivacy("Privacy_ScreenCapture") }
    func openPrivacy(_ section: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(section)") { NSWorkspace.shared.open(url) }
    }
}
