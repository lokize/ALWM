import AppKit
import SwiftUI
import AlwmL10n
import AlwmPluginAPI

private final class ClipboardKeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
enum ClipboardPanelController {
    private static var window: ClipboardKeyPanel?
    private static var keyMonitor: Any?

    static func close() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        PluginPanelOutsideClick.stop(for: window)
        window?.orderOut(nil)
    }

    static func toggle(anchoredTo geometry: PluginPanelAnchor.Geometry?) {
        if let window, window.isVisible {
            close()
            return
        }
        open(anchoredTo: geometry)
    }

    static var isVisible: Bool {
        window?.isVisible == true
    }

    static func open(anchoredTo geometry: PluginPanelAnchor.Geometry?) {
        let root = ClipboardPanelView()
            .pluginLocalized()
        let hosting = NSHostingController(rootView: root)
        let width: CGFloat = 400
        let height: CGFloat = 520
        let geo = geometry ?? PluginPanelAnchor.remembered(forPlugin: "dev.alwm.clipboard")

        if let old = window {
            PluginPanelOutsideClick.stop(for: old)
            old.orderOut(nil)
            window = nil
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }

        let win = ClipboardKeyPanel(
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
        win.isMovableByWindowBackground = false
        window = win
        ClipboardStore.shared.ensureSelection()
        PluginPanelAnchor.attachBeforePresenting(win, size: NSSize(width: width, height: height), to: geo)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        PluginPanelAnchor.attachAfterPresenting(win, size: NSSize(width: width, height: height), to: geo)
        PluginPanelOutsideClick.watch(win)
        installKeyMonitor()
    }

    private static func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let window, window.isVisible, event.window === window else { return event }
            let store = ClipboardStore.shared
            // Let text field handle typing when it has focus.
            if window.firstResponder is NSTextView || window.firstResponder is NSTextField {
                if event.keyCode == 53 { // Esc
                    close()
                    return nil
                }
                if event.keyCode == 125 { // down
                    store.selectNext()
                    return nil
                }
                if event.keyCode == 126 { // up
                    store.selectPrevious()
                    return nil
                }
                return event
            }
            switch event.keyCode {
            case 53: // Esc
                close()
                return nil
            case 125: // down
                store.selectNext()
                return nil
            case 126: // up
                store.selectPrevious()
                return nil
            case 36, 76: // Return / Enter
                store.pasteSelected()
                return nil
            default:
                return event
            }
        }
    }
}

struct ClipboardPanelView: View {
    @ObservedObject private var store = ClipboardStore.shared

    private var loc: String { store.localeCode() }
    private func t(_ key: String) -> String { PluginL10n.t(key, locale: loc) }
    private func tf(_ key: String, _ args: CVarArg...) -> String {
        String(format: PluginL10n.t(key, locale: loc), locale: Locale(identifier: loc), arguments: args)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            searchRow
            filterRow
            list
            footer
        }
        .padding(14)
        .frame(width: 400, height: 520, alignment: .topLeading)
        .pluginPanelChrome(cornerRadius: 14)
        .onAppear { store.ensureSelection() }
        .onChange(of: store.searchQuery) { _, _ in store.ensureSelection() }
        .onChange(of: store.filter) { _, _ in store.ensureSelection() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "clipboard")
                .foregroundStyle(Color(nsColor: store.barTint))
            Text(t("plugin.clipboard.title"))
                .font(.headline)
            Spacer()
            Text(store.countLabel())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var searchRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            PluginPasteableTextField(
                placeholder: t("plugin.clipboard.search"),
                text: $store.searchQuery
            )
            .frame(minHeight: 22)
            if !store.searchQuery.isEmpty {
                Button {
                    store.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ClipboardFilter.allCases, id: \.self) { f in
                    Button {
                        store.filter = f
                    } label: {
                        Text(filterLabel(f))
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule().fill(
                                    store.filter == f
                                        ? Color.teal.opacity(0.35)
                                        : Color.primary.opacity(0.06)
                                )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func filterLabel(_ f: ClipboardFilter) -> String {
        switch f {
        case .all: return t("plugin.clipboard.filter.all")
        case .text: return t("plugin.clipboard.filter.text")
        case .link: return t("plugin.clipboard.filter.link")
        case .image: return t("plugin.clipboard.filter.image")
        case .video: return t("plugin.clipboard.filter.video")
        case .file: return t("plugin.clipboard.filter.file")
        }
    }

    private var list: some View {
        let rows = store.filteredItems
        return Group {
            if rows.isEmpty {
                VStack(spacing: 6) {
                    Spacer(minLength: 40)
                    Image(systemName: "clipboard")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text(t("plugin.clipboard.empty"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 40)
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(rows) { item in
                                itemRow(item)
                                    .id(item.id)
                            }
                        }
                    }
                    .onChange(of: store.selectedID) { _, id in
                        if let id {
                            withAnimation(.easeOut(duration: 0.12)) {
                                proxy.scrollTo(id, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func itemRow(_ item: ClipboardItem) -> some View {
        let selected = store.selectedID == item.id
        return HStack(alignment: .center, spacing: 10) {
            kindIcon(item)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.preview)
                    .font(.callout)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                Text(kindAndTime(item))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                store.togglePin(item)
            } label: {
                Image(systemName: item.pinned ? "pin.fill" : "pin")
                    .foregroundStyle(item.pinned ? Color.orange : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(t("plugin.clipboard.pin"))

            Button {
                store.copyItem(item)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .help(t("plugin.clipboard.copy"))

            if item.kind == .image || item.kind == .file || item.kind == .video {
                Button {
                    store.openOriginal(item)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.plain)
                .help(t("plugin.clipboard.reveal"))
            }

            Button {
                store.deleteItem(item)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(t("plugin.clipboard.delete"))
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.teal.opacity(0.22) : Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? Color.teal.opacity(0.55) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            store.selectedID = item.id
            store.pasteItem(item)
        }
    }

    @ViewBuilder
    private func kindIcon(_ item: ClipboardItem) -> some View {
        if item.kind == .image, let img = store.thumbnail(for: item) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            Image(systemName: item.kind.symbolName)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.teal.opacity(0.2))
                )
        }
    }

    private func kindAndTime(_ item: ClipboardItem) -> String {
        let kind: String
        switch item.kind {
        case .text: kind = t("plugin.clipboard.filter.text")
        case .link: kind = t("plugin.clipboard.filter.link")
        case .image: kind = t("plugin.clipboard.filter.image")
        case .video: kind = t("plugin.clipboard.filter.video")
        case .file: kind = t("plugin.clipboard.filter.file")
        }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: loc)
        f.unitsStyle = .abbreviated
        var parts = [kind, f.localizedString(for: item.createdAt, relativeTo: Date())]
        if let detail = item.detail, !detail.isEmpty { parts.append(detail) }
        if let app = item.sourceApp, !app.isEmpty { parts.append(app) }
        return parts.joined(separator: " · ")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t("plugin.clipboard.hint.keys"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            HStack {
                Stepper {
                    Text(
                        store.keepsAllItems
                            ? t("plugin.clipboard.max.unlimited")
                            : tf("plugin.clipboard.max", store.settings.maxItems)
                    )
                } onIncrement: {
                    store.stepMaxItems(1)
                } onDecrement: {
                    store.stepMaxItems(-1)
                }
                .font(.caption)
                Spacer()
                Button(t("plugin.clipboard.clear")) {
                    store.clearUnpinned()
                }
                .font(.caption)
            }
        }
    }
}
