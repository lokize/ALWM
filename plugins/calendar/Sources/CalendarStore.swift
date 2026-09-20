import AppKit
import Combine
import EventKit
import Foundation
import UserNotifications
import AlwmL10n

struct CalendarEventItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let calendarTitle: String
}

struct CalendarSettings: Codable, Equatable, Sendable {
    var notifyEnabled: Bool = true
    /// Minutes before start to fire a local notification.
    var notifyMinutesBefore: Int = 10
    /// User-facing place name (city / region).
    var locationQuery: String = ""
    var locationLabel: String = ""
    var latitude: Double?
    var longitude: Double?
    /// When true, weather uses Core Location (GPS / Approximate).
    var useAutomaticLocation: Bool = true

    enum CodingKeys: String, CodingKey {
        case notifyEnabled, notifyMinutesBefore
        case locationQuery, locationLabel, latitude, longitude
        case useAutomaticLocation
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notifyEnabled = try c.decodeIfPresent(Bool.self, forKey: .notifyEnabled) ?? true
        notifyMinutesBefore = try c.decodeIfPresent(Int.self, forKey: .notifyMinutesBefore) ?? 10
        locationQuery = try c.decodeIfPresent(String.self, forKey: .locationQuery) ?? ""
        locationLabel = try c.decodeIfPresent(String.self, forKey: .locationLabel) ?? ""
        latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
        // Default to automatic for upgrades that never had this key.
        useAutomaticLocation = try c.decodeIfPresent(Bool.self, forKey: .useAutomaticLocation) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(notifyEnabled, forKey: .notifyEnabled)
        try c.encode(notifyMinutesBefore, forKey: .notifyMinutesBefore)
        try c.encode(locationQuery, forKey: .locationQuery)
        try c.encode(locationLabel, forKey: .locationLabel)
        try c.encodeIfPresent(latitude, forKey: .latitude)
        try c.encodeIfPresent(longitude, forKey: .longitude)
        try c.encode(useAutomaticLocation, forKey: .useAutomaticLocation)
    }
}

final class CalendarStore: ObservableObject, @unchecked Sendable {
    static let shared = CalendarStore()

    @Published private(set) var authorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published private(set) var todayEvents: [CalendarEventItem] = []
    @Published private(set) var upcomingEvents: [CalendarEventItem] = []
    @Published private(set) var settings = CalendarSettings()
    @Published private(set) var weather: WeatherSnapshot?
    @Published private(set) var weatherLoading = false
    @Published var weatherError: String?
    @Published var lastError: String?
    @Published var draftTitle: String = ""
    @Published var draftStart: Date = Date().addingTimeInterval(3600)
    @Published var draftDurationMinutes: Int = 60
    @Published var draftAllDay: Bool = false
    @Published var locationDraft: String = ""
    @Published private(set) var locationSuggestions: [WeatherService.GeoResult] = []
    @Published private(set) var locationSearching = false

    var localeCode: () -> String = { PluginL10n.currentCode }
    var onChange: (() -> Void)?

    private let eventStore = EKEventStore()
    private var refreshTimer: Timer?
    private var notifyTimer: Timer?
    private var weatherTimer: Timer?
    private var changeObserver: NSObjectProtocol?
    private var notifiedIDs = Set<String>()
    private let lock = NSLock()
    private var locationSuggestTask: Task<Void, Never>?
    private var suppressLocationSuggest = false

    private init() {
        loadSettings()
        authorizationStatus = Self.currentStatus()
        locationDraft = settings.locationQuery.isEmpty ? settings.locationLabel : settings.locationQuery
    }

