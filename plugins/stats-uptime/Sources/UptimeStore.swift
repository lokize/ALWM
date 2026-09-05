import Foundation
import Combine
import AlwmStatsKit
import AlwmL10n

final class UptimeStore: ObservableObject, @unchecked Sendable {
    static let shared = UptimeStore()

    @Published private(set) var snapshot = UptimeSampler.Snapshot()

    var localeCode: () -> String = { PluginL10n.currentCode }
    var onChange: (() -> Void)?

    private let sampler = UptimeSampler()
    private var timer: Timer?
    private let lock = NSLock()

    private init() {}

    func start() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let t = Timer(timeInterval: 30.0, repeats: true) { [weak self] _ in
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
        let next = sampler.sample()
        lock.lock()
        snapshot = next
        lock.unlock()
        onChange?()
    }

    var barLabel: String {
        lock.lock()
        let seconds = snapshot.uptimeSeconds
        lock.unlock()
        return Self.compactUptime(seconds)
    }

    var tooltip: String {
        let loc = localeCode()
        return "\(barLabel) — \(PluginL10n.t("plugin.common.click_to_open", locale: loc))"
    }

    static func compactUptime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 {
            return "\(days)d \(hours)h"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}
