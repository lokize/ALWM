import ApplicationServices
import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

public struct PermissionSnapshot: Equatable, Sendable {
    public var accessibility: Bool
    public var inputMonitoring: Bool
    public var screenRecording: Bool
    public var microphone: Bool

    public var requiredGranted: Bool { accessibility && inputMonitoring }
}

/// TCC helpers. Safe to call from any thread (API is process-wide).
public enum Permissions {
    public static func snapshot() -> PermissionSnapshot {
        PermissionSnapshot(
            accessibility: accessibilityGranted(),
            inputMonitoring: inputMonitoringGranted(),
            screenRecording: screenRecordingGranted(),
            microphone: microphoneGranted()
        )
    }

    public static func accessibilityGranted() -> Bool {
        let opts = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    public static func inputMonitoringGranted() -> Bool {
        CGPreflightListenEventAccess()
    }

    public static func screenRecordingGranted() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        // Cached positive from async ScreenCaptureKit probe (CGPreflight can lag / mismatch).
        return screenRecordingProbeCache
    }

    /// Last successful SCShareableContent probe. Updated by `refreshScreenRecordingGranted()`.
    nonisolated(unsafe) private static var screenRecordingProbeCache = false

    /// Authoritative check via ScreenCaptureKit (detects Settings-ON / process-DENIED mismatches).
    public static func refreshScreenRecordingGranted() async -> Bool {
        if CGPreflightScreenCaptureAccess() {
            screenRecordingProbeCache = true
            return true
        }
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            screenRecordingProbeCache = true
            return true
        } catch {
            screenRecordingProbeCache = false
            return false
        }
    }

    public static func microphoneGranted() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    public static func requestAccessibility() {
        guard !accessibilityGranted() else { return }
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    public static func requestInputMonitoring() {
        guard !inputMonitoringGranted() else { return }
        _ = CGRequestListenEventAccess()
    }

    public static func requestScreenRecording() {
        guard !screenRecordingGranted() else { return }
        _ = CGRequestScreenCaptureAccess()
    }

    /// Clears stale Screen Recording TCC rows for this bundle so a fresh toggle can match
    /// the current code signature (fixes “Settings ON but app still denied”).
    @discardableResult
    public static func resetScreenRecordingTCC() -> Bool {
        screenRecordingProbeCache = false
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        proc.arguments = ["reset", "ScreenCapture", "dev.alwm.ALWM"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            NSLog("[ALWM] tccutil reset ScreenCapture failed: \(error)")
            return false
        }
    }

    /// Returns `true` if the mic may be used. Prompts once when status is `.notDetermined`.
    public static func ensureMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    @MainActor
    public static func openAccessibilitySettings() {
        openPrivacyPane("Privacy_Accessibility")
    }

    @MainActor
    public static func openInputMonitoringSettings() {
        openPrivacyPane("Privacy_ListenEvent")
    }

    @MainActor
    public static func openScreenRecordingSettings() {
        // Sequoia+ Screen & System Audio Recording pane; fall back to classic anchor.
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ]
        for s in candidates {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
    }

    /// Quit and relaunch the running .app bundle (needed after toggling Screen Recording).
    @MainActor
    public static func relaunchApp() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    @MainActor
    public static func openMicrophoneSettings() {
        openPrivacyPane("Privacy_Microphone")
    }

    @MainActor
    private static func openPrivacyPane(_ anchor: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
            ?? URL(string: "x-apple.systempreferences:com.apple.preference.security")!
        NSWorkspace.shared.open(url)
    }

    /// Capture a window thumbnail when Screen Recording is granted (ScreenCaptureKit).
    public static func thumbnail(windowNumber: Int, maxWidth: CGFloat = 160) async -> NSImage? {
        guard screenRecordingGranted(), windowNumber > 0 else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let cgID = CGWindowID(windowNumber)
            guard let window = content.windows.first(where: { $0.windowID == cgID }) else { return nil }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            let srcW = max(window.frame.width, 1)
            let srcH = max(window.frame.height, 1)
            let scale = min(1, Double(maxWidth) / srcW)
            config.width = max(1, Int(srcW * scale))
            config.height = max(1, Int(srcH * scale))
            config.showsCursor = false
            config.captureResolution = .best
            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            return NSImage(
                cgImage: cgImage,
                size: NSSize(width: config.width, height: config.height)
            )
        } catch {
            return nil
        }
    }
}
