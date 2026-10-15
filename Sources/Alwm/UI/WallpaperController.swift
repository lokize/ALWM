import AppKit
import AVFoundation
import Combine
import CoreGraphics
import Foundation

enum WallpaperNotificationContent {
    static let title = "Papel de parede alterado"

    struct Payload: Hashable {
        let title: String
        let subtitle: String
        let body: String
        let wallpaperURL: URL
    }

    static func make(for url: URL, relativeTo root: URL? = nil) -> Payload {
        let filePath = url.standardizedFileURL.path
        let parentFolder = url.deletingLastPathComponent().lastPathComponent
        let folder: String
        if let root {
            let rootPath = root.standardizedFileURL.path
            let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            if filePath.hasPrefix(rootPrefix) {
                let relativeFilePath = String(filePath.dropFirst(rootPrefix.count))
                let relativeFolder = (relativeFilePath as NSString).deletingLastPathComponent
                folder = relativeFolder == "." || relativeFolder.isEmpty
                    ? root.lastPathComponent
                    : relativeFolder
            } else {
                folder = parentFolder
            }
        } else {
            folder = parentFolder
        }
        return Payload(
            title: title,
            subtitle: folder.isEmpty ? "Papéis de parede" : folder,
            body: url.deletingPathExtension().lastPathComponent,
            wallpaperURL: url
        )
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

struct WallpaperRotationStatus: Equatable {
    let rotationEnabled: Bool
    let intervalSeconds: Double
    let intervalUnit: WallpaperIntervalUnit
    let secondsUntilNextChange: Int?

    static func remainingSeconds(until deadline: Date?, now: Date) -> Int? {
        guard let deadline else { return nil }
        return max(0, Int(ceil(deadline.timeIntervalSince(now))))
    }

    static func nextChangeText(secondsRemaining: Int?) -> String? {
        guard let secondsRemaining else { return nil }
        let hours = secondsRemaining / 3600
        let minutes = (secondsRemaining % 3600) / 60
        let seconds = secondsRemaining % 60
        if hours > 0 {
            return minutes > 0 ? "Próximo em \(hours) h \(minutes) min" : "Próximo em \(hours) h"
        }
        if minutes > 0 { return "Próximo em \(minutes) min \(seconds) s" }
        return "Próximo em \(seconds) s"
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

    static func selectAndPreview(
        from files: [URL],
        after current: URL?,
        pending: URL?,
        order: WallpaperOrder
    ) -> (selected: URL?, upcoming: URL?) {
        let selected = pending.flatMap { files.contains($0) ? $0 : nil }
            ?? next(from: files, after: current, order: order)
        guard let selected else { return (nil, nil) }
        return (selected, next(from: files, after: selected, order: order))
    }
}

enum WallpaperActiveSelection {
    static func preferred(
        from wallpapers: [CGDirectDisplayID: WallpaperNotificationContent.Payload],
        primaryDisplayID: CGDirectDisplayID
    ) -> WallpaperNotificationContent.Payload? {
        wallpapers[primaryDisplayID]
            ?? wallpapers.keys.sorted().first.flatMap { wallpapers[$0] }
    }
}

struct WallpaperNavigationHistory: Equatable {
    private(set) var backward: [URL] = []
    private(set) var forward: [URL] = []

    mutating func recordAdvance(from current: URL?, to selected: URL) {
        guard let current, current != selected else { return }
        if forward.last == selected {
            backward.append(current)
            forward.removeLast()
        } else {
            backward.append(current)
            forward.removeAll()
        }
    }

    mutating func moveBackward(from current: URL?) -> URL? {
        guard let previous = backward.popLast() else { return nil }
        if let current, current != previous { forward.append(current) }
        return previous
    }
}

@MainActor
final class WallpaperController: ObservableObject {
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
    private var nextRotationDate: Date?
    private var videoSessions: [CGDirectDisplayID: VideoSession] = [:]
    private var previousByScreen: [String: URL] = [:]
    private var pendingByScreen: [String: URL] = [:]
    private var historyByScreen: [String: WallpaperNavigationHistory] = [:]
    private var observers: [NSObjectProtocol] = []
    @Published private(set) var activeWallpaper: WallpaperNotificationContent.Payload?
    @Published private(set) var upcomingWallpaper: WallpaperNotificationContent.Payload?
    @Published private(set) var canGoToPreviousWallpaper = false
    @Published private(set) var rotationStatus = WallpaperRotationStatus(
        rotationEnabled: WallpaperSettings.default.rotationEnabled,
        intervalSeconds: WallpaperSettings.default.intervalSeconds,
        intervalUnit: WallpaperSettings.default.intervalUnit,
        secondsUntilNextChange: nil
    )

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
        nextRotationDate = nil
        if !next.enabled {
            stopVideos()
            activeWallpaper = nil
            upcomingWallpaper = nil
            updateRotationStatus()
            return
        }
        if shouldAdvance {
            pendingByScreen.removeAll()
            historyByScreen.removeAll()
            advance(resetRotationTimer: false)
        } else if muteChanged {
            videoSessions.values.forEach { $0.setMuted(next.videoMuted) }
        }
        scheduleRotation()
    }

    func advance() {
        advance(resetRotationTimer: true)
    }

    private func advance(resetRotationTimer: Bool) {
        guard settings.enabled else { return }
        defer {
            if resetRotationTimer { scheduleRotation() }
        }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let connected = Set(screens.map(Self.displayID(of:)))
        for id in Array(videoSessions.keys) where !connected.contains(id) {
            videoSessions.removeValue(forKey: id)?.stop()
        }
        if settings.separatePerMonitor {
            var changedWallpapers: [WallpaperNotificationContent.Payload] = []
            var activeWallpapers: [CGDirectDisplayID: WallpaperNotificationContent.Payload] = [:]
            var upcomingWallpapers: [CGDirectDisplayID: WallpaperNotificationContent.Payload] = [:]
            for screen in screens {
                let id = Self.displayID(of: screen)
                let key = String(id)
                let directory = WallpaperCatalog.directory(settings: settings, displayID: id)
                let files = WallpaperCatalog.files(in: directory, recursive: settings.recursive)
                var history = historyByScreen[key, default: WallpaperNavigationHistory()]
                let selection = WallpaperCatalog.selectAndPreview(
                    from: files,
                    after: previousByScreen[key],
                    pending: history.forward.last ?? pendingByScreen[key],
                    order: settings.order
                )
                guard let url = selection.selected else {
                    pendingByScreen.removeValue(forKey: key)
                    continue
                }
                let changed = previousByScreen[key] != url
                history.recordAdvance(from: previousByScreen[key], to: url)
                historyByScreen[key] = history
                previousByScreen[key] = url
                if let upcoming = history.forward.last ?? selection.upcoming {
                    pendingByScreen[key] = upcoming
                    upcomingWallpapers[id] = notificationContent(for: upcoming, in: directory)
                } else {
                    pendingByScreen.removeValue(forKey: key)
                }
                if show(url, on: screen, id: id) {
                    let payload = notificationContent(for: url, in: directory)
                    activeWallpapers[id] = payload
                    if changed { changedWallpapers.append(payload) }
                }
            }
            activeWallpaper = WallpaperActiveSelection.preferred(
                from: activeWallpapers,
                primaryDisplayID: CGMainDisplayID()
            )
            upcomingWallpaper = WallpaperActiveSelection.preferred(
                from: upcomingWallpapers,
                primaryDisplayID: CGMainDisplayID()
            )
            WallpaperToastController.shared.show(changedWallpapers)
        } else {
            let files = WallpaperCatalog.files(in: settings.directory, recursive: settings.recursive)
            var history = historyByScreen["all", default: WallpaperNavigationHistory()]
            let selection = WallpaperCatalog.selectAndPreview(
                from: files,
                after: previousByScreen["all"],
                pending: history.forward.last ?? pendingByScreen["all"],
                order: settings.order
            )
            guard let url = selection.selected else {
                pendingByScreen.removeValue(forKey: "all")
                upcomingWallpaper = nil
                return
            }
            let changed = previousByScreen["all"] != url
            history.recordAdvance(from: previousByScreen["all"], to: url)
            historyByScreen["all"] = history
            previousByScreen["all"] = url
            let upcoming = history.forward.last ?? selection.upcoming
            pendingByScreen["all"] = upcoming
            upcomingWallpaper = upcoming.map {
                notificationContent(for: $0, in: settings.directory)
            }
            var didApply = false
            for screen in screens {
                didApply = show(url, on: screen, id: Self.displayID(of: screen)) || didApply
            }
            if didApply {
                activeWallpaper = notificationContent(for: url, in: settings.directory)
            }
            if changed && didApply {
                WallpaperToastController.shared.show([notificationContent(for: url, in: settings.directory)])
            }
        }
        updatePreviousAvailability()
    }

    func retreat() {
        guard settings.enabled else { return }
        defer { scheduleRotation() }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        if settings.separatePerMonitor {
            var active: [CGDirectDisplayID: WallpaperNotificationContent.Payload] = [:]
            var upcoming: [CGDirectDisplayID: WallpaperNotificationContent.Payload] = [:]
            var changed: [WallpaperNotificationContent.Payload] = []
            for screen in screens {
                let id = Self.displayID(of: screen)
                let key = String(id)
                let directory = WallpaperCatalog.directory(settings: settings, displayID: id)
                var history = historyByScreen[key, default: WallpaperNavigationHistory()]
                guard let url = history.moveBackward(from: previousByScreen[key]) else { continue }
                historyByScreen[key] = history
                previousByScreen[key] = url
                pendingByScreen[key] = history.forward.last
                guard show(url, on: screen, id: id) else { continue }
                let payload = notificationContent(for: url, in: directory)
                active[id] = payload
                changed.append(payload)
                if let next = history.forward.last {
                    upcoming[id] = notificationContent(for: next, in: directory)
                }
            }
            activeWallpaper = WallpaperActiveSelection.preferred(from: active, primaryDisplayID: CGMainDisplayID())
            upcomingWallpaper = WallpaperActiveSelection.preferred(from: upcoming, primaryDisplayID: CGMainDisplayID())
            WallpaperToastController.shared.show(changed)
        } else {
            var history = historyByScreen["all", default: WallpaperNavigationHistory()]
            guard let url = history.moveBackward(from: previousByScreen["all"]) else { return }
            historyByScreen["all"] = history
            previousByScreen["all"] = url
            pendingByScreen["all"] = history.forward.last
            var didApply = false
            for screen in screens {
                didApply = show(url, on: screen, id: Self.displayID(of: screen)) || didApply
            }
            if didApply {
                activeWallpaper = notificationContent(for: url, in: settings.directory)
                upcomingWallpaper = history.forward.last.map {
                    notificationContent(for: $0, in: settings.directory)
                }
                WallpaperToastController.shared.show([activeWallpaper].compactMap { $0 })
            }
        }
        updatePreviousAvailability()
    }

    private func updatePreviousAvailability() {
        let key = settings.separatePerMonitor ? String(CGMainDisplayID()) : "all"
        canGoToPreviousWallpaper = !(historyByScreen[key]?.backward.isEmpty ?? true)
    }

    private func scheduleRotation() {
        timer?.invalidate()
        timer = nil
        nextRotationDate = nil
        guard settings.enabled, settings.rotationEnabled else {
            updateRotationStatus()
            return
        }
        let interval = min(86400, max(1, settings.intervalSeconds))
        nextRotationDate = Date().addingTimeInterval(interval)
        updateRotationStatus()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rotationTimerFired() }
        }
    }

