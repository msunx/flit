import AppKit
import ScreenCaptureKit

@MainActor
final class PreviewService {
    private var cache: [String: NSImage] = [:]
    private var dates: [String: Date] = [:]
    private var task: Task<Void, Never>?
    var onImage: ((String, NSImage) -> Void)?
    var onFailure: ((String) -> Void)?

    func image(for id: String) -> NSImage? { cache[id] }
    func stop() { task?.cancel(); task = nil }

    func capture(_ targets: [SwitchTarget], spaces: [SpaceInfo]) {
        stop()
        guard CGPreflightScreenCaptureAccess() else { return }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                let excluded = content.applications.filter { $0.processID == getpid() }
                // Capture only the active desktop on each display; inactive desktops retain their last actual capture.
                for space in spaces where space.isCurrent && !space.isFullscreen {
                    try Task.checkCancellation()
                    guard let display = content.displays.first(where: { $0.displayID == space.displayID }) else { continue }
                    let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
                    if let image = try? await self.snapshot(filter, width: display.width, height: display.height) { self.remember(image, id: space.aliasKey) }
                }
                for target in targets.prefix(32) {
                    try Task.checkCancellation()
                    if let date = dates[target.id], Date().timeIntervalSince(date) < 2 { continue }
                    guard let id = target.windowID, let window = content.windows.first(where: { $0.windowID == id }) else { continue }
                    let filter = SCContentFilter(desktopIndependentWindow: window)
                    if let image = try? await self.snapshot(filter, width: Int(window.frame.width), height: Int(window.frame.height)) {
                        try Task.checkCancellation()
                        self.remember(image, id: target.id)
                    }
                }
            } catch is CancellationError { }
            catch { if !Task.isCancelled { self.onFailure?("预览暂时不可用：\(error.localizedDescription)") } }
        }
    }

    private func snapshot(_ filter: SCContentFilter, width: Int, height: Int) async throws -> NSImage {
        let config = SCStreamConfiguration()
        config.width = 560
        config.height = max(120, min(560, Int(560 * Double(max(height, 1)) / Double(max(width, 1)))))
        config.showsCursor = false
        config.capturesAudio = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private func remember(_ image: NSImage, id: String) {
        cache[id] = image
        dates[id] = Date()
        if cache.count > 96, let oldest = dates.min(by: { $0.value < $1.value })?.key { dates.removeValue(forKey: oldest); cache.removeValue(forKey: oldest) }
        onImage?(id, image)
    }
}
