import Foundation
import Combine
import AlwmStatsKit
import AlwmL10n

final class BluetoothStore: ObservableObject, @unchecked Sendable {
    static let shared = BluetoothStore()

    @Published private(set) var snapshot = BluetoothSampler.Snapshot()

    var localeCode: () -> String = { PluginL10n.currentCode }
    var onChange: (() -> Void)?

    private let sampler = BluetoothSampler()
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
            let t = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
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
        guard snap.poweredOn else { return "BT —" }
        if let bat = snap.primaryBattery {
            return "BT \(Int((bat * 100).rounded()))%"
        }
        let connected = snap.connected.count
        if connected > 0 {
            return "BT \(connected)"
        }
        return "BT"
    }

    var tooltip: String {
        let loc = localeCode()
        return "\(barLabel) — \(PluginL10n.t("plugin.common.click_to_open", locale: loc))"
    }
}
