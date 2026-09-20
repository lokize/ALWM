import AppKit
import Combine
import Foundation
import IOKit.pwr_mgt
import UserNotifications
import AlwmL10n

enum PomodoroPhase: String, Codable, CaseIterable, Sendable {
    case focus
    case shortBreak
    case longBreak

    var symbolName: String {
        switch self {
        case .focus: return "timer"
        case .shortBreak: return "cup.and.saucer"
        case .longBreak: return "sofa"
        }
    }
}

struct PomodoroSettings: Codable, Equatable, Sendable {
    var focusMinutes: Int = 25
    var shortBreakMinutes: Int = 5
    var longBreakMinutes: Int = 15
    var cyclesBeforeLongBreak: Int = 4
    var keepAwakeDuringFocus: Bool = true
    var notifyOnPhaseEnd: Bool = true
    var autoStartNext: Bool = false
}

final class PomodoroStore: ObservableObject, @unchecked Sendable {
    static let shared = PomodoroStore()

    @Published private(set) var settings = PomodoroSettings()
    @Published private(set) var phase: PomodoroPhase = .focus
    @Published private(set) var remainingSeconds: Int = 25 * 60
    @Published private(set) var isRunning = false
    @Published private(set) var completedFocusToday = 0
    @Published private(set) var focusStreak = 0
    @Published private(set) var isKeepingAwake = false

    var localeCode: () -> String = { PluginL10n.currentCode }
    var onChange: (() -> Void)?

    private var tickTimer: Timer?
    private var systemAssertionID: IOPMAssertionID = 0
    private var displayAssertionID: IOPMAssertionID = 0
    private var dayStamp: String = ""
    private let lock = NSLock()

    private init() {
        loadSettings()
        remainingSeconds = settings.focusMinutes * 60
        rollDayIfNeeded()
    }

    var barLabel: String {
        lock.lock()
        let remaining = remainingSeconds
        lock.unlock()
        let m = remaining / 60
        let s = remaining % 60
        return String(format: "%d:%02d", m, s)
    }

    var barSymbol: String {
        lock.lock()
        let awake = isKeepingAwake
        let current = phase
        lock.unlock()
        if awake { return "cup.and.saucer.fill" }
        return current.symbolName
    }

    var barTint: NSColor {
        lock.lock()
        let current = phase
        let running = isRunning
        lock.unlock()
        switch current {
        case .focus: return running ? .systemRed : .labelColor
        case .shortBreak: return .systemGreen
        case .longBreak: return .systemTeal
        }
    }

    var tooltip: String {
        let loc = localeCode()
        lock.lock()
        let current = phase
        let label = {
            let m = remainingSeconds / 60
            let s = remainingSeconds % 60
            return String(format: "%d:%02d", m, s)
        }()
        let awake = isKeepingAwake
        lock.unlock()
        let phaseName = PluginL10n.t("plugin.pomodoro.phase.\(current.rawValue)", locale: loc)
        var parts = ["\(phaseName) · \(label)"]
        if awake {
            parts.append(PluginL10n.t("plugin.pomodoro.awake.on", locale: loc))
        }
        parts.append(PluginL10n.t("plugin.common.click_to_open", locale: loc))
        return parts.joined(separator: " — ")
    }

    var phaseTitle: String {
        lock.lock()
        let current = phase
        lock.unlock()
        return PluginL10n.t("plugin.pomodoro.phase.\(current.rawValue)", locale: localeCode())
    }

