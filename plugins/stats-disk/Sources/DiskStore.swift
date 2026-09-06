import AppKit
import Foundation
import Combine
import AlwmStatsKit
import AlwmL10n

final class DiskStore: ObservableObject, @unchecked Sendable {
    static let shared = DiskStore()

    @Published private(set) var snapshot = DiskSampler.Snapshot()
    @Published private(set) var history: [Double] = Array(repeating: 0, count: 60)

    var localeCode: () -> String = { PluginL10n.currentCode }
    var onChange: (() -> Void)?

    private let sampler = DiskSampler()
    private var timer: Timer?
    private let historyLimit = 60
    private let lock = NSLock()

    private init() {}

    func start() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let t = Timer(timeInterval: 2.5, repeats: true) { [weak self] _ in
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
        var h = history
        h.append(next.usageFraction)
        if h.count > historyLimit {
            h.removeFirst(h.count - historyLimit)
        }
        history = h
        lock.unlock()
        onChange?()
    }

    var barLabel: String {
        lock.lock()
        let frac = snapshot.usageFraction
        lock.unlock()
        let pct = Int((frac * 100).rounded())
        return "\(pct)"
    }

    var chipTint: NSColor {
        lock.lock()
        let usage = snapshot.usageFraction
        lock.unlock()
        return StatsBarChipPressure.tint(for: usage)
    }

    var tooltip: String {
        let loc = localeCode()
        lock.lock()
        let pct = Int((snapshot.usageFraction * 100).rounded())
        lock.unlock()
        return "SSD \(pct)% — \(PluginL10n.t("plugin.common.click_to_open", locale: loc))"
    }
}