    private func rotationTimerFired() {
        guard let nextRotationDate else {
            updateRotationStatus()
            return
        }
        if nextRotationDate <= Date() {
            advance(resetRotationTimer: false)
            scheduleRotation()
        } else {
            updateRotationStatus()
        }
    }

    private func updateRotationStatus() {
        rotationStatus = WallpaperRotationStatus(
            rotationEnabled: settings.rotationEnabled,
            intervalSeconds: settings.intervalSeconds,
            intervalUnit: settings.intervalUnit,
            secondsUntilNextChange: WallpaperRotationStatus.remainingSeconds(
                until: nextRotationDate,
                now: Date()
            )
        )
    }

    private func notificationContent(for url: URL, in directory: String) -> WallpaperNotificationContent.Payload {
        let expandedDirectory = NSString(string: directory).expandingTildeInPath
        let root = URL(fileURLWithPath: expandedDirectory, isDirectory: true).standardizedFileURL
        return WallpaperNotificationContent.make(for: url, relativeTo: root)
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
        nextRotationDate = nil
        stopVideos()
        settings = .default
        previousByScreen.removeAll()
        pendingByScreen.removeAll()
        historyByScreen.removeAll()
        activeWallpaper = nil
        upcomingWallpaper = nil
        canGoToPreviousWallpaper = false
        updateRotationStatus()
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) } ?? 0
    }
}
