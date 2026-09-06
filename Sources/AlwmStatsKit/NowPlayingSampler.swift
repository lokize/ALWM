import Foundation
import AppKit

/// Now Playing via AppleScript for Spotify, Music, and Safari (YouTube/etc.).
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
        case safari
    }

    private let lock = NSLock()
    private var cached = Snapshot()
    private var lastSource: Source?
    private var artworkCacheURL: String?
    private var artworkCacheData: Data?
    private let workQueue = DispatchQueue(label: "dev.alwm.nowplaying.script", qos: .utility)
    private var refreshInFlight = false
    private var pendingCompletion: (@Sendable (Snapshot) -> Void)?
    /// `nil` = unknown; false after Safari refuses "Allow JavaScript from Apple Events".
    private var safariJavaScriptOK: Bool?
    private var safariJavaScriptCheckedAt = Date.distantPast
    /// Last Safari media tab URL — JS must target this tab, not whatever is frontmost.
    private var lastSafariMediaURL: String?

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

    /// True when Safari transport works fully (JS enabled). Keystroke fallback may still work.
    public func safariControlsNeedPermission() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return lastSource == .safari && safariJavaScriptOK == false
    }

    @discardableResult
    public func send(_ command: Command) -> Bool {
        lock.lock()
        let source = lastSource
        lock.unlock()
        guard let source else { return false }
        if source == .safari {
            return sendSafari(command)
        }
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

    private func sendSafari(_ command: Command) -> Bool {
        // User may have just enabled Develop → Allow JavaScript from Apple Events.
        lock.lock()
        safariJavaScriptOK = nil
        lock.unlock()

        let js: String
        switch command {
        case .play:
            js = "(function(){var v=document.querySelector('video');if(!v)return '0';v.play();return '1';})()"
        case .pause, .stop:
            js = "(function(){var v=document.querySelector('video');if(!v)return '0';v.pause();return '1';})()"
        case .togglePlayPause:
            js = "(function(){var v=document.querySelector('video');if(!v)return '0';if(v.paused){v.play();}else{v.pause();}return '1';})()"
        case .nextTrack:
            js = "(function(){var b=document.querySelector('.ytp-next-button');if(b){b.click();return '1';}var v=document.querySelector('video');if(!v)return '0';v.currentTime=Math.min((Number.isFinite(v.duration)?v.duration:v.currentTime+10),v.currentTime+10);return '1';})()"
        case .previousTrack:
            js = "(function(){var b=document.querySelector('.ytp-prev-button');if(b&&!b.disabled&&b.getAttribute('aria-disabled')!=='true'){b.click();return '1';}var v=document.querySelector('video');if(!v)return '0';v.currentTime=Math.max(0,v.currentTime-10);return '1';})()"
        }
        if let result = runSafariJavaScript(js, inURL: nil) {
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("1") { return true }
            NSLog("ALWM NowPlaying: Safari JS control returned %@", trimmed)
        } else {
            NSLog("ALWM NowPlaying: Safari JS control failed — falling back to keystroke")
        }
        return sendSafariKeystroke(for: command)
    }

    private func sendSafariKeystroke(for command: Command) -> Bool {
        let key: String
        switch command {
        case .play, .pause, .togglePlayPause, .stop:
            key = "k"
        case .nextTrack:
            key = "l"
        case .previousTrack:
            key = "j"
        }
        let script = """
        tell application "Safari" to activate
        delay 0.05
        tell application "System Events"
          tell process "Safari"
            keystroke "\(key)"
          end tell
        end tell
        """
        return runAppleScript(script, timeout: 2.0) != nil
    }

    // MARK: - Sampling

    private func sampleNow() -> Snapshot {
        let spotifyRunning = isRunning(bundleID: "com.spotify.client")
        let musicRunning = isRunning(bundleID: "com.apple.Music")
        let safariRunning = isRunning(bundleID: "com.apple.Safari")

        let spotify = spotifyRunning ? sampleSpotify() : nil
        let music = musicRunning ? sampleMusic() : nil
        let safari = safariRunning ? sampleSafari() : nil

        let chosen: (Snapshot, Source)?
        if let spotify, spotify.isPlaying {
            chosen = (spotify, .spotify)
        } else if let music, music.isPlaying {
            chosen = (music, .music)
        } else if let safari, safari.isPlaying {
            chosen = (safari, .safari)
        } else if let spotify, spotify.present {
            chosen = (spotify, .spotify)
        } else if let music, music.present {
            chosen = (music, .music)
        } else if let safari, safari.present {
            chosen = (safari, .safari)
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
        // Spotify's `current track` does not implement `exists` (-1708). Probe with try.
        let script = """
        tell application "Spotify"
          try
            set playerState to player state as text
            set trackName to name of current track
            set trackArtist to artist of current track
            set trackAlbum to album of current track
            set trackDuration to duration of current track
            set trackPosition to player position
            set artURL to ""
            try
              set artURL to artwork url of current track
            end try
            set sep to character id 31
            return playerState & sep & trackName & sep & trackArtist & sep & trackAlbum & sep & trackDuration & sep & trackPosition & sep & artURL
          on error
            return "none"
          end try
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
        let durationMs = parseNumber(parts[4]) ?? 0
        let elapsed = parseNumber(parts[5]) ?? 0
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
          try
            set playerState to player state as text
            if playerState is "stopped" then return "none"
            set trackName to name of current track
            set trackArtist to artist of current track
            set trackAlbum to album of current track
            set trackDuration to duration of current track
            set trackPosition to player position
            set sep to character id 31
            return playerState & sep & trackName & sep & trackArtist & sep & trackAlbum & sep & trackDuration & sep & trackPosition
          on error
            return "none"
          end try
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
        let duration = parseNumber(parts[4]) ?? 0
        let elapsed = parseNumber(parts[5]) ?? 0
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

    /// Front Safari tab when it looks like a video site (YouTube, Vimeo, Twitch, …).
    /// Playback timeline uses `<video>` via Safari JavaScript when the user has enabled
    /// Develop → Allow JavaScript from Apple Events.
    private func sampleSafari() -> Snapshot? {
        // Prefer a media tab anywhere in Safari (not only the frontmost tab).
        let script = """
        tell application "Safari"
          try
            if (count of windows) is 0 then return "none"
            set sep to character id 31
            set mediaTab to missing value
            repeat with w in windows
              repeat with t in tabs of w
                try
                  set u to URL of t as text
                  if u contains "youtube.com/watch" or u contains "youtube.com/shorts" or u contains "youtu.be/" or u contains "youtube.com/embed" or u contains "youtube.com/live" or u contains "vimeo.com/" or u contains "twitch.tv/" then
                    set mediaTab to t
                    exit repeat
                  end if
                end try
              end repeat
              if mediaTab is not missing value then exit repeat
            end repeat
            if mediaTab is missing value then set mediaTab to current tab of front window
            return (name of mediaTab) & sep & (URL of mediaTab)
          on error
            return "none"
          end try
        end tell
        """
        guard let raw = runAppleScript(script, timeout: 2.5)?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw != "none", !raw.isEmpty
        else { return nil }

        let parts = raw.split(separator: "\u{001f}", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return nil }
        let pageTitle = clean(parts[0]) ?? ""
        let urlString = clean(parts[1]) ?? ""
        guard var media = browserMedia(title: pageTitle, urlString: urlString) else { return nil }

        lock.lock()
        lastSafariMediaURL = urlString
        lock.unlock()

        if let playback = sampleSafariVideoPlayback(urlString: urlString) {
            media.isPlaying = playback.isPlaying
            media.duration = playback.duration
            media.elapsed = playback.elapsed
        }

        var artwork: Data?
        if let artURL = media.artworkURL {
            artwork = artworkData(for: artURL)
        }

        return Snapshot(
            present: true,
            isPlaying: media.isPlaying,
            title: media.title,
            artist: media.artist,
            album: nil,
            artworkData: artwork,
            duration: media.duration,
            elapsed: media.elapsed,
            appName: "Safari"
        )
    }

    private struct SafariPlayback {
        var isPlaying: Bool
        var duration: Double?
        var elapsed: Double?
    }

    private func sampleSafariVideoPlayback(urlString: String) -> SafariPlayback? {
        let js = "(function(){var v=document.querySelector('video');if(!v)return 'novideo';return (v.paused?'paused':'playing')+'|'+(Number.isFinite(v.duration)?v.duration:0)+'|'+(Number.isFinite(v.currentTime)?v.currentTime:0);})()"
        guard let raw = runSafariJavaScript(js, inURL: urlString)?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw != "novideo", !raw.isEmpty
        else { return nil }
        let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3 else { return nil }
        let isPlaying = parts[0].lowercased() == "playing"
        let duration = Double(parts[1].replacingOccurrences(of: ",", with: ".")) ?? 0
        let elapsed = Double(parts[2].replacingOccurrences(of: ",", with: ".")) ?? 0
        return SafariPlayback(
            isPlaying: isPlaying,
            duration: duration > 0 ? duration : nil,
            elapsed: elapsed >= 0 ? elapsed : nil
        )
    }

    /// Runs JS in the Safari tab matching `inURL` (or last media URL / front tab).
    private func runSafariJavaScript(_ javaScript: String, inURL: String?) -> String? {
        lock.lock()
        let known = safariJavaScriptOK
        let checkedAt = safariJavaScriptCheckedAt
        let targetURL = inURL ?? lastSafariMediaURL
        lock.unlock()
        // Only briefly skip after a hard permission denial — user may enable Develop setting anytime.
        if known == false, Date().timeIntervalSince(checkedAt) < 8 {
            return nil
        }

        let escaped = javaScript
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let urlEscaped = (targetURL ?? "")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script: String
        if !urlEscaped.isEmpty {
            script = """
            tell application "Safari"
              try
                set targetURL to "\(urlEscaped)"
                set targetTab to missing value
                repeat with w in windows
                  repeat with t in tabs of w
                    try
                      if (URL of t as text) is targetURL then
                        set targetTab to t
                        exit repeat
                      end if
                    end try
                  end repeat
                  if targetTab is not missing value then exit repeat
                end repeat
                if targetTab is missing value then
                  repeat with w in windows
                    repeat with t in tabs of w
                      try
                        set u to URL of t as text
                        if u contains "youtube.com" or u contains "youtu.be" or u contains "vimeo.com" then
                          set targetTab to t
                          exit repeat
                        end if
                      end try
                    end repeat
                    if targetTab is not missing value then exit repeat
                  end repeat
                end if
                if targetTab is missing value then set targetTab to current tab of front window
                set r to do JavaScript "\(escaped)" in targetTab
                return r as text
              on error errMsg
                return "ERR:" & errMsg
              end try
            end tell
            """
        } else {
            script = """
            tell application "Safari"
              try
                set r to do JavaScript "\(escaped)" in current tab of front window
                return r as text
              on error errMsg
                return "ERR:" & errMsg
              end try
            end tell
            """
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alwm-safari-\(UUID().uuidString).applescript")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }

        guard let raw = runAppleScriptFile(url, timeout: 2.5)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }

        if raw.hasPrefix("ERR:") {
            let lower = raw.lowercased()
            if lower.contains("javascript from apple events") || lower.contains("allow javascript") {
                lock.lock()
                safariJavaScriptOK = false
                safariJavaScriptCheckedAt = Date()
                lock.unlock()
            }
            NSLog("ALWM NowPlaying: Safari JS error %@", raw)
            return nil
        }

        lock.lock()
        safariJavaScriptOK = true
        safariJavaScriptCheckedAt = Date()
        lock.unlock()
        return raw
    }

    @discardableResult
    private func runAppleScriptFile(_ url: URL, timeout: TimeInterval) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = [url.path]
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
        guard proc.terminationStatus == 0 else {
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            if let s = String(data: errData, encoding: .utf8), !s.isEmpty {
                NSLog("ALWM NowPlaying: osascript failed %@", s)
            }
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    private struct BrowserMedia {
        var title: String
        var artist: String
        var isPlaying: Bool
        var artworkURL: String?
        var duration: Double?
        var elapsed: Double?
    }

    private func browserMedia(title rawTitle: String, urlString: String) -> BrowserMedia? {
        guard let url = URL(string: urlString), let host = url.host?.lowercased() else { return nil }
        let path = url.path
        let pathLower = path.lowercased()
        let query = url.query ?? ""

        enum Kind {
            case youtube, vimeo, twitch, netflix, otherVideo
        }

        let kind: Kind?
        if host.contains("youtube.com") || host == "youtu.be" || host.contains("youtube-nocookie.com") {
            kind = .youtube
        } else if host.contains("vimeo.com") {
            kind = .vimeo
        } else if host.contains("twitch.tv") {
            kind = .twitch
        } else if host.contains("netflix.com") {
            kind = .netflix
        } else if host.contains("primevideo.com")
            || host.contains("disneyplus.com")
            || host.contains("play.max.com")
            || host.contains("hulu.com") {
            kind = .otherVideo
        } else {
            kind = nil
        }
        guard let kind else { return nil }

        let isContent: Bool
        switch kind {
        case .youtube:
            isContent = host == "youtu.be"
                || pathLower.contains("/watch")
                || pathLower.contains("/shorts/")
                || pathLower.contains("/live")
                || pathLower.contains("/embed/")
                || query.lowercased().contains("v=")
        case .vimeo:
            isContent = path.split(separator: "/").contains { Int($0) != nil }
        case .twitch:
            isContent = pathLower != "/" && !pathLower.isEmpty
        case .netflix, .otherVideo:
            isContent = pathLower.contains("/watch") || pathLower.contains("/title") || pathLower.contains("/video")
        }
        guard isContent else { return nil }

        var title = stripBrowserChrome(rawTitle)
        if title.isEmpty {
            title = host
        }
        let artist: String
        switch kind {
        case .youtube: artist = "YouTube"
        case .vimeo: artist = "Vimeo"
        case .twitch: artist = "Twitch"
        case .netflix: artist = "Netflix"
        case .otherVideo: artist = host.replacingOccurrences(of: "www.", with: "")
        }

        let artworkURL: String?
        if kind == .youtube, let videoID = youtubeVideoID(host: host, path: path, query: query) {
            // hqdefault is reliably available; maxresdefault often 404s.
            artworkURL = "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg"
        } else {
            artworkURL = nil
        }

        // Without video element access, treat a content URL on the front tab as playing.
        return BrowserMedia(
            title: title,
            artist: artist,
            isPlaying: true,
            artworkURL: artworkURL,
            duration: nil,
            elapsed: nil
        )
    }

    /// Extract YouTube video id from watch / shorts / embed / youtu.be URLs.
    private func youtubeVideoID(host: String, path: String, query: String) -> String? {
        func validID(_ raw: String) -> String? {
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Standard IDs are 11 chars; allow a bit of slack for edge formats.
            guard (6...20).contains(id.count),
                  id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0) })
            else { return nil }
            return id
        }

        if host == "youtu.be" {
            let id = path.split(separator: "/").first.map(String.init) ?? ""
            return validID(id)
        }

        let parts = path.split(separator: "/").map(String.init)
        if let shortsIdx = parts.firstIndex(of: "shorts"), parts.index(after: shortsIdx) < parts.endIndex {
            return validID(parts[parts.index(after: shortsIdx)])
        }
        if let embedIdx = parts.firstIndex(of: "embed"), parts.index(after: embedIdx) < parts.endIndex {
            return validID(parts[parts.index(after: embedIdx)])
        }
        if let liveIdx = parts.firstIndex(of: "live"), parts.index(after: liveIdx) < parts.endIndex {
            return validID(parts[parts.index(after: liveIdx)])
        }

        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2, kv[0] == "v" else { continue }
            let decoded = kv[1].removingPercentEncoding ?? kv[1]
            return validID(decoded)
        }
        return nil
    }

    private func stripBrowserChrome(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Safari unread / notification prefixes: "(60) Title"
        if t.hasPrefix("("), let close = t.firstIndex(of: ")") {
            let after = t.index(after: close)
            if after < t.endIndex {
                t = String(t[after...]).trimmingCharacters(in: .whitespaces)
            }
        }
        let suffixes = [
            " - YouTube",
            " — YouTube",
            " | YouTube",
            " - Vimeo",
            " - Twitch",
            " | Twitch",
            " - Netflix",
            " | Netflix"
        ]
        for suffix in suffixes where t.hasSuffix(suffix) {
            t = String(t.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        return t
    }

    // MARK: - Helpers

    private func isRunning(bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    private func clean(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private func parseNumber(_ s: String) -> Double? {
        Double(s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))
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
