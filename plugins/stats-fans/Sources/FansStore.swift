import Foundation
import Combine
import AlwmStatsKit
import AlwmL10n

final class FansStore: ObservableObject, @unchecked Sendable {
    static let shared = FansStore()

    @Published private(set) var snapshot = FansSampler.Snapshot()

    var localeCode: () -> String = { PluginL10n.currentCode }
    var onChange: (() -> Void)?

    private let sampler = FansSampler()
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
        let snap = snapshot
        lock.unlock()
        guard snap.present, let rpm = snap.primaryRPM else { return "FAN —" }
        if let frac = snap.primaryFraction, frac > 0 {
            let pct = Int((frac * 100).rounded())
            return "FAN \(pct)%"
        }
        return "FAN \(Int(rpm.rounded()))"
    }

    var tooltip: String {
        let loc = localeCode()
        return "\(barLabel) — \(PluginL10n.t("plugin.common.click_to_open", locale: loc))"
    }
}
