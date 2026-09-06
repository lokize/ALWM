import AppKit
import Foundation
import Combine
import AlwmStatsKit
import AlwmL10n

final class GPUStore: ObservableObject, @unchecked Sendable {
    static let shared = GPUStore()

    @Published private(set) var snapshot = GPUSampler.Snapshot()
    @Published private(set) var history: [Double] = Array(repeating: 0, count: 60)

    var localeCode: () -> String = { PluginL10n.currentCode }
    var onChange: (() -> Void)?

    private let sampler = GPUSampler()
    private var timer: Timer?
    private let historyLimit = 60
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
            let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
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
        if next.present {
            var h = history
            h.append(next.utilization)
            if h.count > historyLimit {
                h.removeFirst(h.count - historyLimit)
            }
            history = h
        }
        lock.unlock()
        onChange?()
    }

    var barLabel: String {
        lock.lock()
        let snap = snapshot
        lock.unlock()
        guard snap.present else { return "—" }
        let pct = Int((snap.utilization * 100).rounded())
        return "\(pct)"
    }

    var chipTint: NSColor {
        lock.lock()
        let usage = snapshot.utilization
        let present = snapshot.present
        lock.unlock()
        guard present else { return .secondaryLabelColor }
        return StatsBarChipPressure.tint(for: usage)
    }

    var tooltip: String {
        let loc = localeCode()
        lock.lock()
        let snap = snapshot
        lock.unlock()
        guard snap.present else {
            return "GPU — \(PluginL10n.t("plugin.common.click_to_open", locale: loc))"
        }
        let pct = Int((snap.utilization * 100).rounded())
        return "GPU \(pct)% — \(PluginL10n.t("plugin.common.click_to_open", locale: loc))"
    }
}
