import AppKit
import Foundation
import Combine
import UserNotifications
import AlwmStatsKit
import AlwmL10n

struct SensorsAlertSettings: Codable, Equatable, Sendable {
    var enabled: Bool
    /// Notify when CPU / primary die reaches this °C.
    var cpuThresholdCelsius: Double
    /// Notify when GPU die reaches this °C (ignored when no GPU sensor).
    var gpuThresholdCelsius: Double
    /// Minimum seconds between notifications for the same channel.
    var cooldownSeconds: Int

    static let `default` = SensorsAlertSettings(
        enabled: false,
        cpuThresholdCelsius: 85,
        gpuThresholdCelsius: 85,
        cooldownSeconds: 120
    )
}

final class SensorsStore: ObservableObject, @unchecked Sendable {
    static let shared = SensorsStore()

    @Published private(set) var snapshot = SensorsSampler.Snapshot()
    @Published var useFahrenheit = false
    @Published var alerts = SensorsAlertSettings.default

    var localeCode: () -> String = { PluginL10n.currentCode }
    var onChange: (() -> Void)?

    private let sampler = SensorsSampler()
    private var timer: Timer?
    private let lock = NSLock()
    private let settingsURL: URL

    /// Rising-edge latch so we notify once per heat-up, not every tick.
    private var cpuOverThreshold = false
    private var gpuOverThreshold = false
    private var lastCPUNotifyAt = Date.distantPast
    private var lastGPUNotifyAt = Date.distantPast

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/alwm/plugins", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        settingsURL = dir.appendingPathComponent("dev.alwm.stats-sensors.json")
        loadSettings()
    }

    var isPresent: Bool {
        lock.lock()
        defer { lock.unlock() }
        return snapshot.present
    }

    func start() {
        SensorsNotifier.requestAuthorization()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
                self?.tick()
            }
            RunLoop.main.add(t, forMode: .common)
            self.timer = t
            self.tick()
        }
    }

    func stop() {
        DispatchQueue.main.async { [weak self] in
            self?.timer?.invalidate()
            self?.timer = nil
        }
    }

    func setAlertsEnabled(_ enabled: Bool) {
        alerts.enabled = enabled
        if !enabled {
            cpuOverThreshold = false
            gpuOverThreshold = false
        }
        saveSettings()
        onChange?()
    }

    func setCPUThreshold(_ celsius: Double) {
        alerts.cpuThresholdCelsius = min(110, max(50, celsius.rounded()))
        cpuOverThreshold = false
        saveSettings()
        onChange?()
    }

    func setGPUThreshold(_ celsius: Double) {
        alerts.gpuThresholdCelsius = min(110, max(50, celsius.rounded()))
        gpuOverThreshold = false
        saveSettings()
        onChange?()
    }

    private func tick() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let next = self.sampler.sample()
            DispatchQueue.main.async {
                self.lock.lock()
                self.snapshot = next
                self.lock.unlock()
                self.evaluateAlerts(snapshot: next)
                self.onChange?()
            }
        }
    }

    private func evaluateAlerts(snapshot: SensorsSampler.Snapshot) {
        guard alerts.enabled else { return }
        let loc = localeCode()
        let cool = TimeInterval(max(30, alerts.cooldownSeconds))

        if let cpu = snapshot.primaryCelsius {
            let over = cpu >= alerts.cpuThresholdCelsius
            if over, !cpuOverThreshold, Date().timeIntervalSince(lastCPUNotifyAt) >= cool {
                lastCPUNotifyAt = Date()
                SensorsNotifier.notify(
                    channel: .cpu,
                    celsius: cpu,
                    threshold: alerts.cpuThresholdCelsius,
                    useFahrenheit: useFahrenheit,
                    locale: loc
                )
            }
            cpuOverThreshold = over
        }

        if let gpu = snapshot.gpuCelsius {
            let over = gpu >= alerts.gpuThresholdCelsius
            if over, !gpuOverThreshold, Date().timeIntervalSince(lastGPUNotifyAt) >= cool {
                lastGPUNotifyAt = Date()
                SensorsNotifier.notify(
                    channel: .gpu,
                    celsius: gpu,
                    threshold: alerts.gpuThresholdCelsius,
                    useFahrenheit: useFahrenheit,
                    locale: loc
                )
            }
            gpuOverThreshold = over
        }
    }

    private func loadSettings() {
        guard let data = try? Data(contentsOf: settingsURL),
              let decoded = try? JSONDecoder().decode(SensorsAlertSettings.self, from: data)
        else { return }
        alerts = decoded
    }

    private func saveSettings() {
        guard let data = try? JSONEncoder().encode(alerts) else { return }
        try? data.write(to: settingsURL, options: .atomic)
    }

    var barLabel: String {
        lock.lock()
        let primary = snapshot.primaryCelsius
        lock.unlock()
        return StatsFormat.temperatureChip(primary)
    }

    var chipTint: NSColor {
        lock.lock()
        let c = snapshot.primaryCelsius
        let alertsOn = alerts.enabled
        let cpuLimit = alerts.cpuThresholdCelsius
        lock.unlock()
        guard let c else { return .secondaryLabelColor }
        if alertsOn, c >= cpuLimit { return .systemRed }
        if c >= 90 { return .systemRed }
        if c >= 75 { return .systemOrange }
        return .labelColor
    }

    var tooltip: String {
        let loc = localeCode()
        return "\(barLabel) — \(PluginL10n.t("plugin.common.click_to_open", locale: loc))"
    }
}

enum SensorsNotifier {
    enum Channel {
        case cpu, gpu
    }

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notify(
        channel: Channel,
        celsius: Double,
        threshold: Double,
        useFahrenheit: Bool,
        locale: String
    ) {
        let temp = StatsFormat.temperature(celsius, useFahrenheit: useFahrenheit)
        let limit = StatsFormat.temperature(threshold, useFahrenheit: useFahrenheit)
        let content = UNMutableNotificationContent()
        switch channel {
        case .cpu:
            content.title = PluginL10n.t("plugin.sensors.alert.cpu.title", locale: locale)
            content.body = PluginL10n.tf(
                "plugin.sensors.alert.body",
                locale: locale,
                temp, limit
            )
        case .gpu:
            content.title = PluginL10n.t("plugin.sensors.alert.gpu.title", locale: locale)
            content.body = PluginL10n.tf(
                "plugin.sensors.alert.body",
                locale: locale,
                temp, limit
            )
        }
        content.sound = .default
        let id = "sensors-\(channel)-\(Int(Date().timeIntervalSince1970))"
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}
