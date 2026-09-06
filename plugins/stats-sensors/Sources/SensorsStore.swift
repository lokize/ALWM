import AppKit
import Foundation
import Combine
import AlwmStatsKit
import AlwmL10n

final class SensorsStore: ObservableObject, @unchecked Sendable {
    static let shared = SensorsStore()

    @Published private(set) var snapshot = SensorsSampler.Snapshot()
    @Published var useFahrenheit = false

    var localeCode: () -> String = { PluginL10n.currentCode }
    var onChange: (() -> Void)?

    private let sampler = SensorsSampler()
    private var timer: Timer?
    private let lock = NSLock()

    private init() {}

    var isPresent: Bool {
        lock.lock()
        defer { lock.unlock() }
        return snapshot.present
    }

    func start() {
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

    private func tick() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let next = self.sampler.sample()
            DispatchQueue.main.async {
                self.lock.lock()
                self.snapshot = next
                self.lock.unlock()
                self.onChange?()
            }
        }
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
        lock.unlock()
        guard let c else { return .secondaryLabelColor }
        if c >= 90 { return .systemRed }
        if c >= 75 { return .systemOrange }
        return .labelColor
    }

    var tooltip: String {
        let loc = localeCode()
        return "\(barLabel) — \(PluginL10n.t("plugin.common.click_to_open", locale: loc))"
    }
}
