import AppKit
import SwiftUI
import AlwmL10n
import AlwmPluginAPI

/// Borderless panels refuse key status by default — without this, TextFields never accept typing.
private final class CalendarKeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
enum CalendarPanelController {
    private static var window: CalendarKeyPanel?

    static func close() {
        PluginPanelOutsideClick.stop(for: window)
        window?.orderOut(nil)
    }

    static func toggle(relativeTo view: NSView?) {
        if let window, window.isVisible {
            PluginPanelOutsideClick.stop(for: window)
            window.orderOut(nil)
            return
        }
        open(relativeTo: view)
    }

    static func open(relativeTo view: NSView?) {
        let root = CalendarPanelView()
            .pluginLocalized()
        let hosting = NSHostingController(rootView: root)
        let width: CGFloat = 380
        let height: CGFloat = 580

        // Always recreate so an older non-key panel instance cannot stick around.
        if let old = window {
            PluginPanelOutsideClick.stop(for: old)
            old.orderOut(nil)
            window = nil
        }

        let win = CalendarKeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        win.contentViewController = hosting
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.hidesOnDeactivate = false
        win.becomesKeyOnlyIfNeeded = false
        win.isFloatingPanel = true
        win.isMovableByWindowBackground = true
        win.acceptsMouseMovedEvents = true

        if let view, let screen = view.window?.screen ?? NSScreen.main {
            let rect = view.window?.convertToScreen(view.convert(view.bounds, to: nil))
                ?? NSRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY, width: 1, height: 1)
            var origin = NSPoint(x: rect.midX - width / 2, y: rect.minY - height - 8)
            origin.x = min(max(origin.x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - width - 8)
            origin.y = min(max(origin.y, screen.visibleFrame.minY + 8), screen.visibleFrame.maxY - height - 8)
            win.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        } else if let screen = NSScreen.main {
            let mouse = NSEvent.mouseLocation
            var origin = NSPoint(x: mouse.x - width / 2, y: mouse.y - height - 12)
            origin.x = min(max(origin.x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - width - 8)
            origin.y = min(max(origin.y, screen.visibleFrame.minY + 8), screen.visibleFrame.maxY - height - 8)
            win.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        } else {
            win.center()
        }

        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        PluginPanelOutsideClick.watch(win)
    }
}

struct CalendarPanelView: View {
    @ObservedObject private var store = CalendarStore.shared

