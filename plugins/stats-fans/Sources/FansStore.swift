import AppKit
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
        guard snap.present, let rpm = snap.primaryRPM else { return "—" }
        if let frac = snap.primaryFraction, frac > 0 {
            return "\(Int((frac * 100).rounded()))"
        }
        return "\(Int(rpm.rounded()))"
    }

    var chipUnit: String? {
        lock.lock()
        let snap = snapshot
        lock.unlock()
        guard snap.present, snap.primaryRPM != nil else { return nil }
        if let frac = snap.primaryFraction, frac > 0 { return nil }
        return "rpm"
    }

    var chipTint: NSColor {
        lock.lock()
        let snap = snapshot
        lock.unlock()
        guard snap.present else { return .secondaryLabelColor }
        if let frac = snap.primaryFraction {
            return StatsBarChipPressure.tint(for: frac)
        }
        return .labelColor
    }

    var tooltip: String {
        let loc = localeCode()
        lock.lock()
        let snap = snapshot
        lock.unlock()
        let detail: String
        if !snap.present || snap.primaryRPM == nil {
            detail = "FAN —"
        } else if let frac = snap.primaryFraction, frac > 0 {
            detail = "FAN \(Int((frac * 100).rounded()))%"
        } else if let rpm = snap.primaryRPM {
            detail = "FAN \(Int(rpm.rounded())) rpm"
        } else {
            detail = "FAN —"
        }
        return "\(detail) — \(PluginL10n.t("plugin.common.click_to_open", locale: loc))"
    }
}
