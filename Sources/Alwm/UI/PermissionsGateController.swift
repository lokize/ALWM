import AppKit
import SwiftUI

@MainActor
public final class PermissionsGateController {
    private var window: NSWindow?
    public var onReady: (() -> Void)?
    public var onQuit: (() -> Void)?

    public init() {}

    public func show() {
        if window != nil {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = PermissionsGateView(
            onContinue: { [weak self] in
                self?.close()
                self?.onReady?()
            },
            onQuit: { [weak self] in
                self?.onQuit?()
            },
            onRelaunch: {
                Permissions.relaunchApp()
            }
        )
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = "ALWM Permissions"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 560, height: 680))
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    public func close() {
        window?.orderOut(nil)
        window = nil
    }
}

struct PermissionsGateView: View {
    @State private var snap = Permissions.snapshot()
    @State private var timer: Timer?
    @State private var repairNote: String?

    var onContinue: () -> Void
    var onQuit: () -> Void
    var onRelaunch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ALWM Permissions")
                        .font(.title2.weight(.semibold))
                    Text("Conceda o que faltar. Acessibilidade e Input Monitoring são obrigatórios; captura precisa de Screen Recording.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Use sempre ./scripts/package.sh. Não apague ~/.config/alwm/signing/.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            permissionCard(
                title: "Accessibility",
                badge: "Required",
                badgeColor: .orange,
                granted: snap.accessibility,
                detail: "Permite inspecionar, focar, mover e redimensionar janelas."
            ) {
                Permissions.requestAccessibility()
            } openSettings: {
                Permissions.openAccessibilitySettings()
            }

            permissionCard(
                title: "Input Monitoring",
                badge: "Required",
                badgeColor: .orange,
                granted: snap.inputMonitoring,
                detail: "Hotkeys globais e gestos do trackpad."
            ) {
                Permissions.requestInputMonitoring()
            } openSettings: {
                Permissions.openInputMonitoringSettings()
            }

            permissionCard(
                title: "Screen Recording",
                badge: "Capture",
                badgeColor: .blue,
                granted: snap.screenRecording,
                detail: snap.screenRecording
                    ? "OK — captura liberada para este processo."
                    : "Se o interruptor em Ajustes já está AZUL mas aqui continua Not Granted, a permissão está ligada a uma assinatura antiga. Use Reparar.",
                grantTitle: "Abrir Ajustes",
                grant: {
                    Permissions.requestScreenRecording()
                    Permissions.openScreenRecordingSettings()
                },
                openSettings: {
                    Permissions.openScreenRecordingSettings()
                }
            )

            if !snap.screenRecording {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Ajustes ON + app Negado = entrada TCC antiga")
                        .font(.callout.weight(.semibold))
                    Text("1. Clique Reparar (limpa a permissão antiga)\n2. Ligue de novo o interruptor do ALWM (azul)\n3. Reiniciar ALWM")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Reparar Screen Recording") {
                            repairScreenRecording()
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Reiniciar ALWM", action: onRelaunch)
                    }
                    if let repairNote {
                        Text(repairNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.orange.opacity(0.12))
                )
            }

            permissionCard(
                title: "Microphone",
                badge: "Recording",
                badgeColor: .secondary,
                granted: snap.microphone,
                detail: "Opcional. Sem microfone a gravação continua com áudio do sistema."
            ) {
                Task { _ = await Permissions.ensureMicrophoneAccess() }
            } openSettings: {
                Permissions.openMicrophoneSettings()
            }

            Spacer(minLength: 0)

            HStack {
                Button("Quit ALWM", role: .destructive, action: onQuit)
                Spacer()
                Button("Check Again") { refreshSnap() }
                Button("Relaunch ALWM", action: onRelaunch)
                Button(continueTitle) {
                    onContinue()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!snap.requiredGranted)
            }
        }
        .padding(22)
        .frame(width: 560, height: 680)
        .onAppear {
            refreshSnap()
            timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
                Task { @MainActor in
                    refreshSnap()
                }
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    private var continueTitle: String {
        snap.screenRecording ? "Continue" : "Continue Without Screen Recording"
    }

    private func refreshSnap() {
        Task { @MainActor in
            _ = await Permissions.refreshScreenRecordingGranted()
            snap = Permissions.snapshot()
        }
    }

    private func repairScreenRecording() {
        let ok = Permissions.resetScreenRecordingTCC()
        repairNote = ok
            ? "Permissão antiga limpa. Abra Ajustes, ligue ALWM (azul) e Reinicie."
            : "Não foi possível limpar via tccutil. Remova ALWM manualmente em Ajustes e ligue de novo."
        Permissions.requestScreenRecording()
        Permissions.openScreenRecordingSettings()
        refreshSnap()
    }

    @ViewBuilder
    private func permissionCard(
        title: String,
        badge: String,
        badgeColor: Color,
        granted: Bool,
        detail: String,
        grantTitle: String = "Grant Access",
        grant: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(granted ? Color.green : Color.orange)
                Text(title)
                    .font(.headline)
                Text(badge)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(badgeColor.opacity(0.15)))
                    .foregroundStyle(badgeColor)
                Spacer()
                Text(granted ? "Granted" : "Not Granted")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(granted ? .green : .orange)
            }
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !granted {
                HStack {
                    Button(grantTitle, action: grant)
                    Button("Open Settings", action: openSettings)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}
