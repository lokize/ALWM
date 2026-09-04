import AppKit
import Foundation

/// Orchestrates screenshot / screen recording flows (overlay → capture → notify).
@MainActor
final class CaptureController: NSObject {
    private let overlay = CaptureSelectionOverlay()
    private let recorder = ScreenRecorder()
    private var recordingHUD: NSPanel?
    private var hudStopBridge: RecordingHUDStopBridge?
    private var micWarned = false
    private var isStopping = false

    var isRecording: Bool { recorder.isRecording }

    override init() {
        super.init()
        recorder.onMicUnavailable = { [weak self] in
            guard let self, !self.micWarned else { return }
            self.micWarned = true
            self.notify(title: L10n.t("capture.mic.unavailable.title"),
                        body: L10n.t("capture.mic.unavailable.body"))
        }
    }

    func captureRegion() {
        Task { @MainActor in
            guard await ensureScreenRecording() else { return }
            overlay.present { [weak self] result in
                guard let self else { return }
                switch result {
                case .cancelled:
                    break
                case .region(let rect):
                    Task { await self.runScreenshot { try await ScreenshotService.captureRegion(rect) } }
                case .fullDisplay(let screen):
                    Task { await self.runScreenshot { try await ScreenshotService.captureDisplay(screen) } }
                }
            }
        }
    }

    func captureDisplay() {
        Task { @MainActor in
            guard await ensureScreenRecording() else { return }
            let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                ?? NSScreen.main
                ?? NSScreen.screens.first
            guard let screen else { return }
            await runScreenshot { try await ScreenshotService.captureDisplay(screen) }
        }
    }

    func toggleRecording() {
        Task { @MainActor in
            if recorder.isRecording {
                await stopRecording()
                return
            }
            guard await ensureScreenRecording() else { return }
            overlay.present { [weak self] result in
                guard let self else { return }
                switch result {
                case .cancelled:
                    break
                case .region(let rect):
                    let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) })
                        ?? NSScreen.main
                        ?? NSScreen.screens.first
                    guard let screen else { return }
                    Task { await self.startRecording(screen: screen, region: rect) }
                case .fullDisplay(let screen):
                    Task { await self.startRecording(screen: screen, region: nil) }
                }
            }
        }
    }

    private func startRecording(screen: NSScreen, region: NSRect?) async {
        do {
            try await recorder.start(displayScreen: screen, region: region)
            showRecordingHUD()
            notify(title: L10n.t("capture.record.started.title"),
                   body: L10n.t("capture.record.started.body"))
        } catch {
            NSLog("[ALWM][Capture] record start failed: \(error)")
            notify(title: L10n.t("capture.error.title"),
                   body: L10n.t("capture.error.record_start"))
        }
    }

    private func stopRecording() async {
        guard !isStopping else { return }
        isStopping = true
        overlay.cancelActive()
        hideRecordingHUD()

        // Don't await teardown on the caller's critical path longer than needed —
        // hand off so menu/workspace bar stay interactive while the file finalizes.
        let recorder = self.recorder
        Task { @MainActor in
            defer { self.isStopping = false }
            do {
                let url = try await recorder.stop()
                try? await Task.sleep(nanoseconds: 200_000_000)
                CaptureIO.reveal(url)
                self.notify(title: L10n.t("capture.record.saved.title"),
                            body: url.path)
            } catch {
                NSLog("[ALWM][Capture] record stop failed: \(error)")
                // Still open the Movies folder so the user can inspect what landed.
                CaptureIO.revealFolder(CaptureIO.moviesDir)
                self.notify(title: L10n.t("capture.error.title"),
                            body: L10n.t("capture.error.record_stop"))
            }
        }
    }

    private func runScreenshot(_ work: () async throws -> URL) async {
        do {
            let url = try await work()
            CaptureIO.reveal(url)
            notify(title: L10n.t("capture.shot.saved.title"),
                   body: url.lastPathComponent)
        } catch {
            NSLog("[ALWM][Capture] screenshot failed: \(error)")
            notify(title: L10n.t("capture.error.title"),
                   body: L10n.t("capture.error.screenshot"))
        }
    }

    private func ensureScreenRecording() async -> Bool {
        if await Permissions.refreshScreenRecordingGranted() { return true }

        Permissions.requestScreenRecording()
        try? await Task.sleep(nanoseconds: 500_000_000)
        if await Permissions.refreshScreenRecordingGranted() { return true }

        let alert = NSAlert()
        alert.messageText = L10n.t("capture.permission.screen.title")
        alert.informativeText = """
        \(L10n.t("capture.permission.screen.body"))

        Se o interruptor em Ajustes já está ligado mas a captura falha, a permissão está presa a uma assinatura antiga. Use Reparar no painel de permissões (ou tccutil reset).
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.t("capture.permission.open_settings"))
        alert.addButton(withTitle: "Reparar TCC")
        alert.addButton(withTitle: L10n.t("capture.permission.relaunch"))
        alert.addButton(withTitle: L10n.t("common.cancel"))
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            Permissions.openScreenRecordingSettings()
        case .alertSecondButtonReturn:
            _ = Permissions.resetScreenRecordingTCC()
            Permissions.requestScreenRecording()
            Permissions.openScreenRecordingSettings()
        case .alertThirdButtonReturn:
            Permissions.relaunchApp()
        default:
            break
        }
        return false
    }

    private func showRecordingHUD() {
        hideRecordingHUD()
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hasShadow = true
        panel.ignoresMouseEvents = false

        let root = NSView(frame: panel.contentView!.bounds)
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        root.layer?.cornerRadius = 10

        let dot = NSView(frame: NSRect(x: 12, y: 14, width: 12, height: 12))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 6
        root.addSubview(dot)

        let bridge = RecordingHUDStopBridge { [weak self] in
            Task { @MainActor in
                await self?.stopRecording()
            }
        }
        hudStopBridge = bridge

        let btn = NSButton(frame: NSRect(x: 32, y: 4, width: 120, height: 32))
        btn.title = L10n.t("capture.record.stop")
        btn.bezelStyle = .inline
        btn.isBordered = false
        btn.contentTintColor = .white
        // Nonisolated bridge target for the AppKit action.
        btn.target = bridge
        btn.action = #selector(RecordingHUDStopBridge.stopClicked)
        root.addSubview(btn)

        panel.contentView = root
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - 80, y: f.maxY - 56))
        }
        panel.orderFrontRegardless()
        recordingHUD = panel
    }

    private func hideRecordingHUD() {
        recordingHUD?.orderOut(nil)
        recordingHUD = nil
        hudStopBridge = nil
    }

    private func notify(title: String, body: String) {
        NSLog("[ALWM][Capture] %@ — %@", title, body)
        NSSound(named: "Tink")?.play()
    }
}

/// HUD stop button target (nonisolated).
private final class RecordingHUDStopBridge: NSObject {
    private let onStop: () -> Void

    init(onStop: @escaping () -> Void) {
        self.onStop = onStop
    }

    @objc func stopClicked() {
        onStop()
    }
}