    func start() {
        PomodoroNotifier.requestAuthorization()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.rollDayIfNeeded()
            if self.tickTimer == nil {
                let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                    self?.tick()
                }
                RunLoop.main.add(t, forMode: .common)
                self.tickTimer = t
            }
            self.syncKeepAwake()
            self.onChange?()
        }
    }

    func stop() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.tickTimer?.invalidate()
            self.tickTimer = nil
            self.releaseKeepAwake()
        }
    }

    func toggleRunning() {
        if isRunning { pause() } else { resume() }
    }

    func resume() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.rollDayIfNeeded()
            self.isRunning = true
            self.syncKeepAwake()
            self.publish()
        }
    }

    func pause() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.syncKeepAwake()
            self.publish()
        }
    }

    func skip() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.advancePhase()
            if !self.settings.autoStartNext {
                self.isRunning = false
            }
            self.syncKeepAwake()
            self.publish()
        }
    }

    func resetPhase() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.remainingSeconds = self.duration(for: self.phase)
            self.syncKeepAwake()
            self.publish()
        }
    }

    func resetAll() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.phase = .focus
            self.focusStreak = 0
            self.remainingSeconds = self.duration(for: .focus)
            self.syncKeepAwake()
            self.publish()
        }
    }

    func updateSettings(_ mutate: (inout PomodoroSettings) -> Void) {
        mutate(&settings)
        settings.focusMinutes = clampMinutes(settings.focusMinutes, min: 1, max: 120)
        settings.shortBreakMinutes = clampMinutes(settings.shortBreakMinutes, min: 1, max: 60)
        settings.longBreakMinutes = clampMinutes(settings.longBreakMinutes, min: 1, max: 60)
        settings.cyclesBeforeLongBreak = min(12, max(1, settings.cyclesBeforeLongBreak))
        saveSettings()
        if !isRunning {
            remainingSeconds = duration(for: phase)
        }
        syncKeepAwake()
        publish()
    }

    private func tick() {
        rollDayIfNeeded()
        guard isRunning else { return }
        if remainingSeconds > 0 {
            remainingSeconds -= 1
            onChange?()
            objectWillChange.send()
            return
        }
        finishPhase()
    }

    private func finishPhase() {
        let finished = phase
        if finished == .focus {
            completedFocusToday += 1
            focusStreak += 1
            saveStats()
        }
        if settings.notifyOnPhaseEnd {
            PomodoroNotifier.notifyPhaseEnd(phase: finished, locale: localeCode())
        }
        advancePhase()
        isRunning = settings.autoStartNext
        syncKeepAwake()
        publish()
    }

    private func advancePhase() {
        switch phase {
        case .focus:
            if focusStreak > 0, focusStreak % max(1, settings.cyclesBeforeLongBreak) == 0 {
                phase = .longBreak
            } else {
                phase = .shortBreak
            }
        case .shortBreak, .longBreak:
            phase = .focus
        }
        remainingSeconds = duration(for: phase)
    }

    private func duration(for phase: PomodoroPhase) -> Int {
        switch phase {
        case .focus: return settings.focusMinutes * 60
        case .shortBreak: return settings.shortBreakMinutes * 60
        case .longBreak: return settings.longBreakMinutes * 60
        }
    }

    private func clampMinutes(_ value: Int, min: Int, max: Int) -> Int {
        Swift.min(max, Swift.max(min, value))
    }

    private func publish() {
        objectWillChange.send()
        onChange?()
    }

    private func syncKeepAwake() {
        let want = settings.keepAwakeDuringFocus && isRunning && phase == .focus
        if want {
            ensureKeepAwake()
        } else {
            releaseKeepAwake()
        }
    }

    private func ensureKeepAwake() {
        if systemAssertionID == 0 {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "ALWM Pomodoro Focus" as CFString,
                &id
            )
            if result == kIOReturnSuccess {
                systemAssertionID = id
            }
        }
        if displayAssertionID == 0 {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "ALWM Pomodoro Focus Display" as CFString,
                &id
            )
            if result == kIOReturnSuccess {
                displayAssertionID = id
            }
        }
        isKeepingAwake = systemAssertionID != 0 || displayAssertionID != 0
    }

    private func releaseKeepAwake() {
        if systemAssertionID != 0 {
            IOPMAssertionRelease(systemAssertionID)
            systemAssertionID = 0
        }
        if displayAssertionID != 0 {
            IOPMAssertionRelease(displayAssertionID)
            displayAssertionID = 0
        }
        isKeepingAwake = false
    }

    private var settingsURL: URL {
        pluginDir.appendingPathComponent("dev.alwm.pomodoro.json")
    }

    private var statsURL: URL {
        pluginDir.appendingPathComponent("dev.alwm.pomodoro.stats.json")
    }

    private var pluginDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/alwm/plugins", isDirectory: true)
    }

    private func loadSettings() {
        if let data = try? Data(contentsOf: settingsURL),
           let decoded = try? JSONDecoder().decode(PomodoroSettings.self, from: data) {
            settings = decoded
        }
        loadStats()
    }

    private func saveSettings() {
        try? FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(settings) {
            try? data.write(to: settingsURL, options: .atomic)
        }
    }

    private struct DayStats: Codable {
        var day: String
        var completedFocus: Int
    }

    private func loadStats() {
        guard let data = try? Data(contentsOf: statsURL),
              let decoded = try? JSONDecoder().decode(DayStats.self, from: data)
        else { return }
        dayStamp = decoded.day
        if decoded.day == Self.todayStamp() {
            completedFocusToday = decoded.completedFocus
        } else {
            completedFocusToday = 0
            dayStamp = Self.todayStamp()
        }
    }

    private func saveStats() {
        try? FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        let payload = DayStats(day: Self.todayStamp(), completedFocus: completedFocusToday)
        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: statsURL, options: .atomic)
        }
    }

    private func rollDayIfNeeded() {
        let today = Self.todayStamp()
        guard dayStamp != today else { return }
        dayStamp = today
        completedFocusToday = 0
        saveStats()
    }

    private static func todayStamp() -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}

enum PomodoroNotifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notifyPhaseEnd(phase: PomodoroPhase, locale: String) {
        let content = UNMutableNotificationContent()
        content.title = PluginL10n.t("plugin.pomodoro.notify.title", locale: locale)
        content.body = PluginL10n.t("plugin.pomodoro.notify.\(phase.rawValue)", locale: locale)
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "pomodoro-\(phase.rawValue)-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}