    var todayEventCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return todayEvents.count
    }

    var barSymbol: String {
        if let weather {
            return weather.currentCondition.symbolName
        }
        return "calendar"
    }

    var barLabel: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: localeCode())
        f.dateFormat = "d"
        let day = f.string(from: Date())
        if let temp = weather?.currentTemp {
            return "\(day) \(Int(temp.rounded()))°"
        }
        return day
    }

    var barUnit: String? {
        guard isAuthorized else { return nil }
        let n = todayEventCount
        return n > 0 ? "\(n)" : nil
    }

    var barTint: NSColor {
        if let code = weather?.currentCode ?? weather?.days.first?.weatherCode {
            switch WeatherCondition.from(wmoCode: code) {
            case .rain, .drizzle, .thunderstorm: return .systemBlue
            case .snow: return .systemTeal
            case .clear: return .systemOrange
            default: break
            }
        }
        let status = authorizationStatus
        if status == .denied || status == .restricted {
            return .secondaryLabelColor
        }
        return todayEventCount > 0 ? .systemOrange : .labelColor
    }

    var tooltip: String {
        let loc = localeCode()
        var parts: [String] = []
        if let weather {
            let temp = weather.currentTemp.map { "\(Int($0.rounded()))°" } ?? "—"
            parts.append("\(weather.locationLabel) \(temp)")
        }
        switch authorizationStatus {
        case .notDetermined:
            parts.append(PluginL10n.t("plugin.calendar.tooltip.authorize", locale: loc))
        case .denied, .restricted:
            parts.append(PluginL10n.t("plugin.calendar.tooltip.denied", locale: loc))
        default:
            let n = todayEventCount
            if n == 0 {
                parts.append(PluginL10n.t("plugin.calendar.tooltip.empty", locale: loc))
            } else {
                parts.append(PluginL10n.tf("plugin.calendar.tooltip.events", locale: loc, n))
            }
        }
        return parts.joined(separator: " · ")
    }

    var isAuthorized: Bool {
        let s = authorizationStatus
        return s == .fullAccess || s == .writeOnly
    }

    func start() {
        authorizationStatus = Self.currentStatus()
        CalendarNotifier.requestAuthorization()
        if changeObserver == nil {
            changeObserver = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged,
                object: eventStore,
                queue: .main
            ) { [weak self] _ in
                self?.refreshEvents()
            }
        }
        if refreshTimer == nil {
            let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
                self?.refreshEvents()
            }
            RunLoop.main.add(t, forMode: .common)
            refreshTimer = t
        }
        if notifyTimer == nil {
            let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
                self?.checkNotifications()
            }
            RunLoop.main.add(t, forMode: .common)
            notifyTimer = t
        }
        if weatherTimer == nil {
            let t = Timer(timeInterval: 30 * 60, repeats: true) { [weak self] _ in
                Task { await self?.refreshWeather() }
            }
            RunLoop.main.add(t, forMode: .common)
            weatherTimer = t
        }
        Task {
            await ensureLocationAndWeather()
            await requestAccessIfNeeded()
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        notifyTimer?.invalidate()
        notifyTimer = nil
        weatherTimer?.invalidate()
        weatherTimer = nil
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
            self.changeObserver = nil
        }
    }

    func applyLocationFromDraft() async {
        let query = locationDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            weatherError = PluginL10n.t("plugin.calendar.weather.error.empty", locale: localeCode())
            return
        }
        weatherLoading = true
        weatherError = nil
        locationSuggestions = []
        objectWillChange.send()
        do {
            let geo = try await WeatherService.geocode(query: query)
            await applyGeoResult(geo, query: query)
        } catch WeatherService.WeatherError.notFound {
            weatherError = PluginL10n.t("plugin.calendar.weather.error.not_found", locale: localeCode())
            weatherLoading = false
            objectWillChange.send()
            onChange?()
        } catch {
            weatherError = PluginL10n.t("plugin.calendar.weather.error.network", locale: localeCode())
            weatherLoading = false
            objectWillChange.send()
            onChange?()
        }
    }

    func selectLocationSuggestion(_ geo: WeatherService.GeoResult) async {
        locationSuggestTask?.cancel()
        locationSuggestions = []
        weatherLoading = true
        weatherError = nil
        objectWillChange.send()
        await applyGeoResult(geo, query: geo.displayName)
    }

    /// Debounced Open-Meteo search while the user types a city.
    func locationDraftEdited() {
        if suppressLocationSuggest {
            suppressLocationSuggest = false
            return
        }
        locationSuggestTask?.cancel()
        let query = locationDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else {
            locationSuggestions = []
            locationSearching = false
            objectWillChange.send()
            return
        }
        locationSearching = true
        objectWillChange.send()
        locationSuggestTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 320_000_000)
            guard !Task.isCancelled, let self else { return }
            do {
                let hits = try await WeatherService.search(query: query, count: 6)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.locationSuggestions = hits
                    self.locationSearching = false
                    self.objectWillChange.send()
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.locationSuggestions = []
                    self.locationSearching = false
                    self.objectWillChange.send()
                }
            }
        }
    }

    private func applyGeoResult(_ geo: WeatherService.GeoResult, query: String) async {
        updateSettings {
            $0.useAutomaticLocation = false
            $0.locationQuery = query
            $0.locationLabel = geo.displayName
            $0.latitude = geo.latitude
            $0.longitude = geo.longitude
        }
        suppressLocationSuggest = true
        locationDraft = geo.displayName
        locationSuggestions = []
        do {
            try await fetchWeatherLocked(
                latitude: geo.latitude,
                longitude: geo.longitude,
                label: geo.displayName
            )
        } catch {
            weatherError = PluginL10n.t("plugin.calendar.weather.error.network", locale: localeCode())
            weatherLoading = false
            objectWillChange.send()
            onChange?()
        }
    }

    func useAutomaticLocation() async {
        updateSettings { $0.useAutomaticLocation = true }
        await ensureLocationAndWeather(forceRefresh: true)
    }

    func refreshWeather() async {
        await ensureLocationAndWeather(forceRefresh: true)
    }

    private func ensureLocationAndWeather(forceRefresh: Bool = false) async {
        if settings.useAutomaticLocation {
            let resolved = await resolveAutomaticLocation()
            if !resolved {
                // Fall back to saved coords or timezone seed.
                if settings.latitude == nil || settings.longitude == nil {
                    await resolveTimezoneFallback()
                }
            }
        } else if settings.latitude == nil || settings.longitude == nil || settings.locationLabel.isEmpty {
            await resolveTimezoneFallback()
        }

        guard let lat = settings.latitude, let lon = settings.longitude else { return }
        if !forceRefresh, weather != nil { return }
        weatherLoading = true
        weatherError = nil
        objectWillChange.send()
        do {
            try await fetchWeatherLocked(
                latitude: lat,
                longitude: lon,
                label: settings.locationLabel.isEmpty ? locationDraft : settings.locationLabel
            )
        } catch {
            weatherError = PluginL10n.t("plugin.calendar.weather.error.network", locale: localeCode())
            weatherLoading = false
            objectWillChange.send()
            onChange?()
        }
    }

    /// Returns true if Core Location succeeded.
    @discardableResult
    private func resolveAutomaticLocation() async -> Bool {
        weatherLoading = true
        weatherError = nil
        objectWillChange.send()
        do {
            let loc = try await DeviceLocation.shared.requestCurrentLocation()
            let label = await WeatherService.reverseGeocodeLabel(
                latitude: loc.coordinate.latitude,
                longitude: loc.coordinate.longitude
            ) ?? PluginL10n.t("plugin.calendar.weather.location.current", locale: localeCode())
            updateSettings {
                $0.useAutomaticLocation = true
                $0.locationQuery = label
                $0.locationLabel = label
                $0.latitude = loc.coordinate.latitude
                $0.longitude = loc.coordinate.longitude
            }
            suppressLocationSuggest = true
            locationDraft = label
            locationSuggestions = []
            weatherLoading = false
            objectWillChange.send()
            return true
        } catch DeviceLocation.LocationError.denied {
            weatherError = PluginL10n.t("plugin.calendar.weather.error.location_denied", locale: localeCode())
            weatherLoading = false
            objectWillChange.send()
            return false
        } catch {
            weatherError = PluginL10n.t("plugin.calendar.weather.error.location_failed", locale: localeCode())
            weatherLoading = false
            objectWillChange.send()
            return false
        }
    }

    private func resolveTimezoneFallback() async {
        let seed = defaultLocationSeed()
        locationDraft = seed
        do {
            let geo = try await WeatherService.geocode(query: seed)
            updateSettings {
                $0.locationQuery = seed
                $0.locationLabel = geo.displayName
                $0.latitude = geo.latitude
                $0.longitude = geo.longitude
            }
            locationDraft = geo.displayName
        } catch {
            weatherError = PluginL10n.t("plugin.calendar.weather.error.network", locale: localeCode())
            objectWillChange.send()
        }
    }

    private func fetchWeatherLocked(latitude: Double, longitude: Double, label: String) async throws {
        let snap = try await WeatherService.forecast(
            latitude: latitude,
            longitude: longitude,
            locationLabel: label
        )
        weather = snap
        weatherLoading = false
        weatherError = nil
        objectWillChange.send()
        onChange?()
    }

    private func defaultLocationSeed() -> String {
        if !settings.locationQuery.isEmpty { return settings.locationQuery }
        let tz = TimeZone.current.identifier
        if let city = tz.split(separator: "/").last {
            return city.replacingOccurrences(of: "_", with: " ")
        }
        return "São Paulo"
    }

    func requestAccessIfNeeded() async {
        await MainActor.run {
            authorizationStatus = Self.currentStatus()
        }
        if isAuthorized {
            await MainActor.run { refreshEvents() }
            return
        }
        if authorizationStatus == .denied || authorizationStatus == .restricted {
            await MainActor.run { onChange?() }
            return
        }
        do {
            let granted: Bool
            if #available(macOS 14.0, *) {
                granted = try await eventStore.requestFullAccessToEvents()
            } else {
                granted = try await eventStore.requestAccess(to: .event)
            }
            await MainActor.run {
                authorizationStatus = Self.currentStatus()
                if granted {
                    refreshEvents()
                } else {
                    onChange?()
                }
            }
        } catch {
            await MainActor.run {
                lastError = error.localizedDescription
                authorizationStatus = Self.currentStatus()
                onChange?()
            }
        }
    }

    func refreshEvents() {
        authorizationStatus = Self.currentStatus()
        guard isAuthorized else {
            todayEvents = []
            upcomingEvents = []
            objectWillChange.send()
            onChange?()
            return
        }

        let cal = Calendar.current
        let now = Date()
        let startOfDay = cal.startOfDay(for: now)
        guard let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay),
              let upcomingEnd = cal.date(byAdding: .day, value: 7, to: startOfDay)
        else { return }

        let todayPred = eventStore.predicateForEvents(
            withStart: startOfDay,
            end: endOfDay,
            calendars: nil
        )
        let upcomingPred = eventStore.predicateForEvents(
            withStart: now,
            end: upcomingEnd,
            calendars: nil
        )

        let today = eventStore.events(matching: todayPred)
            .map(Self.mapEvent)
            .sorted { $0.start < $1.start }

        let upcoming = eventStore.events(matching: upcomingPred)
            .map(Self.mapEvent)
            .filter { !$0.isAllDay || $0.start >= startOfDay }
            .sorted { $0.start < $1.start }
            .prefix(12)
            .map { $0 }

        todayEvents = today
        upcomingEvents = upcoming
        objectWillChange.send()
        onChange?()
    }

    func updateSettings(_ mutate: (inout CalendarSettings) -> Void) {
        mutate(&settings)
        saveSettings()
        objectWillChange.send()
        onChange?()
    }

    @discardableResult
    func addDraftEvent() -> Bool {
        let start = draftStart
        let end: Date
        if draftAllDay {
            end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: start))
                ?? start.addingTimeInterval(86400)
        } else {
            end = start.addingTimeInterval(TimeInterval(max(15, draftDurationMinutes) * 60))
        }
        let ok = addEvent(title: draftTitle, start: start, end: end, isAllDay: draftAllDay)
        if ok {
            draftTitle = ""
            draftStart = Date().addingTimeInterval(3600)
            draftDurationMinutes = 60
            draftAllDay = false
        }
        return ok
    }

    @discardableResult
    func addEvent(title: String, start: Date, end: Date, isAllDay: Bool) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard isAuthorized else { return false }
        guard let calendar = eventStore.defaultCalendarForNewEvents else {
            lastError = PluginL10n.t("plugin.calendar.error.no_calendar", locale: localeCode())
            return false
        }

        let event = EKEvent(eventStore: eventStore)
        event.title = trimmed
        event.startDate = isAllDay ? Calendar.current.startOfDay(for: start) : start
        event.endDate = end
        event.isAllDay = isAllDay
        event.calendar = calendar
        do {
            try eventStore.save(event, span: .thisEvent, commit: true)
            lastError = nil
            refreshEvents()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func openSystemCalendar() {
        if let url = URL(string: "ical://") {
            NSWorkspace.shared.open(url)
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    private func checkNotifications() {
        guard settings.notifyEnabled else { return }
        guard isAuthorized else { return }
        let lead = TimeInterval(max(0, settings.notifyMinutesBefore) * 60)
        let now = Date()
        let windowEnd = now.addingTimeInterval(35)
        for event in upcomingEvents where !event.isAllDay {
            let fireAt = event.start.addingTimeInterval(-lead)
            guard fireAt <= windowEnd, fireAt >= now.addingTimeInterval(-30) else { continue }
            let key = "\(event.id)-\(Int(event.start.timeIntervalSince1970))"
            guard !notifiedIDs.contains(key) else { continue }
            notifiedIDs.insert(key)
            CalendarNotifier.notify(
                title: event.title,
                start: event.start,
                minutesBefore: settings.notifyMinutesBefore,
                locale: localeCode()
            )
        }
        if notifiedIDs.count > 200 {
            notifiedIDs = Set(notifiedIDs.suffix(100))
        }
    }

    private static func mapEvent(_ event: EKEvent) -> CalendarEventItem {
        CalendarEventItem(
            id: event.eventIdentifier ?? UUID().uuidString,
            title: event.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? "(No title)",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            calendarTitle: event.calendar?.title ?? ""
        )
    }

    private static func currentStatus() -> EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    private var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/alwm/plugins", isDirectory: true)
            .appendingPathComponent("dev.alwm.calendar.json")
    }

    private func loadSettings() {
        let url = settingsURL
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(CalendarSettings.self, from: data)
        else { return }
        settings = decoded
    }

    private func saveSettings() {
        let url = settingsURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

enum CalendarNotifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notify(title: String, start: Date, minutesBefore: Int, locale: String) {
        let content = UNMutableNotificationContent()
        content.title = PluginL10n.t("plugin.calendar.notify.title", locale: locale)
        let time = Self.timeString(start, locale: locale)
        if minutesBefore <= 0 {
            content.body = PluginL10n.tf("plugin.calendar.notify.now", locale: locale, title, time)
        } else {
            content.body = PluginL10n.tf(
                "plugin.calendar.notify.body",
                locale: locale,
                title,
                minutesBefore,
                time
            )
        }
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "calendar-\(title.hashValue)-\(Int(start.timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    private static func timeString(_ date: Date, locale: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: locale)
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: date)
    }
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
