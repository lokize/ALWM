import AVFoundation
import AppKit
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

/// Records a display, a region, or a single window with video + system audio
/// (+ optional mic) into a file.
///
/// Uses `SCRecordingOutput` (macOS 15+) instead of a hand-rolled AVAssetWriter pipeline —
/// the latter often produced empty Movies/ALWM folders when frames/audio failed to mux.
@MainActor
final class ScreenRecorder: NSObject {
    enum RecError: Error {
        case noPermission
        case noDisplay
        case alreadyRecording
        case notRecording
        case setupFailed(String)
    }

    enum Target {
        case display(NSScreen)
        case region(NSScreen, NSRect)
        case window(CaptureWindowTarget)
    }

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var outputURL: URL?
    private var stopping = false
    private var uiRecording = false
    private let outputBridge = RecordingOutputBridge()

    /// Resolves once the recording output has finalized (delegate) or a timeout elapses.
    private var finalizeWaiter: CheckedContinuation<Result<Void, Error>, Never>?
    private var finalizeResult: Result<Void, Error>?
    /// Resolves the caller of `stop()` after the stream is fully torn down.
    private var stopWaiter: CheckedContinuation<Result<Void, Error>, Never>?
    /// Keeps the display awake while recording so the stream is not paused mid-capture.
    private var activityToken: NSObjectProtocol?

    var isRecording: Bool { uiRecording }

    var onMicUnavailable: (() -> Void)?
    /// Fired when the stream stops on its own (display sleep, permission change, captured
    /// window closing…). The owner should finalize the file and update its UI.
    var onUnexpectedStop: (() -> Void)?

    override init() {
        super.init()
        outputBridge.owner = self
    }

