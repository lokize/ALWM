import AVFoundation
import AppKit
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

/// Records a display or region with video + system audio (+ optional mic) into a file.
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

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var outputURL: URL?
    private var stopping = false
    private var uiRecording = false
    private let outputBridge = RecordingOutputBridge()

    /// Completes when SCRecordingOutput finishes or fails after stop.
    private var finishWaiter: CheckedContinuation<Result<Void, Error>, Never>?

    var isRecording: Bool { uiRecording }

    var onMicUnavailable: (() -> Void)?

    override init() {
        super.init()
        outputBridge.owner = self
    }

    func start(displayScreen: NSScreen, region: NSRect?) async throws {
        guard !uiRecording, !stopping else { throw RecError.alreadyRecording }
        guard await Permissions.refreshScreenRecordingGranted() else { throw RecError.noPermission }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = Self.matchingDisplay(screen: displayScreen, in: content) else {
            throw RecError.noDisplay
        }
        let excluded = CaptureIO.excludeALWMWindowIDs(from: content)
        let filter = SCContentFilter(display: display, excludingWindows: excluded)

        let scale = displayScreen.backingScaleFactor
        let sf = displayScreen.frame
        let pixelW: Int
        let pixelH: Int
        if let region {
            pixelW = max(2, Int(region.width * scale) & ~1)
            pixelH = max(2, Int(region.height * scale) & ~1)
        } else {
            pixelW = max(2, Int(sf.width * scale) & ~1)
            pixelH = max(2, Int(sf.height * scale) & ~1)
        }

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
        if let region {
            let localX = region.minX - sf.minX
            let localYFromTop = sf.maxY - region.maxY
            config.sourceRect = CGRect(
                x: localX,
                y: localYFromTop,
                width: max(2, region.width),
                height: max(2, region.height)
            )
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
        uiRecording = true
        NSLog("[ALWM][Capture] recording started → %@", url.path)
    }

    func stop() async throws -> URL {
        guard uiRecording || stream != nil else { throw RecError.notRecording }
        guard !stopping else { throw RecError.notRecording }
        stopping = true
        uiRecording = false
        defer {
            stopping = false
            finishWaiter = nil
        }

        let active = stream
        let output = recordingOutput
        let url = outputURL
        stream = nil
        recordingOutput = nil
        outputURL = nil

        NSLog("[ALWM][Capture] stop: removing recording output…")

        let finishResult: Result<Void, Error> = await withCheckedContinuation { cont in
            self.finishWaiter = cont
            Task { @MainActor in
                if let active, let output {
                    do {
                        try active.removeRecordingOutput(output)
                    } catch {
                        NSLog("[ALWM][Capture] removeRecordingOutput: \(error.localizedDescription)")
                        // Fall through — stopCapture still finalizes if output was attached.
                    }
                    do {
                        try await active.stopCapture()
                    } catch {
                        NSLog("[ALWM][Capture] stopCapture: \(error.localizedDescription)")
                    }
                } else if let active {
                    try? await active.stopCapture()
                }

                // If delegate never fires, resolve after a short grace period by inspecting the file.
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if let waiter = self.finishWaiter {
                    self.finishWaiter = nil
                    waiter.resume(returning: .success(()))
                }
            }
        }

        if case .failure(let err) = finishResult {
            NSLog("[ALWM][Capture] recording failed: \(err.localizedDescription)")
            throw RecError.setupFailed(err.localizedDescription)
        }

        guard let url else {
            throw RecError.setupFailed("no output url")
        }

        // Brief poll — filesystem may lag the finish callback by a tick.
        for _ in 0..<15 {
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

    fileprivate func recordingDidStart() {
        NSLog("[ALWM][Capture] recordingOutputDidStartRecording")
    }

    fileprivate func recordingDidFinish() {
        NSLog("[ALWM][Capture] recordingOutputDidFinishRecording")
        if let waiter = finishWaiter {
            finishWaiter = nil
            waiter.resume(returning: .success(()))
        }
    }

    fileprivate func recordingDidFail(_ error: Error) {
        NSLog("[ALWM][Capture] recordingOutput didFail: \(error.localizedDescription)")
        if let waiter = finishWaiter {
            finishWaiter = nil
            waiter.resume(returning: .failure(error))
        }
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
        NSLog("[ALWM][Capture] stream stopped: \(error.localizedDescription)")
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
