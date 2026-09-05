import Foundation
import Combine
import AlwmStatsKit
import AlwmL10n

final class CPUStore: ObservableObject, @unchecked Sendable {
    static let shared = CPUStore()

    @Published private(set) var snapshot = CPUSampler.Snapshot()
    @Published private(set) var history: [Double] = Array(repeating: 0, count: 60)

    var localeCode: () -> String = { PluginL10n.currentCode }
    var onChange: (() -> Void)?

    private let sampler = CPUSampler()
    private var timer: Timer?
    private let historyLimit = 60
    private let lock = NSLock()

    private init() {}

    func start() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.timer == nil else { return }
            _ = self.sampler.sample()
            let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
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
        h.append(next.totalUsage)
        if h.count > historyLimit {
            h.removeFirst(h.count - historyLimit)
        }
        history = h
        lock.unlock()
        onChange?()
    }

    var barLabel: String {
        lock.lock()
        let pct = Int((snapshot.totalUsage * 100).rounded())
        lock.unlock()
        return "CPU \(pct)%"
    }

    var tooltip: String {
        let loc = localeCode()
        return "\(barLabel) — \(PluginL10n.t("plugin.common.click_to_open", locale: loc))"
    }
}