    func start(target: Target) async throws {
        guard !uiRecording, !stopping, stream == nil else { throw RecError.alreadyRecording }
        guard await Permissions.refreshScreenRecordingGranted() else { throw RecError.noPermission }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let excluded = CaptureIO.excludeALWMWindowIDs(from: content)

        let filter: SCContentFilter
        var sourceRect: CGRect?
        switch target {
        case .display(let screen):
            guard let display = Self.matchingDisplay(screen: screen, in: content) else {
                throw RecError.noDisplay
            }
            filter = SCContentFilter(display: display, excludingWindows: excluded)
        case .region(let screen, let region):
            guard let display = Self.matchingDisplay(screen: screen, in: content) else {
                throw RecError.noDisplay
            }
            filter = SCContentFilter(display: display, excludingWindows: excluded)
            let sf = screen.frame
            sourceRect = CGRect(
                x: region.minX - sf.minX,
                y: sf.maxY - region.maxY,
                width: max(2, region.width),
                height: max(2, region.height)
            )
        case .window(let window):
            if let match = content.windows.first(where: { $0.windowID == window.id }) {
                filter = SCContentFilter(desktopIndependentWindow: match)
            } else {
                // Window vanished between the click and the start — fall back to its region.
                guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(window.frame) })
                        ?? NSScreen.main,
                      let display = Self.matchingDisplay(screen: screen, in: content)
                else { throw RecError.noDisplay }
                filter = SCContentFilter(display: display, excludingWindows: excluded)
                let sf = screen.frame
                sourceRect = CGRect(
                    x: window.frame.minX - sf.minX,
                    y: sf.maxY - window.frame.maxY,
                    width: max(2, window.frame.width),
                    height: max(2, window.frame.height)
                )
            }
        }

        let contentRect: CGRect
        let scale: CGFloat
        switch target {
        case .display(let screen):
            contentRect = screen.frame
            scale = screen.backingScaleFactor
        case .region(let screen, let region):
            contentRect = region
            scale = screen.backingScaleFactor
        case .window:
            contentRect = sourceRect ?? filter.contentRect
            scale = CGFloat(filter.pointPixelScale)
        }
        let pixelW = max(2, Int(contentRect.width * scale) & ~1)
        let pixelH = max(2, Int(contentRect.height * scale) & ~1)

        let wantMic = await Permissions.ensureMicrophoneAccess()
        if !wantMic { onMicUnavailable?() }

        let config = SCStreamConfiguration()
        config.width = pixelW
        config.height = pixelH
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 5
        config.showsCursor = true
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.captureMicrophone = wantMic
        if let sourceRect {
            config.sourceRect = sourceRect
        }

        try CaptureIO.ensureMoviesDir()

        let recConfig = SCRecordingOutputConfiguration()
        let fileType: AVFileType = recConfig.availableOutputFileTypes.contains(.mp4) ? .mp4
            : (recConfig.availableOutputFileTypes.contains(.mov) ? .mov : .mp4)
        let ext = fileType == .mov ? "mov" : "mp4"
        let url = CaptureIO.moviesDir.appendingPathComponent(
            CaptureIO.timestampName(prefix: "Recording", ext: ext)
        )
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }

        recConfig.outputURL = url
        recConfig.outputFileType = fileType
        if recConfig.availableVideoCodecTypes.contains(.h264) {
            recConfig.videoCodecType = .h264
        } else if let first = recConfig.availableVideoCodecTypes.first {
            recConfig.videoCodecType = first
        }

        let output = SCRecordingOutput(configuration: recConfig, delegate: outputBridge)
        let stream = SCStream(filter: filter, configuration: config, delegate: outputBridge)
        // Add recording output BEFORE startCapture so the first frame is included.
        try stream.addRecordingOutput(output)
        try await stream.startCapture()

        self.stream = stream
        self.recordingOutput = output
        self.outputURL = url
        self.finalizeResult = nil
        uiRecording = true
        beginActivity()
        NSLog("[ALWM][Capture] recording started → %@ (%dx%d)", url.path, pixelW, pixelH)
    }

    func stop() async throws -> URL {
        guard uiRecording || stream != nil else { throw RecError.notRecording }
        guard !stopping else { throw RecError.notRecording }
        stopping = true
        uiRecording = false

        let active = stream
        let output = recordingOutput
        let url = outputURL
        stream = nil
        recordingOutput = nil
        outputURL = nil

        NSLog("[ALWM][Capture] stop: finalizing recording output…")

        let finishResult: Result<Void, Error> = await withCheckedContinuation { cont in
            self.stopWaiter = cont
            Task { @MainActor in
                if let active, let output {
                    do {
                        // Removing the output is what finalizes the movie. Wait for the
                        // delegate (or timeout) BEFORE stopping capture so the tail of the
                        // recording is not dropped.
                        try active.removeRecordingOutput(output)
                    } catch {
                        NSLog("[ALWM][Capture] removeRecordingOutput: \(error.localizedDescription)")
                    }
                    let finalize = await self.waitForFinalize(timeout: 6)
                    try? await active.stopCapture()
                    self.resumeStop(finalize)
                } else if let active {
                    try? await active.stopCapture()
                    self.resumeStop(.success(()))
                } else {
                    self.resumeStop(.success(()))
                }
            }
        }
        stopping = false
        endActivity()

        if case .failure(let err) = finishResult {
            NSLog("[ALWM][Capture] recording failed: \(err.localizedDescription)")
            throw RecError.setupFailed(err.localizedDescription)
        }

        guard let url else {
            throw RecError.setupFailed("no output url")
        }

        // The file should exist once the output reports finish; poll briefly for the
        // filesystem/encoder to settle before handing the URL to the UI.
        for _ in 0..<30 {
            if FileManager.default.fileExists(atPath: url.path),
               let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? NSNumber,
               size.intValue >= 1024 {
                NSLog("[ALWM][Capture] stop: done → %@ (%@ bytes)", url.lastPathComponent, size)
                return url
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        if FileManager.default.fileExists(atPath: url.path),
           let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? NSNumber,
           size.intValue >= 512 {
            NSLog("[ALWM][Capture] stop: small file → %@ (%@ bytes)", url.lastPathComponent, size)
            return url
        }

        NSLog("[ALWM][Capture] stop: missing/empty file at %@", url.path)
        throw RecError.setupFailed("recording file missing or empty")
    }

    // MARK: - Finalize plumbing

    private func waitForFinalize(timeout: TimeInterval) async -> Result<Void, Error> {
        if let result = finalizeResult {
            finalizeResult = nil
            return result
        }
        return await withCheckedContinuation { cont in
            self.finalizeWaiter = cont
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let waiter = self.finalizeWaiter {
                    self.finalizeWaiter = nil
                    waiter.resume(returning: .success(()))
                }
            }
        }
    }

    private func resumeFinalize(_ result: Result<Void, Error>) {
        finalizeResult = result
        if let waiter = finalizeWaiter {
            finalizeWaiter = nil
            finalizeResult = nil
            waiter.resume(returning: result)
        }
    }

    private func resumeStop(_ result: Result<Void, Error>) {
        if let waiter = stopWaiter {
            stopWaiter = nil
            waiter.resume(returning: result)
        }
    }

    // MARK: - Activity

    private func beginActivity() {
        guard activityToken == nil else { return }
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleDisplaySleepDisabled, .idleSystemSleepDisabled],
            reason: "ALWM screen recording"
        )
    }

    private func endActivity() {
        if let activityToken {
            ProcessInfo.processInfo.endActivity(activityToken)
            self.activityToken = nil
        }
    }

    // MARK: - Delegate callbacks

    fileprivate func recordingDidStart() {
        NSLog("[ALWM][Capture] recordingOutputDidStartRecording")
    }

    fileprivate func recordingDidFinish() {
        NSLog("[ALWM][Capture] recordingOutputDidFinishRecording")
        resumeFinalize(.success(()))
    }

    fileprivate func recordingDidFail(_ error: Error) {
        NSLog("[ALWM][Capture] recordingOutput didFail: \(error.localizedDescription)")
        resumeFinalize(.failure(error))
    }

    fileprivate func streamDidStop(_ error: Error) {
        NSLog("[ALWM][Capture] stream stopped: \(error.localizedDescription)")
        guard !stopping, uiRecording else { return }
        uiRecording = false
        onUnexpectedStop?()
    }

    private static func matchingDisplay(screen: NSScreen, in content: SCShareableContent) -> SCDisplay? {
        let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        if let num, let match = content.displays.first(where: { $0.displayID == num }) {
            return match
        }
        return content.displays.first
    }
}

/// SCK callbacks hop to MainActor.
private final class RecordingOutputBridge: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
    nonisolated(unsafe) weak var owner: ScreenRecorder?

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let owner = self.owner
        Task { @MainActor in owner?.streamDidStop(error) }
    }

    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        let owner = self.owner
        Task { @MainActor in owner?.recordingDidStart() }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        let owner = self.owner
        Task { @MainActor in owner?.recordingDidFinish() }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        let owner = self.owner
        Task { @MainActor in owner?.recordingDidFail(error) }
    }
}
