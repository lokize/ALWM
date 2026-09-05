import Foundation
import Combine
import AlwmStatsKit
import AlwmL10n

final class NowPlayingStore: ObservableObject, @unchecked Sendable {
    static let shared = NowPlayingStore()

    @Published private(set) var snapshot = NowPlayingSampler.Snapshot()

    var localeCode: () -> String = { PluginL10n.currentCode }
    var onChange: (() -> Void)?

    private let sampler = NowPlayingSampler()
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

    func send(_ command: NowPlayingSampler.Command) {
        _ = sampler.send(command)
        // Refresh soon after a transport action.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.tick()
        }
    }

    private func tick() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.sampler.refresh { [weak self] next in
                guard let self else { return }
                DispatchQueue.main.async {
                    self.lock.lock()
                    self.snapshot = next
                    self.lock.unlock()
                    self.onChange?()
                }
            }
        }
    }

    var barLabel: String {
        lock.lock()
        let snap = snapshot
        lock.unlock()
        guard snap.present else { return "♪ —" }
        let mark = snap.isPlaying ? "▶" : "⏸"
        let title = snap.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let artist = snap.artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let body: String
        if !title.isEmpty, !artist.isEmpty {
            body = "\(title) — \(artist)"
        } else if !title.isEmpty {
            body = title
        } else if !artist.isEmpty {
            body = artist
        } else {
            body = snap.appName ?? "Now Playing"
        }
        return "\(mark) \(truncate(body, max: 28))"
    }

    var tooltip: String {
        let loc = localeCode()
        return "\(barLabel) — \(PluginL10n.t("plugin.common.click_to_open", locale: loc))"
    }

    private func truncate(_ s: String, max: Int) -> String {
        guard s.count > max else { return s }
        let idx = s.index(s.startIndex, offsetBy: max - 1)
        return String(s[..<idx]) + "…"
    }
}
