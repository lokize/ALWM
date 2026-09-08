import AppKit
import SwiftUI
import AlwmPluginAPI

// MARK: - Settings root shell

struct SettingsRootView: View {
    @State var config: AlwmConfig
    @State var pane: SettingsPane
    @State var showWhatsNew = false
    @State var hotkeySearch = ""
    @State var persistTask: Task<Void, Never>?
    @ObservedObject var updates = AppUpdateService.shared
    @ObservedObject var credits = CreditsService.shared
    @ObservedObject var loc = LocalizationController.shared
    let monitors: [MonitorInfo]
    let runningAppsProvider: () -> [AppRuleRunningApp]
    let onCaptureAppRuleFrame: (String?) -> AppRuleCapturedGeometry?
    let onApplyRulesNow: () -> Void
    var onSave: (AlwmConfig) -> Void
    var onDump: () -> Void
    var onRevealConfig: () -> Void
    var onResetRuntime: () -> Void
    var onRerunOnboarding: () -> Void

    init(
        config: AlwmConfig,
        initialPane: SettingsPane,
        monitors: [MonitorInfo],
        runningAppsProvider: @escaping () -> [AppRuleRunningApp],
        onCaptureAppRuleFrame: @escaping (String?) -> AppRuleCapturedGeometry?,
        onApplyRulesNow: @escaping () -> Void,
        onSave: @escaping (AlwmConfig) -> Void,
        onDump: @escaping () -> Void,
        onRevealConfig: @escaping () -> Void,
        onResetRuntime: @escaping () -> Void,
        onRerunOnboarding: @escaping () -> Void
    ) {
        _config = State(initialValue: config)
        _pane = State(initialValue: initialPane)
        self.monitors = monitors
        self.runningAppsProvider = runningAppsProvider
        self.onCaptureAppRuleFrame = onCaptureAppRuleFrame
        self.onApplyRulesNow = onApplyRulesNow
        self.onSave = onSave
        self.onDump = onDump
        self.onRevealConfig = onRevealConfig
        self.onResetRuntime = onResetRuntime
        self.onRerunOnboarding = onRerunOnboarding
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                Section {
                    nav(.general)
                    nav(.about)
                    nav(.diagnostics)
                }
                Section(L10n.t("nav.layout")) {
                    nav(.layout)
                    nav(.monitors)
                    nav(.workspaces)
                    nav(.rules)
                }
                Section(L10n.t("nav.appearance")) {
                    nav(.workspaceBar)
                    nav(.borders)
                }
                Section(L10n.t("nav.input")) {
                    nav(.gesturesFocus)
                    nav(.hotkeys)
                }
                Section(L10n.t("nav.extras")) {
                    nav(.quake)
                    nav(.capture)
                    nav(.notepad)
                    nav(.plugins)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            .listStyle(.sidebar)
        } detail: {
            detail
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(pane.title).font(.title2.weight(.semibold))
                                Text(subtitle).font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(L10n.t("settings.whats_new")) { showWhatsNew = true }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        Divider()
                        if pane == .hotkeys {
                            hotkeySearchBar
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                            Divider()
                        }
                    }
                    .background(.bar)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        Divider()
                        HStack {
                            Text(L10n.t("settings.config_path"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(L10n.t("settings.footer_meta"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                    .background(.bar)
                }
        }
        .frame(minWidth: 960, minHeight: 680)
        .preferredColorScheme(colorScheme)
        .alwmLocalized()
        .onChange(of: pane) { _, newPane in
            if newPane != .hotkeys {
                hotkeySearch = ""
            }
        }
        .onChange(of: config) { _, _ in
            schedulePersist()
        }
        .onChange(of: config.settings.language) { _, language in
            LocalizationController.shared.apply(language)
            PluginManager.shared.requestBarRefresh()
        }
        .onDisappear {
            persistTask?.cancel()
            persistTask = nil
            // Flush pending edits when the window closes.
            persist()
        }
        .sheet(isPresented: $showWhatsNew) {
            WhatsNewView()
        }
    }

    func nav(_ p: SettingsPane) -> some View {
        Label(p.title, systemImage: p.systemImage).tag(p)
    }

    var colorScheme: ColorScheme? {
        switch config.settings.theme {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var subtitle: String {
        switch pane {
        case .general: return L10n.t("pane.general.sub")
        case .about: return L10n.t("pane.about.sub")
        case .diagnostics: return L10n.t("pane.diagnostics.sub")
        case .layout: return L10n.t("pane.layout.sub")
        case .monitors: return L10n.t("pane.monitors.sub")
        case .workspaces: return L10n.t("pane.workspaces.sub")
        case .rules: return L10n.t("pane.rules.sub")
        case .workspaceBar: return L10n.t("pane.workspace_bar.sub")
        case .borders: return L10n.t("pane.borders.sub")
        case .gesturesFocus: return L10n.t("pane.gestures.sub")
        case .hotkeys: return L10n.t("pane.hotkeys.sub")
        case .quake: return L10n.t("pane.quake.sub")
        case .capture: return L10n.t("pane.capture.sub")
        case .notepad: return L10n.t("pane.notepad.sub")
        case .plugins: return L10n.t("pane.plugins.sub")
        }
    }

    @ViewBuilder
    var detail: some View {
        // Native Form scrolling — wrapping Form in NSScrollView ate trackpad events
        // (SwiftUI Form swallowed the wheel; only the outer scrollbar knob moved).
        // Plugins embeds its own ScrollView — skip the Form scroller probe.
        if pane == .plugins {
            // Plugins owns its ScrollView; fill the detail column so GeometryReader
            // inside gets a finite height (otherwise catalog clips with no scroller).
            // Do not `.clipped()` here — it hid the order footer below the catalog.
            paneForm
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .focusEffectDisabled()
                .id(pane)
        } else {
            paneForm
                .scrollIndicators(.visible)
                .background(ForceLegacyVerticalScroller())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .id(pane)
        }
    }

    @ViewBuilder
    var paneForm: some View {
        switch pane {
        case .general: generalPane
        case .about: aboutPane
        case .diagnostics: diagnosticsPane
        case .layout: layoutPane
        case .monitors: monitorsPane
        case .workspaces: workspacesPane
        case .rules: rulesPane
        case .workspaceBar: workspaceBarPane
        case .borders: bordersPane
        case .gesturesFocus: gesturesFocusPane
        case .hotkeys: hotkeysPane
        case .quake: quakePane
        case .capture: capturePane
        case .notepad: notepadPane
        case .plugins: PluginsSettingsPane()
        }
    }
}

