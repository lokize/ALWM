import Foundation
import Combine
import AlwmStatsKit
import AlwmL10n

final class NetworkStore: ObservableObject, @unchecked Sendable {
    static let shared = NetworkStore()

    @Published private(set) var snapshot = NetworkSampler.Snapshot()
    @Published private(set) var downloadHistory: [Double] = Array(repeating: 0, count: 60)
    @Published private(set) var uploadHistory: [Double] = Array(repeating: 0, count: 60)
    @Published private(set) var connectivityHistory: [Bool] = Array(repeating: false, count: 48)
    @Published private(set) var publicIP: String?

    var localeCode: () -> String = { PluginL10n.currentCode }
    var onChange: (() -> Void)?

    private let sampler = NetworkSampler()
    private var timer: Timer?
    private let historyLimit = 60
    private let connectivityLimit = 48
    private let lock = NSLock()
    private var publicIPFetchedAt: Date?
    private var publicIPTask: URLSessionDataTask?

    private init() {}

    func start() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.timer == nil else { return }
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
            self?.publicIPTask?.cancel()
            self?.publicIPTask = nil
        }
    }

    private func tick() {
        let next = sampler.sample()
        lock.lock()
        snapshot = next
        var down = downloadHistory
        var up = uploadHistory
        var conn = connectivityHistory
        down.append(next.downloadBytesPerSec)
        up.append(next.uploadBytesPerSec)
        conn.append(next.internetReachable)
        if down.count > historyLimit { down.removeFirst(down.count - historyLimit) }
        if up.count > historyLimit { up.removeFirst(up.count - historyLimit) }
        if conn.count > connectivityLimit { conn.removeFirst(conn.count - connectivityLimit) }
        downloadHistory = down
        uploadHistory = up
        connectivityHistory = conn
        lock.unlock()
        maybeRefreshPublicIP(reachable: next.internetReachable)
        onChange?()
    }

    private func maybeRefreshPublicIP(reachable: Bool) {
        guard reachable else { return }
        if let at = publicIPFetchedAt, Date().timeIntervalSince(at) < 120, publicIP != nil { return }
        publicIPFetchedAt = Date()
        guard let url = URL(string: "https://api.ipify.org") else { return }
        publicIPTask?.cancel()
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data, let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !text.isEmpty
            else { return }
            DispatchQueue.main.async {
                self.publicIP = text
                self.onChange?()
            }
        }
        publicIPTask = task
        task.resume()
    }

    var barLabel: String {
        lock.lock()
        let down = StatsFormat.bytesPerSecond(snapshot.downloadBytesPerSec)
        let up = StatsFormat.bytesPerSecond(snapshot.uploadBytesPerSec)
        lock.unlock()
        // Compact chip: ↓x ↑y
        let d = down.replacingOccurrences(of: " ", with: "")
        let u = up.replacingOccurrences(of: " ", with: "")
        return "↓\(d) ↑\(u)"
    }

    var tooltip: String {
        let loc = localeCode()
        return "\(barLabel) — \(PluginL10n.t("plugin.common.click_to_open", locale: loc))"
    }
}