    private var loc: String { store.localeCode() }
    private func t(_ key: String) -> String { PluginL10n.t(key, locale: loc) }
    private func tf(_ key: String, _ args: CVarArg...) -> String {
        String(format: PluginL10n.t(key, locale: loc), locale: Locale(identifier: loc), arguments: args)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    weatherSection
                    locationSection
                    Divider()
                    if !store.isAuthorized {
                        authBlock
                    } else {
                        todaySection
                        upcomingSection
                        addSection
                        settingsSection
                    }
                }
            }
            if let err = store.lastError, !err.isEmpty {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(14)
        .frame(width: 380, height: 580, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: store.barSymbol)
                .foregroundStyle(Color(nsColor: store.barTint))
            Text(t("plugin.calendar.title"))
                .font(.headline)
            Spacer()
            Button {
                Task { await store.refreshWeather() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help(t("plugin.calendar.weather.refresh"))
            Button {
                store.openSystemCalendar()
            } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(.plain)
            .help(t("plugin.calendar.open_app"))
        }
    }

    private var weatherSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(t("plugin.calendar.weather.week"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if store.weatherLoading {
                    ProgressView()
                        .controlSize(.small)
                } else if let temp = store.weather?.currentTemp {
                    Text("\(Int(temp.rounded()))°")
                        .font(.title3.weight(.semibold).monospacedDigit())
                }
            }

            if let err = store.weatherError, !err.isEmpty {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let days = store.weather?.days, !days.isEmpty {
                HStack(spacing: 4) {
                    ForEach(days) { day in
                        VStack(spacing: 4) {
                            Text(weekdayShort(day.date))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                            Image(systemName: day.condition.symbolName)
                                .font(.body)
                                .foregroundStyle(Color(nsColor: tint(for: day.condition)))
                                .frame(height: 20)
                            Text("\(Int(day.tempMax.rounded()))°")
                                .font(.caption2.weight(.semibold).monospacedDigit())
                            Text("\(Int(day.tempMin.rounded()))°")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
            } else if !store.weatherLoading {
                Text(t("plugin.calendar.weather.empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var locationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(t("plugin.calendar.weather.location"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if store.settings.useAutomaticLocation {
                    Text(t("plugin.calendar.weather.location.auto_on"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                PluginPasteableTextField(
                    placeholder: t("plugin.calendar.weather.location.placeholder"),
                    text: $store.locationDraft,
                    onSubmit: {
                        Task { await store.applyLocationFromDraft() }
                    }
                )
                .frame(minHeight: 28)
                .onChange(of: store.locationDraft) { _, _ in
                    store.locationDraftEdited()
                }
                Button(t("plugin.calendar.weather.location.apply")) {
                    Task { await store.applyLocationFromDraft() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.locationDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.weatherLoading)
            }

            if store.locationSearching && store.locationSuggestions.isEmpty {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(t("plugin.calendar.weather.location.searching"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if !store.locationSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(store.locationSuggestions) { hit in
                        Button {
                            Task { await store.selectLocationSuggestion(hit) }
                        } label: {
                            HStack {
                                Image(systemName: "mappin.and.ellipse")
                                    .foregroundStyle(.secondary)
                                Text(hit.displayName)
                                    .font(.callout)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if hit.id != store.locationSuggestions.last?.id {
                            Divider()
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
            }

            HStack(spacing: 8) {
                Button {
                    Task { await store.useAutomaticLocation() }
                } label: {
                    Label(t("plugin.calendar.weather.location.detect"), systemImage: "location.fill")
                }
                .buttonStyle(.bordered)
                .disabled(store.weatherLoading)
                if let label = store.weather?.locationLabel, !label.isEmpty {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var authBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(authMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if store.authorizationStatus == .notDetermined {
                    Button(t("plugin.calendar.authorize")) {
                        Task { await store.requestAccessIfNeeded() }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button(t("plugin.calendar.open_privacy")) {
                        store.openPrivacySettings()
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button(t("plugin.calendar.refresh")) {
                    Task { await store.requestAccessIfNeeded() }
                }
            }
        }
    }

    private var authMessage: String {
        switch store.authorizationStatus {
        case .denied, .restricted:
            return t("plugin.calendar.auth.denied")
        default:
            return t("plugin.calendar.auth.needed")
        }
    }

    private var todaySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t("plugin.calendar.section.today"))
                .font(.subheadline.weight(.semibold))
            if store.todayEvents.isEmpty {
                Text(t("plugin.calendar.empty.today"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.todayEvents) { event in
                    eventRow(event)
                }
            }
        }
    }

    private var upcomingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t("plugin.calendar.section.upcoming"))
                .font(.subheadline.weight(.semibold))
            if store.upcomingEvents.isEmpty {
                Text(t("plugin.calendar.empty.upcoming"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.upcomingEvents) { event in
                    eventRow(event, showDate: true)
                }
            }
        }
    }

    private func eventRow(_ event: CalendarEventItem, showDate: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.orange)
                .frame(width: 3, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                Text(timeLabel(event, showDate: showDate))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if !event.calendarTitle.isEmpty {
                    Text(event.calendarTitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private func timeLabel(_ event: CalendarEventItem, showDate: Bool) -> String {
        if event.isAllDay {
            if showDate {
                return "\(dayString(event.start)) · \(t("plugin.calendar.all_day"))"
            }
            return t("plugin.calendar.all_day")
        }
        let range = "\(timeString(event.start)) – \(timeString(event.end))"
        if showDate {
            return "\(dayString(event.start)) · \(range)"
        }
        return range
    }

    private var addSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t("plugin.calendar.section.add"))
                .font(.subheadline.weight(.semibold))
            PluginPasteableTextField(
                placeholder: t("plugin.calendar.add.title"),
                text: $store.draftTitle
            )
            .frame(minHeight: 28)
            Toggle(t("plugin.calendar.add.all_day"), isOn: $store.draftAllDay)
            DatePicker(
                t("plugin.calendar.add.start"),
                selection: $store.draftStart,
                displayedComponents: store.draftAllDay ? [.date] : [.date, .hourAndMinute]
            )
            if !store.draftAllDay {
                Stepper(
                    tf("plugin.calendar.add.duration", store.draftDurationMinutes),
                    value: $store.draftDurationMinutes,
                    in: 15...480,
                    step: 15
                )
            }
            Button {
                _ = store.addDraftEvent()
            } label: {
                Label(t("plugin.calendar.add.submit"), systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text(t("plugin.calendar.settings"))
                .font(.subheadline.weight(.semibold))
            Toggle(t("plugin.calendar.notify.toggle"), isOn: Binding(
                get: { store.settings.notifyEnabled },
                set: { v in store.updateSettings { $0.notifyEnabled = v } }
            ))
            Stepper(
                tf("plugin.calendar.notify.minutes", store.settings.notifyMinutesBefore),
                value: Binding(
                    get: { store.settings.notifyMinutesBefore },
                    set: { v in store.updateSettings { $0.notifyMinutesBefore = v } }
                ),
                in: 0...120,
                step: 5
            )
            .disabled(!store.settings.notifyEnabled)
        }
    }

    private func weekdayShort(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: loc)
        f.dateFormat = "EEE"
        return f.string(from: date)
    }

    private func tint(for condition: WeatherCondition) -> NSColor {
        switch condition {
        case .rain, .drizzle, .thunderstorm: return .systemBlue
        case .snow: return .systemTeal
        case .clear: return .systemOrange
        case .fog: return .secondaryLabelColor
        default: return .labelColor
        }
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: loc)
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: date)
    }

    private func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: loc)
        f.dateFormat = "EEE d MMM"
        return f.string(from: date)
    }
}
