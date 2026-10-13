import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import UserNotifications

enum WallpaperNotificationContent {
    static let title = "Papel de parede alterado"

    static func body(for url: URL) -> String {
        let folder = url.deletingLastPathComponent().lastPathComponent
        return "\(folder.isEmpty ? "Papéis de parede" : folder) — \(url.lastPathComponent)"
    }
}

enum WallpaperUpdatePolicy {
    static func shouldAdvance(from current: WallpaperSettings, to next: WallpaperSettings) -> Bool {
        current.enabled != next.enabled
            || current.directory != next.directory
            || current.order != next.order
            || current.recursive != next.recursive
            || current.separatePerMonitor != next.separatePerMonitor
            || current.monitorDirectories != next.monitorDirectories
    }
}

@MainActor
private final class WallpaperNotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = WallpaperNotificationService()

    private let center = UNUserNotificationCenter.current()
    private var permissionGranted: Bool?
    private var isRequestingPermission = false
    private var pendingURLs: [URL] = []

    private override init() {
        super.init()
        center.delegate = self
    }

    func notify(for urls: [URL]) {
        let uniqueURLs = Array(Set(urls)).sorted { $0.path < $1.path }
        guard !uniqueURLs.isEmpty else { return }
        if let permissionGranted {
            if permissionGranted { uniqueURLs.forEach(deliver(for:)) }
            return
        }
        pendingURLs.append(contentsOf: uniqueURLs)
        guard !isRequestingPermission else { return }
        isRequestingPermission = true
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            Task { @MainActor in
                guard let self else { return }
                self.isRequestingPermission = false
                self.permissionGranted = granted
                if let error {
                    NSLog("ALWM wallpaper notification: authorization failed: %@", error.localizedDescription)
                }
                let queued = self.pendingURLs
                self.pendingURLs.removeAll()
                if granted { queued.forEach(self.deliver(for:)) }
            }
        }
    }

    private func deliver(for url: URL) {
        let content = UNMutableNotificationContent()
        content.title = WallpaperNotificationContent.title
        content.body = WallpaperNotificationContent.body(for: url)
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request) { error in
            if let error {
                NSLog("ALWM wallpaper notification: failed to deliver %@: %@", url.path, error.localizedDescription)
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

enum WallpaperCatalog {
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "bmp", "webp"]
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    static func directory(settings: WallpaperSettings, displayID: CGDirectDisplayID) -> String {
        guard settings.separatePerMonitor else { return settings.directory }
        let override = settings.monitorDirectories[String(displayID)] ?? ""
        return override.isEmpty ? settings.directory : override
    }

    static func files(in directory: String, recursive: Bool) -> [URL] {
        guard !directory.isEmpty else { return [] }
        let root = URL(fileURLWithPath: NSString(string: directory).expandingTildeInPath, isDirectory: true)
        let keys: [URLResourceKey] = [.isRegularFileKey]
        let urls: [URL]
        if recursive {
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
            ) else { return [] }
            urls = enumerator.compactMap { $0 as? URL }
        } else {
            urls = (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
            )) ?? []
        }
        return urls.filter { url in
            let ext = url.pathExtension.lowercased()
            guard imageExtensions.contains(ext) || videoExtensions.contains(ext) else { return false }
            return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    static func next(from files: [URL], after previous: URL?, order: WallpaperOrder) -> URL? {
        guard !files.isEmpty else { return nil }
        if order == .alphabetical {
            guard let previous, let index = files.firstIndex(of: previous) else { return files[0] }
            return files[(index + 1) % files.count]
        }
        guard files.count > 1 else { return files[0] }
        return files.filter { $0 != previous }.randomElement() ?? files[0]
    }
}

@MainActor
final class WallpaperController {
    static let shared = WallpaperController()

    @MainActor private final class VideoSession {
        let window: NSWindow
        let player: AVQueuePlayer
        let looper: AVPlayerLooper

        init(url: URL, screen: NSScreen, muted: Bool) {
            window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            window.ignoresMouseEvents = true
            window.isOpaque = true
            window.backgroundColor = .black
            window.hasShadow = false
            let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            content.wantsLayer = true
            let layer = AVPlayerLayer()
            layer.frame = content.bounds
            layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layer.videoGravity = .resizeAspectFill
            content.layer?.addSublayer(layer)
            window.contentView = content
            player = AVQueuePlayer()
            player.isMuted = muted
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            layer.player = player
            window.orderFrontRegardless()
            player.play()
        }

        func stop() {
            player.pause()
            window.orderOut(nil)
        }

        func setMuted(_ muted: Bool) {
            player.isMuted = muted
        }
    }

    private var settings: WallpaperSettings = .default
    private var timer: Timer?
    private var videoSessions: [CGDirectDisplayID: VideoSession] = [:]
    private var previousByScreen: [String: URL] = [:]
    private var observers: [NSObjectProtocol] = []

    private init() {
        let sleep = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pauseVideos() }
        }
        let wake = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.resumeVideos() }
        }
        let screenSleep = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pauseVideos() }
        }
        let screenWake = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.resumeVideos() }
        }
        let screens = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
        observers = [sleep, wake, screenSleep, screenWake, screens]
    }

    func apply(_ next: WallpaperSettings) {
        guard settings != next else { return }
        let shouldAdvance = WallpaperUpdatePolicy.shouldAdvance(from: settings, to: next)
        let muteChanged = settings.videoMuted != next.videoMuted
        settings = next
        timer?.invalidate()
        timer = nil
        if !next.enabled {
            stopVideos()
            return
        }
        if shouldAdvance {
            advance()
        } else if muteChanged {
            videoSessions.values.forEach { $0.setMuted(next.videoMuted) }
        }
        if next.rotationEnabled {
            timer = Timer.scheduledTimer(withTimeInterval: min(86400, max(1, next.intervalSeconds)), repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.advance() }
            }
        }
    }

    func advance() {
        guard settings.enabled else { return }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let connected = Set(screens.map(Self.displayID(of:)))
        for id in Array(videoSessions.keys) where !connected.contains(id) {
            videoSessions.removeValue(forKey: id)?.stop()
        }
        if settings.separatePerMonitor {
            var changedURLs: [URL] = []
            for screen in screens {
                let id = Self.displayID(of: screen)
                let key = String(id)
                let directory = WallpaperCatalog.directory(settings: settings, displayID: id)
                let files = WallpaperCatalog.files(in: directory, recursive: settings.recursive)
                guard let url = WallpaperCatalog.next(from: files, after: previousByScreen[key], order: settings.order) else { continue }
                let changed = previousByScreen[key] != url
                previousByScreen[key] = url
                if show(url, on: screen, id: id), changed { changedURLs.append(url) }
            }
            WallpaperNotificationService.shared.notify(for: changedURLs)
        } else {
            let files = WallpaperCatalog.files(in: settings.directory, recursive: settings.recursive)
            guard let url = WallpaperCatalog.next(from: files, after: previousByScreen["all"], order: settings.order) else { return }
            let changed = previousByScreen["all"] != url
            previousByScreen["all"] = url
            var didApply = false
            for screen in screens {
                didApply = show(url, on: screen, id: Self.displayID(of: screen)) || didApply
            }
            if changed && didApply { WallpaperNotificationService.shared.notify(for: [url]) }
        }
    }

    @discardableResult
    private func show(_ url: URL, on screen: NSScreen, id: CGDirectDisplayID) -> Bool {
        videoSessions.removeValue(forKey: id)?.stop()
        if WallpaperCatalog.videoExtensions.contains(url.pathExtension.lowercased()) {
            videoSessions[id] = VideoSession(url: url, screen: screen, muted: settings.videoMuted)
            return true
        } else {
            do {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen)
                return true
            } catch {
                NSLog("ALWM wallpaper: failed to set %@: %@", url.path, error.localizedDescription)
                return false
            }
        }
    }

    private func pauseVideos() { videoSessions.values.forEach { $0.player.pause() } }
    private func resumeVideos() { videoSessions.values.forEach { $0.player.play() } }
    private func stopVideos() {
        videoSessions.values.forEach { $0.stop() }
        videoSessions.removeAll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        stopVideos()
        settings = .default
        previousByScreen.removeAll()
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) } ?? 0
    }
}
