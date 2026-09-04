import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

enum CaptureIO {
    static var picturesDir: URL {
        let base = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
        let dir = base.appendingPathComponent("ALWM", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var moviesDir: URL {
        let base = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        let dir = base.appendingPathComponent("ALWM", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    static func ensureMoviesDir() throws -> URL {
        let dir = moviesDir
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        return dir
    }

    static func timestampName(prefix: String, ext: String) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "\(prefix)_\(df.string(from: Date())).\(ext)"
    }

    @MainActor
    static func reveal(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            revealFolder(url.deletingLastPathComponent())
            return
        }
        // Prefer selecting the file; fall back to opening the folder.
        if !NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    @MainActor
    static func revealFolder(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    static func excludeALWMWindowIDs(from content: SCShareableContent) -> [SCWindow] {
        let myPID = ProcessInfo.processInfo.processIdentifier
        return content.windows.filter { $0.owningApplication?.processID == myPID }
    }
}

@MainActor
enum ScreenshotService {
    enum ShotError: Error {
        case noPermission
        case noDisplay
        case captureFailed(String)
    }

    /// Capture the display containing `screen` (full frame).
    static func captureDisplay(_ screen: NSScreen) async throws -> URL {
        guard Permissions.screenRecordingGranted() else { throw ShotError.noPermission }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = matchingDisplay(screen: screen, in: content) else {
            throw ShotError.noDisplay
        }
        let excluded = CaptureIO.excludeALWMWindowIDs(from: content)
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let config = SCStreamConfiguration()
        let scale = screen.backingScaleFactor
        config.width = max(1, Int(screen.frame.width * scale))
        config.height = max(1, Int(screen.frame.height * scale))
        config.showsCursor = true
        config.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return try writePNG(image)
    }

    /// Capture a global Cocoa rectangle (may span one display).
    static func captureRegion(_ rect: NSRect) async throws -> URL {
        guard Permissions.screenRecordingGranted() else { throw ShotError.noPermission }
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) })
                ?? NSScreen.main else {
            throw ShotError.noDisplay
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = matchingDisplay(screen: screen, in: content) else {
            throw ShotError.noDisplay
        }
        let excluded = CaptureIO.excludeALWMWindowIDs(from: content)
        let filter = SCContentFilter(display: display, excludingWindows: excluded)

        let sf = screen.frame
        let scale = screen.backingScaleFactor
        let localX = rect.minX - sf.minX
        let localYFromTop = (sf.maxY - rect.maxY)
        let source = CGRect(
            x: localX,
            y: localYFromTop,
            width: rect.width,
            height: rect.height
        )
        let config = SCStreamConfiguration()
        config.sourceRect = source
        config.width = max(1, Int(rect.width * scale))
        config.height = max(1, Int(rect.height * scale))
        config.showsCursor = true
        config.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return try writePNG(image)
    }

    private static func matchingDisplay(screen: NSScreen, in content: SCShareableContent) -> SCDisplay? {
        let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        if let num, let match = content.displays.first(where: { $0.displayID == num }) {
            return match
        }
        return content.displays.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
    }

    private static func writePNG(_ image: CGImage) throws -> URL {
        let url = CaptureIO.picturesDir.appendingPathComponent(
            CaptureIO.timestampName(prefix: "Screenshot", ext: "png")
        )
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw ShotError.captureFailed("png encode")
        }
        try data.write(to: url, options: .atomic)
        return url
    }
}
