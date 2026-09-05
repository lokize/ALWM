import Foundation
import AppKit

/// Now Playing via AppleScript for Spotify and Music.
///
/// MediaRemote (`dlopen`) is intentionally avoided — it has crashed ALWM on current
/// macOS (`EXC_BAD_ACCESS` / block ABI mismatches). Scripting runs out-of-process.
public final class NowPlayingSampler: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public var present: Bool
        public var isPlaying: Bool
        public var title: String?
        public var artist: String?
        public var album: String?
        public var artworkData: Data?
        public var duration: Double?
        public var elapsed: Double?
        public var appName: String?

        public init(
            present: Bool = false,
            isPlaying: Bool = false,
            title: String? = nil,
            artist: String? = nil,
            album: String? = nil,
            artworkData: Data? = nil,
            duration: Double? = nil,
            elapsed: Double? = nil,
            appName: String? = nil
        ) {
            self.present = present
            self.isPlaying = isPlaying
            self.title = title
            self.artist = artist
            self.album = album
            self.artworkData = artworkData
            self.duration = duration
            self.elapsed = elapsed
            self.appName = appName
        }

        public var progress: Double {
            guard let duration, duration > 0, let elapsed else { return 0 }
            return min(max(elapsed / duration, 0), 1)
        }
    }

    public enum Command: UInt32, Sendable {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case stop = 3
        case nextTrack = 4
        case previousTrack = 5
    }

    private enum Source: String {
        case spotify
        case music
    }

    private let lock = NSLock()
    private var cached = Snapshot()
    private var lastSource: Source?
    private var artworkCacheURL: String?
    private var artworkCacheData: Data?
    private let workQueue = DispatchQueue(label: "dev.alwm.nowplaying.script", qos: .utility)
    private var refreshInFlight = false
    private var pendingCompletion: (@Sendable (Snapshot) -> Void)?

    public init() {}

    public func refresh(completion: @escaping @Sendable (Snapshot) -> Void) {
        workQueue.async { [weak self] in
            guard let self else { return }
            if self.refreshInFlight {
                self.pendingCompletion = completion
                return
            }
            self.refreshInFlight = true
            let snap = self.sampleNow()
            self.lock.lock()
            self.cached = snap
            self.lock.unlock()
            completion(snap)
            let again = self.pendingCompletion
            self.pendingCompletion = nil
            self.refreshInFlight = false
            if let again {
                self.refresh(completion: again)
            }
        }
    }

    public func currentSnapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    @discardableResult
    public func send(_ command: Command) -> Bool {
        lock.lock()
        let source = lastSource
        lock.unlock()
        guard let source else { return false }
        let verb: String
        switch command {
        case .play: verb = "play"
        case .pause: verb = "pause"
        case .togglePlayPause: verb = "playpause"
        case .stop: verb = "pause"
        case .nextTrack: verb = "next track"
        case .previousTrack: verb = "previous track"
        }
        let app = source == .spotify ? "Spotify" : "Music"
        let script = "tell application \"\(app)\" to \(verb)"
        return runAppleScript(script, timeout: 1.5) != nil
    }

    // MARK: - Sampling

    private func sampleNow() -> Snapshot {
        let spotifyRunning = isRunning(bundleID: "com.spotify.client")
        let musicRunning = isRunning(bundleID: "com.apple.Music")

        let spotify = spotifyRunning ? sampleSpotify() : nil
        let music = musicRunning ? sampleMusic() : nil

        let chosen: (Snapshot, Source)?
        if let spotify, spotify.isPlaying {
            chosen = (spotify, .spotify)
        } else if let music, music.isPlaying {
            chosen = (music, .music)
        } else if let spotify, spotify.present {
            chosen = (spotify, .spotify)
        } else if let music, music.present {
            chosen = (music, .music)
        } else {
            chosen = nil
        }

        guard let (snap, source) = chosen else {
            lock.lock()
            lastSource = nil
            lock.unlock()
            return Snapshot(present: false)
        }
        lock.lock()
        lastSource = source
        lock.unlock()
        return snap
    }

    private func sampleSpotify() -> Snapshot? {
        let script = """
        tell application "Spotify"
          if not (exists current track) then return "none"
          set st to player state as text
          set n to name of current track
          set a to artist of current track
          set al to album of current track
          set d to duration of current track
          set p to player position
          set art to artwork url of current track
          return st & character id 31 & n & character id 31 & a & character id 31 & al & character id 31 & d & character id 31 & p & character id 31 & art
        end tell
        """
        guard let raw = runAppleScript(script, timeout: 2.0)?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw != "none", !raw.isEmpty
        else { return nil }

        let parts = raw.split(separator: "\u{001f}", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 6 else { return nil }
        let state = parts[0].lowercased()
        let title = clean(parts[1])
        let artist = clean(parts[2])
        let album = clean(parts[3])
        // Spotify duration is milliseconds.
        let durationMs = Double(parts[4].replacingOccurrences(of: ",", with: ".")) ?? 0
        let elapsed = Double(parts[5].replacingOccurrences(of: ",", with: ".")) ?? 0
        let artURL = parts.count > 6 ? clean(parts[6]) : nil
        let isPlaying = state == "playing"
        let present = title != nil || artist != nil || isPlaying
        guard present else { return nil }

        var artwork: Data?
        if let artURL, artURL.hasPrefix("http") {
            artwork = artworkData(for: artURL)
        }

        return Snapshot(
            present: true,
            isPlaying: isPlaying,
            title: title,
            artist: artist,
            album: album,
            artworkData: artwork,
            duration: durationMs > 0 ? durationMs / 1000.0 : nil,
            elapsed: elapsed >= 0 ? elapsed : nil,
            appName: "Spotify"
        )
    }

    private func sampleMusic() -> Snapshot? {
        let script = """
        tell application "Music"
          if player state is stopped then return "none"
          if not (exists current track) then return "none"
          set st to player state as text
          set n to name of current track
          set a to artist of current track
          set al to album of current track
          set d to duration of current track
          set p to player position
          return st & character id 31 & n & character id 31 & a & character id 31 & al & character id 31 & d & character id 31 & p
        end tell
        """
        guard let raw = runAppleScript(script, timeout: 2.0)?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw != "none", !raw.isEmpty
        else { return nil }

        let parts = raw.split(separator: "\u{001f}", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 6 else { return nil }
        let state = parts[0].lowercased()
        let title = clean(parts[1])
        let artist = clean(parts[2])
        let album = clean(parts[3])
        let duration = Double(parts[4].replacingOccurrences(of: ",", with: ".")) ?? 0
        let elapsed = Double(parts[5].replacingOccurrences(of: ",", with: ".")) ?? 0
        let isPlaying = state == "playing"
        let present = title != nil || artist != nil || isPlaying
        guard present else { return nil }

        return Snapshot(
            present: true,
            isPlaying: isPlaying,
            title: title,
            artist: artist,
            album: album,
            artworkData: nil,
            duration: duration > 0 ? duration : nil,
            elapsed: elapsed >= 0 ? elapsed : nil,
            appName: "Music"
        )
    }

    // MARK: - Helpers

    private func isRunning(bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    private func clean(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private func artworkData(for urlString: String) -> Data? {
        lock.lock()
        if artworkCacheURL == urlString, let artworkCacheData {
            let data = artworkCacheData
            lock.unlock()
            return data
        }
        lock.unlock()

        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 1.5)
        request.httpMethod = "GET"
        let sem = DispatchSemaphore(value: 0)
        var result: Data?
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { sem.signal() }
            guard let data,
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  data.count > 64
            else { return }
            result = data
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 1.6)

        if let result {
            lock.lock()
            artworkCacheURL = urlString
            artworkCacheData = result
            lock.unlock()
        }
        return result
    }

    @discardableResult
    private func runAppleScript(_ source: String, timeout: TimeInterval) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", source]
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do {
            try proc.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.03)
        }
        if proc.isRunning {
            proc.terminate()
            proc.waitUntilExit()
            return nil
        }
        guard proc.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
