import AppKit
import SwiftUI

@MainActor
public final class SettingsWindowController {
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    public var onSave: ((AlwmConfig) -> Void)?
    public var onDump: (() -> Void)?
    public var onRevealConfig: (() -> Void)?
    public var onResetRuntime: (() -> Void)?
    public var onRerunOnboarding: (() -> Void)?
    public var monitorsProvider: (() -> [MonitorInfo])?
    public var runningAppsProvider: (() -> [AppRuleRunningApp])?
    public var onCaptureAppRuleFrame: ((String?) -> AppRuleCapturedGeometry?)?
    public var onApplyRulesNow: (() -> Void)?

    public init() {}

    public func open(config: AlwmConfig, initialPane: String? = nil) {
        let pane = SettingsPane(rawValue: initialPane ?? "") ?? .general
        // Always rebuild so toggles reflect the live config (not a stale copy).
        if let window {
            window.orderOut(nil)
            self.window = nil
        }
        detachCloseObserver()
        let root = SettingsRootView(
            config: config,
            initialPane: pane,
            monitors: monitorsProvider?() ?? [],
            runningAppsProvider: { [weak self] in self?.runningAppsProvider?() ?? [] },
            onCaptureAppRuleFrame: { [weak self] bundleID in self?.onCaptureAppRuleFrame?(bundleID) },
            onApplyRulesNow: { [weak self] in self?.onApplyRulesNow?() },
            onSave: { [weak self] c in self?.onSave?(c) },
            onDump: { [weak self] in self?.onDump?() },
            onRevealConfig: { [weak self] in self?.onRevealConfig?() },
            onResetRuntime: { [weak self] in self?.onResetRuntime?() },
            onRerunOnboarding: { [weak self] in self?.onRerunOnboarding?() }
        )
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = L10n.t("settings.title")
        window.setContentSize(NSSize(width: 920, height: 640))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.minSize = NSSize(width: 760, height: 520)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.detachCloseObserver()
                self?.window = nil
            }
        }
    }

    public func close() {
        detachCloseObserver()
        window?.orderOut(nil)
        window = nil
    }

    /// True only while Settings is the key window (do not block gestures when it sits in the background).
    public var isKeyFront: Bool {
        guard let window, window.isVisible else { return false }
        return window.isKeyWindow
    }

    /// True while the settings window is on screen (blocks focus-follows-mouse).
    public var isVisible: Bool {
        guard let window else { return false }
        return window.isVisible
    }

    private func detachCloseObserver() {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
    }
}

enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case general, about, diagnostics
    case layout, monitors, workspaces, rules
    case workspaceBar, borders
    case gesturesFocus, hotkeys
    case quake, capture, notepad, plugins

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L10n.t("pane.general")
        case .about: return L10n.t("pane.about")
        case .diagnostics: return L10n.t("pane.diagnostics")
        case .layout: return L10n.t("pane.layout")
        case .monitors: return L10n.t("pane.monitors")
        case .workspaces: return L10n.t("pane.workspaces")
        case .rules: return L10n.t("pane.rules")
        case .workspaceBar: return L10n.t("pane.workspace_bar")
        case .borders: return L10n.t("pane.borders")
        case .gesturesFocus: return L10n.t("pane.gestures")
        case .hotkeys: return L10n.t("pane.hotkeys")
        case .quake: return L10n.t("pane.quake")
        case .capture: return L10n.t("pane.capture")
        case .notepad: return L10n.t("pane.notepad")
        case .plugins: return L10n.t("pane.plugins")
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .about: return "info.circle"
        case .diagnostics: return "stethoscope"
        case .layout: return "rectangle.split.3x1"
        case .monitors: return "display.2"
        case .workspaces: return "square.grid.2x2"
        case .rules: return "list.bullet.rectangle"
        case .workspaceBar: return "menubar.rectangle"
        case .borders: return "square.dashed"
        case .gesturesFocus: return "hand.point.up.left"
        case .hotkeys: return "keyboard"
        case .quake: return "terminal"
        case .capture: return "camera.viewfinder"
        case .notepad: return "note.text"
        case .plugins: return "puzzlepiece.extension"
        }
    }
}

struct SettingsRootView: View {
    @State var config: AlwmConfig
    @State private var pane: SettingsPane
    @State private var showWhatsNew = false
    @State private var hotkeySearch = ""
    @State private var persistTask: Task<Void, Never>?
    @ObservedObject private var updates = AppUpdateService.shared
    @ObservedObject private var loc = LocalizationController.shared
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
        .frame(minWidth: 820, minHeight: 580)
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

    private func nav(_ p: SettingsPane) -> some View {
        Label(p.title, systemImage: p.systemImage).tag(p)
    }

    private var colorScheme: ColorScheme? {
        switch config.settings.theme {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    private var subtitle: String {
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
    private var detail: some View {
        // Native Form scrolling — wrapping Form in NSScrollView ate trackpad events
        // (SwiftUI Form swallowed the wheel; only the outer scrollbar knob moved).
        paneForm
            .scrollIndicators(.visible)
            .background(ForceLegacyVerticalScroller())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .id(pane)
    }

    @ViewBuilder
    private var paneForm: some View {
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

    // MARK: General

    private var generalPane: some View {
        Form {
            Section {
                Picker(L10n.t("language.title"), selection: $config.settings.language) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang == .system ? L10n.t("language.system") : lang.nativeName)
                            .tag(lang)
                    }
                }
            } header: {
                Text(L10n.t("language.title"))
            } footer: {
                Text(L10n.t("language.footer"))
            }
            Section {
                Picker(L10n.t("general.theme"), selection: $config.settings.theme) {
                    ForEach(AppTheme.allCases) { t in
                        Text(t.label).tag(t)
                    }
                }
                Toggle(L10n.t("general.show_menubar_label"), isOn: $config.settings.showMenuBarStatusLabel)
                    .toggleStyle(.switch)
                Toggle(L10n.t("general.workspace_bar"), isOn: $config.settings.workspaceBar.enabled)
                    .toggleStyle(.switch)
                Toggle(L10n.t("general.window_borders"), isOn: $config.settings.borders.enabled)
                    .toggleStyle(.switch)
            } header: {
                Text(L10n.t("general.appearance"))
            } footer: {
                Text(L10n.t("general.show_menubar_label.help"))
            }
            Section {
                Toggle(L10n.t("general.launch_at_login"), isOn: $config.settings.launchAtLogin)
                    .toggleStyle(.switch)
                Toggle(L10n.t("general.prevent_sleep"), isOn: $config.settings.preventDisplaySleep)
                    .toggleStyle(.switch)
            } header: {
                Text(L10n.t("general.power"))
            } footer: {
                Text(L10n.t("general.launch_at_login.help") + "\n" + L10n.t("general.prevent_sleep.help"))
            }
            Section(L10n.t("general.onboarding")) {
                Button(L10n.t("general.rerun_wizard")) {
                    config.settings.onboardingCompleted = false
                    persist()
                    onRerunOnboarding()
                }
                Text(L10n.t("general.rerun_wizard.help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(L10n.t("general.cli")) {
                LabeledContent("alwmctl") {
                    Text(AlwmVersion.ctlHint)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Toggle(L10n.t("general.ipc"), isOn: $config.settings.ipcEnabled)
                    .toggleStyle(.switch)
                Button(L10n.t("general.reveal_config")) { onRevealConfig() }
            }
            Section(L10n.t("general.extras")) {
                Toggle(L10n.t("general.quake"), isOn: $config.settings.quake.enabled)
                    .toggleStyle(.switch)
                Toggle(L10n.t("general.developer"), isOn: $config.settings.developerMode)
                    .toggleStyle(.switch)
            }
        }
        .formStyle(.grouped)
    }

    private var aboutPane: some View {
        Form {
            Section {
                HStack {
                    Spacer(minLength: 0)
                    VStack(spacing: 12) {
                        AlwmLogoImage(side: 96, cornerRadius: 22)
                        Text("ALWM")
                            .font(.title2.weight(.semibold))
                        Text("v\(AlwmVersion.installed)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                    Spacer(minLength: 0)
                }
            }
            Section {
                LabeledContent(L10n.t("about.app"), value: "ALWM")
                LabeledContent(L10n.t("about.version"), value: AlwmVersion.installed)
                if let latest = updates.latestVersion {
                    LabeledContent(L10n.t("about.latest"), value: latest)
                }
                LabeledContent(L10n.t("about.layout"), value: L10n.t("about.layout_value"))
                LabeledContent(L10n.t("about.license"), value: "GPL-3.0")
            }
            Section {
                updateStatusRow
            }
            Section(L10n.t("about.lineage")) {
                Text(L10n.t("about.lineage.body"))
                    .foregroundStyle(.secondary)
            }
            Section {
                Button(L10n.t("settings.whats_new")) { showWhatsNew = true }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            updates.checkForUpdates()
        }
    }

    @ViewBuilder
    private var updateStatusRow: some View {
        switch updates.phase {
        case .idle, .checking:
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.t("about.update.checking"))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        case .upToDate:
            Label(L10n.t("about.update.up_to_date"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
        case .available:
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.tf("about.update.available", updates.latestVersion ?? ""))
                    .foregroundStyle(.primary)
                Button {
                    updates.installUpdate()
                } label: {
                    Label(L10n.t("about.update.button"), systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
            }
        case .downloading:
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.t("about.update.downloading"))
                Spacer()
            }
        case .installing:
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.t("about.update.installing"))
                Spacer()
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tf("about.update.failed", message))
                    .foregroundStyle(.red)
                    .font(.callout)
                HStack {
                    Button(L10n.t("about.update.retry")) {
                        updates.checkForUpdates(force: true)
                    }
                    if updates.isUpdateAvailable {
                        Button(L10n.t("about.update.button")) {
                            updates.installUpdate()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    private var diagnosticsPane: some View {
        Form {
            Section {
                Toggle("Developer Mode", isOn: $config.settings.developerMode)
                    .toggleStyle(.switch)
                if config.settings.developerMode {
                    Button("Dump Runtime State") { onDump() }
                    Button("Reset Runtime State") { onResetRuntime() }
                }
                Button("Open ~/.config/alwm") { onRevealConfig() }
            } footer: {
                Text(
                    config.settings.developerMode
                        ? "Dump copies state to the clipboard and Console. Reset rescans windows like a fresh start."
                        : "Ligue Developer Mode para exibir ferramentas de runtime."
                )
            }
        }
        .formStyle(.grouped)
    }

    private var layoutPane: some View {
        Form {
            Section("Columns") {
                labeledSlider("Inner gap", value: $config.settings.gap, range: 0...40)
                labeledSlider("Outer gap", value: $config.settings.outerGap, range: 0...40)
                labeledSlider("Default column width", value: $config.settings.defaultColumnWidthRatio, range: 0.25...1)
                labeledNumber("Minimum column width", value: $config.settings.minColumnWidth)
            }
            Section("Motion") {
                labeledSlider("Animation duration (s)", value: $config.settings.animationDuration, range: 0...0.6)
                Text("Layout motion stays part of the scrolling model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var monitorsPane: some View {
        Form {
            Section("Detected displays") {
                if monitors.isEmpty {
                    Text("No monitors reported yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(monitors.enumerated()), id: \.offset) { _, mon in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(mon.name.isEmpty ? "Display \(mon.id)" : mon.name)
                                .font(.headline)
                            Text("id=\(mon.id)  \(Int(mon.frame.width))×\(Int(mon.frame.height)) @ (\(Int(mon.frame.x)), \(Int(mon.frame.y)))")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            Section("Tips") {
                Text("For scrolling columns across multiple displays, prefer vertical monitor arrangement in System Settings and an auto-hiding Dock so parked windows do not bleed sideways.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var workspacesPane: some View {
        WorkspacesSettingsPane(config: $config, monitors: monitors)
    }

    private var rulesPane: some View {
        AppRulesSettingsPane(
            config: $config,
            monitors: monitors,
            runningApps: runningAppsProvider(),
            onCaptureFrame: onCaptureAppRuleFrame,
            onApplyNow: {
                onSave(config)
                onApplyRulesNow()
            }
        )
    }

    private var workspaceBarPane: some View {
        Form {
            Section {
                Toggle("Enabled", isOn: $config.settings.workspaceBar.enabled)
                    .toggleStyle(.switch)
                Toggle("Reserve layout space", isOn: $config.settings.workspaceBar.reserveLayoutSpace)
                    .toggleStyle(.switch)
                    .disabled(config.settings.workspaceBar.position == .overlayMenuBar)
                Text(config.settings.workspaceBar.position == .overlayMenuBar
                     ? "Na menu bar não reserva espaço — as janelas usam a tela toda abaixo do sistema."
                     : "Quando ativo, o layout deixa espaço sob a barra.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Placement") {
                Picker("Position", selection: $config.settings.workspaceBar.position) {
                    ForEach(WorkspaceBarPosition.allCases) { Text($0.label).tag($0) }
                }
                Picker("Workspaces alignment", selection: $config.settings.workspaceBar.alignment) {
                    ForEach(WorkspaceBarAlignment.allCases) { Text($0.label).tag($0) }
                }
                labeledSlider(
                    "Offset horizontal",
                    value: $config.settings.workspaceBar.horizontalOffset,
                    range: -300...300,
                    id: "wsbar.offset"
                )
                Text("Negativo = esquerda · positivo = direita (px a partir do alinhamento).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                labeledSlider("Height", value: $config.settings.workspaceBar.height, range: 22...40, id: "wsbar.height")
                Text(config.settings.workspaceBar.position == .overlayMenuBar
                     ? "Na menu bar, Height controla o tamanho do pill dentro da faixa do sistema."
                     : "Altura da faixa abaixo da menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                labeledSlider("Width", value: $config.settings.workspaceBar.widthScale, range: 0.8...1.8, id: "wsbar.width")
                Text("Escala dos chips: padding, fonte do workspace e tamanho dos ícones.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                labeledSlider(
                    "Background opacity",
                    value: $config.settings.workspaceBar.backgroundOpacity,
                    range: 0...1,
                    id: "wsbar.opacity"
                )
                Text("0 = transparente · 1 = opaco. Aplica ao vivo no fundo do pill / faixa.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Show labels", isOn: $config.settings.workspaceBar.showLabels)
                    .toggleStyle(.switch)
                Toggle("Show app icons", isOn: $config.settings.workspaceBar.showAppIcons)
                    .toggleStyle(.switch)
                Toggle("Deduplicate icons", isOn: $config.settings.workspaceBar.deduplicateAppIcons)
                    .toggleStyle(.switch)
                    .disabled(!config.settings.workspaceBar.showAppIcons)
                Text("Alterações aplicam e gravam automaticamente.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Content")
            }
        }
        .formStyle(.grouped)
        .onChange(of: config.settings.workspaceBar) { _, bar in
            if bar.position == .overlayMenuBar, bar.reserveLayoutSpace {
                config.settings.workspaceBar.reserveLayoutSpace = false
            }
        }
    }

    private var bordersPane: some View {
        Form {
            Section {
                Toggle("Enabled", isOn: $config.settings.borders.enabled)
                    .toggleStyle(.switch)
                labeledSlider("Width", value: $config.settings.borders.width, range: 1...10)
                TextField("Color (hex)", text: $config.settings.borders.colorHex)
                    .textFieldStyle(.roundedBorder)
            } footer: {
                Text("O raio dos cantos segue o chrome da janela focada (sem ajuste manual).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var gesturesFocusPane: some View {
        Form {
            Section {
                Toggle(L10n.t("gestures.enabled"), isOn: $config.settings.gestures.enabled)
                    .toggleStyle(.switch)
                Toggle(L10n.t("gestures.scroll_snap"), isOn: $config.settings.gestures.scrollSnap)
                    .toggleStyle(.switch)
                Toggle(L10n.t("gestures.invert"), isOn: $config.settings.gestures.invertScroll)
                    .toggleStyle(.switch)
                labeledSlider(L10n.t("gestures.swipe_factor"), value: $config.settings.gestures.swipeScrollFactor, range: 0.4...5)
            } header: {
                Text(L10n.t("gestures.title"))
            }

            Section {
                if config.settings.gestures.bindings.isEmpty {
                    Text(L10n.t("gestures.bindings.empty"))
                        .foregroundStyle(.secondary)
                    Button {
                        config.settings.gestures.bindings = GestureBinding.default
                    } label: {
                        Label(L10n.t("gestures.bindings.restore"), systemImage: "arrow.counterclockwise")
                    }
                }
                ForEach(Array(config.settings.gestures.bindings.enumerated()), id: \.element.id) { index, binding in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Picker("", selection: $config.settings.gestures.bindings[index].action) {
                                ForEach(HotkeyActions.gestureActions, id: \.self) { action in
                                    Text(HotkeyActions.title(for: action)).tag(action)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Toggle("", isOn: $config.settings.gestures.bindings[index].enabled)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .help(binding.enabled ? L10n.t("menu.on") : L10n.t("menu.off"))

                            Button(role: .destructive) {
                                config.settings.gestures.bindings.remove(at: index)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help(L10n.t("common.remove"))
                        }

                        Text(HotkeyActions.detail(for: binding.action))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(alignment: .top, spacing: 20) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(L10n.t("common.fingers"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Picker("", selection: $config.settings.gestures.bindings[index].fingers) {
                                    Text("3").tag(3)
                                    Text("4").tag(4)
                                    Text("2").tag(2)
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .frame(width: 160)
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Text(L10n.t("common.direction"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Picker("", selection: $config.settings.gestures.bindings[index].direction) {
                                    ForEach(GestureDirection.allCases) { dir in
                                        Text(dir.label).tag(dir)
                                    }
                                }
                                .labelsHidden()
                                .frame(maxWidth: 220, alignment: .leading)
                            }
                            Spacer(minLength: 0)
                        }

                        Text(gestureBindingSummary(binding))
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                    .opacity(binding.enabled ? 1 : 0.55)
                }
                Button {
                    config.settings.gestures.bindings.append(
                        GestureBinding(
                            enabled: true,
                            fingers: 3,
                            direction: .left,
                            action: "workspace.prev"
                        )
                    )
                } label: {
                    Label(L10n.t("gestures.add"), systemImage: "plus")
                }
            } header: {
                Text(L10n.t("gestures.bindings"))
            } footer: {
                Text(L10n.t("gestures.bindings.help"))
            }

            Section {
                Label(L10n.t("gestures.mission_control.tip"), systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L10n.t("gestures.open_trackpad_settings")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.trackpad") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
            }

            Section {
                Toggle(L10n.t("focus.follows_mouse"), isOn: $config.settings.focusFollowsMouse)
                    .toggleStyle(.switch)
                Toggle(L10n.t("focus.move_mouse"), isOn: $config.settings.moveMouseToFocusedWindow)
                    .toggleStyle(.switch)
                Toggle(L10n.t("focus.warp"), isOn: $config.settings.warpCursorOnEmptyWorkspace)
                    .toggleStyle(.switch)
            } header: {
                Text(L10n.t("focus.title"))
            } footer: {
                Text(L10n.t("focus.warp.help"))
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if config.settings.gestures.bindings.isEmpty {
                config.settings.gestures.bindings = GestureBinding.default
            }
        }
    }

    private func gestureBindingSummary(_ binding: GestureBinding) -> String {
        let fingers = "\(binding.fingers)"
        return "\(fingers) · \(binding.direction.label) → \(HotkeyActions.title(for: binding.action))"
    }

    private var hotkeySearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(L10n.t("hotkeys.search"), text: $hotkeySearch)
                .textFieldStyle(.plain)
                .disableAutocorrection(true)
            if !hotkeySearch.isEmpty {
                Button {
                    hotkeySearch = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    private var filteredHotkeyIndices: [Int] {
        let q = hotkeySearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return Array(config.hotkeys.indices) }
        return config.hotkeys.indices.filter { index in
            let binding = config.hotkeys[index]
            let haystack = [
                binding.action,
                HotkeyActions.title(for: binding.action),
                HotkeyActions.detail(for: binding.action),
                binding.key,
                chord(binding),
                binding.modifiers.joined(separator: "+")
            ].joined(separator: " ").lowercased()
            return haystack.contains(q)
        }
    }

    private var hotkeysPane: some View {
        Form {
            Section {
                if filteredHotkeyIndices.isEmpty {
                    Text(L10n.t("hotkeys.search.empty"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }
                ForEach(filteredHotkeyIndices, id: \.self) { index in
                    let binding = config.hotkeys[index]
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("", selection: $config.hotkeys[index].action) {
                            ForEach(HotkeyActions.catalog(workspaces: config.workspaces), id: \.self) { action in
                                Text("\(HotkeyActions.title(for: action))  ·  \(action)").tag(action)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)

                        Text(HotkeyActions.detail(for: binding.action))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 12) {
                            Text(L10n.t("hotkeys.shortcut"))
                                .foregroundStyle(.secondary)
                                .frame(width: 64, alignment: .leading)
                            HotkeyRecorderField(
                                key: $config.hotkeys[index].key,
                                modifiers: $config.hotkeys[index].modifiers
                            )
                            Spacer(minLength: 8)
                            Text(chord(binding))
                                .font(.body.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 56, alignment: .trailing)
                            Button(role: .destructive) {
                                config.hotkeys.remove(at: index)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Button {
                    config.hotkeys.append(
                        HotkeyBinding(action: "relayout", key: "r", modifiers: ["option"])
                    )
                } label: {
                    Label(L10n.t("hotkeys.add"), systemImage: "plus")
                }
            } footer: {
                Text(L10n.t("hotkeys.record.help"))
            }
        }
        .formStyle(.grouped)
    }

    private var quakePane: some View {
        Form {
            Section {
                Toggle("Enabled", isOn: $config.settings.quake.enabled)
                    .toggleStyle(.switch)
                TextField("Bundle ID (empty = Ghostty → Terminal)", text: $config.settings.quake.bundleID)
            }
            Section("Placement") {
                Picker("Edge", selection: $config.settings.quake.edge) {
                    ForEach(QuakeEdge.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                labeledSlider("Size (thickness)", value: $config.settings.quake.sizeRatio, range: 0.15...0.9)
                Text(config.settings.quake.edge == .left || config.settings.quake.edge == .right
                     ? "Largura do painel em relação à tela."
                     : "Altura do painel em relação à tela.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                labeledSlider("Length along edge", value: $config.settings.quake.lengthRatio, range: 0.2...1.0)
                labeledNumber("Inset", value: $config.settings.quake.inset)
                labeledSlider("Animation (s)", value: $config.settings.quake.animationDuration, range: 0...0.5)
            }
            Section {
                Toggle(L10n.t("quake.blur"), isOn: Binding(
                    get: { config.settings.quake.blur },
                    set: { on in
                        config.settings.quake.blur = on
                        // Blur is only visible through a translucent terminal.
                        if on, config.settings.quake.opacity > 0.94 {
                            config.settings.quake.opacity = 0.8
                        }
                    }
                ))
                .toggleStyle(.switch)
                if config.settings.quake.blur {
                    labeledSlider(
                        L10n.t("quake.blur.intensity"),
                        value: $config.settings.quake.blurIntensity,
                        range: 0.05...1.0
                    )
                }
                labeledSlider(
                    L10n.t("quake.opacity"),
                    value: Binding(
                        get: { config.settings.quake.opacity },
                        set: { config.settings.quake.opacity = min(1, max(0.25, $0)) }
                    ),
                    range: 0.25...1.0
                )
                Text(L10n.t("quake.opacity.help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L10n.t("quake.blur.help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L10n.t("quake.shortcut.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(L10n.t("quake.appearance"))
            }
        }
        .formStyle(.grouped)
    }

    private var capturePane: some View {
        Form {
            Section {
                LabeledContent(L10n.t("capture.settings.screenshots")) {
                    Text(CaptureIO.picturesDir.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Button(L10n.t("capture.settings.open_screenshots")) {
                    CaptureIO.revealFolder(CaptureIO.picturesDir)
                }
            } header: {
                Text(L10n.t("capture.settings.screenshots"))
            } footer: {
                Text(L10n.t("capture.settings.screenshots.help"))
            }

            Section {
                LabeledContent(L10n.t("capture.settings.recordings")) {
                    Text(CaptureIO.moviesDir.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Button(L10n.t("capture.settings.open_recordings")) {
                    CaptureIO.revealFolder(CaptureIO.moviesDir)
                }
            } header: {
                Text(L10n.t("capture.settings.recordings"))
            } footer: {
                Text(L10n.t("capture.settings.recordings.help"))
            }

            Section {
                Text(L10n.t("capture.settings.hotkeys.help"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text(L10n.t("capture.settings.hotkeys"))
            }
        }
        .formStyle(.grouped)
    }

    private var notepadPane: some View {
        Form {
            Section {
                Toggle(L10n.t("notepad.enabled"), isOn: $config.settings.notepad.enabled)
                    .toggleStyle(.switch)
                Button(L10n.t("notepad.open_folder")) {
                    CaptureIO.revealFolder(NotesPaths.root)
                }
            }
            Section(L10n.t("notepad.placement")) {
                Picker(L10n.t("quake.edge"), selection: $config.settings.notepad.edge) {
                    ForEach(QuakeEdge.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                labeledSlider(L10n.t("notepad.size"), value: $config.settings.notepad.sizeRatio, range: 0.25...0.95)
                labeledSlider(L10n.t("notepad.length"), value: $config.settings.notepad.lengthRatio, range: 0.2...1.0)
                labeledNumber(L10n.t("notepad.inset"), value: $config.settings.notepad.inset)
                labeledSlider(L10n.t("notepad.animation"), value: $config.settings.notepad.animationDuration, range: 0...0.5)
            }
            Section {
                Toggle(L10n.t("quake.blur"), isOn: $config.settings.notepad.blur)
                    .toggleStyle(.switch)
                if config.settings.notepad.blur {
                    labeledSlider(
                        L10n.t("quake.blur.intensity"),
                        value: $config.settings.notepad.blurIntensity,
                        range: 0.05...1.0
                    )
                }
                labeledSlider(
                    L10n.t("quake.opacity"),
                    value: Binding(
                        get: { config.settings.notepad.opacity },
                        set: { config.settings.notepad.opacity = min(1, max(0.25, $0)) }
                    ),
                    range: 0.25...1.0
                )
                Text(L10n.t("notepad.shortcut.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(L10n.t("notepad.appearance"))
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Helpers

    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            persist()
        }
    }

    private func persist() {
        var synced = config
        synced.hotkeys = ConfigStore.syncWorkspaceHotkeys(
            workspaces: synced.workspaces,
            hotkeys: synced.hotkeys
        )
        if synced.hotkeys.count != config.hotkeys.count {
            config = synced
        }
        ConfigWriter.write(synced)
        onSave(synced)
    }

    private func labeledSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        id: String? = nil
    ) -> some View {
        let sliderID = id ?? "slider.\(title).\(range.lowerBound).\(range.upperBound)"
        return LabeledContent {
            HStack(spacing: 12) {
                Slider(
                    value: Binding(
                        get: { value.wrappedValue },
                        set: { newValue in
                            let clamped = min(range.upperBound, max(range.lowerBound, newValue))
                            value.wrappedValue = (clamped * 1000).rounded() / 1000
                        }
                    ),
                    in: range
                )
                .id(sliderID)
                .controlSize(.small)
                Text(value.wrappedValue, format: .number.precision(.fractionLength(2)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
                    .contentTransition(.numericText())
            }
            .frame(minWidth: 220)
        } label: {
            Text(title)
        }
        .id(sliderID + ".row")
    }

    private func labeledNumber(_ title: String, value: Binding<Double>) -> some View {
        LabeledContent(title) {
            TextField("", value: value, format: .number)
                .frame(width: 90)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func chord(_ b: HotkeyBinding) -> String {
        HotkeyActions.chord(key: b.key, modifiers: b.modifiers)
    }

    private func modifiersText(_ binding: Binding<[String]>) -> Binding<String> {
        Binding(
            get: { binding.wrappedValue.joined(separator: ", ") },
            set: {
                binding.wrappedValue = $0.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    .filter { !$0.isEmpty }
            }
        )
    }

    private func optionalString(_ binding: Binding<String?>) -> Binding<String> {
        SettingsBindings.optionalString(binding)
    }

    private func optionalDouble(_ binding: Binding<Double?>) -> Binding<String> {
        SettingsBindings.optionalDouble(binding)
    }
}

enum SettingsBindings {
    static func optionalString(_ binding: Binding<String?>) -> Binding<String> {
        Binding(
            get: { binding.wrappedValue ?? "" },
            set: { binding.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }

    static func optionalDouble(_ binding: Binding<Double?>) -> Binding<String> {
        Binding(
            get: { binding.wrappedValue.map { String(Int($0)) } ?? "" },
            set: { binding.wrappedValue = Double($0) }
        )
    }
}

/// Extracted so release builds can type-check Settings without timing out.
private struct WorkspacesSettingsPane: View {
    @Binding var config: AlwmConfig
    let monitors: [MonitorInfo]

    var body: some View {
        Form {
            Section {
                ForEach($config.workspaces) { $ws in
                    WorkspaceSettingsRow(
                        workspace: $ws,
                        monitors: monitors,
                        onDelete: { id in
                            config.workspaces.removeAll { $0.id == id }
                        }
                    )
                }
                Button(action: addWorkspace) {
                    Label("Add workspace", systemImage: "plus")
                }
            } footer: {
                Text("Cada monitor mostra só os workspaces dele. \"Principal (0)\" = primeiro display. Para um workspace aparecer só no segundo monitor, escolha \"Só 1: …\". Janelas enviadas a um workspace só aparecem quando ele está ativo.")
            }
        }
        .formStyle(.grouped)
    }

    private func addWorkspace() {
        let next = String((config.workspaces.compactMap { Int($0.id) }.max() ?? 0) + 1)
        config.workspaces.append(
            WorkspaceDefinition(id: next, name: next, layout: .niri, monitorIndex: nil)
        )
        config.hotkeys = ConfigStore.syncWorkspaceHotkeys(
            workspaces: config.workspaces,
            hotkeys: config.hotkeys
        )
    }
}

private struct WorkspaceSettingsRow: View {
    @Binding var workspace: WorkspaceDefinition
    let monitors: [MonitorInfo]
    var onDelete: (String) -> Void

    private var monitorSelection: Binding<String> {
        Binding(
            get: { workspace.monitorIndex.map(String.init) ?? "auto" },
            set: { workspace.monitorIndex = $0 == "auto" ? nil : Int($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("ID", text: $workspace.id).frame(width: 72)
                TextField("Name", text: $workspace.name)
                Button(role: .destructive) {
                    onDelete(workspace.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
            Picker("Layout", selection: $workspace.layout) {
                ForEach(WorkspaceLayoutStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            }
            Picker("Monitor", selection: monitorSelection) {
                Text("Principal (0)").tag("auto")
                ForEach(Array(monitors.enumerated()), id: \.offset) { idx, mon in
                    Text(monitorLabel(idx: idx, mon: mon)).tag(String(idx))
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func monitorLabel(idx: Int, mon: MonitorInfo) -> String {
        let name = mon.name.isEmpty ? "Display \(idx)" : mon.name
        return "Só \(idx): \(name)"
    }
}

struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss

    private var releases: [AlwmWhatsNew.Release] {
        AlwmWhatsNew.releases
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("What's New")
                .font(.title2.weight(.semibold))
                .padding(.bottom, 4)
            Text("ALWM \(AlwmVersion.string)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.bottom, 14)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(releases, id: \.version) { release in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Version \(release.version)")
                                .font(.headline)
                            ForEach(Array(release.items.enumerated()), id: \.offset) { _, line in
                                HStack(alignment: .top, spacing: 8) {
                                    Text("•")
                                        .foregroundStyle(.secondary)
                                    Text(line)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .font(.body)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.trailing, 4)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 16)
        }
        .padding(24)
        .frame(width: 520, height: 440)
    }
}

enum AlwmVersion {
    /// Kept in sync by `scripts/bump-version.sh`. Prefer `installed` for UI / update checks.
    static let string = "0.5.0"
    static let ctlHint = "~/.local/bin/alwmctl"
    /// Version of the running app (Info.plist), falling back to the embedded constant.
    static var installed: String {
        if let fromBundle = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !fromBundle.isEmpty {
            return fromBundle
        }
        return string
    }
}

enum AlwmWhatsNew {
    struct Release: Codable, Equatable {
        var version: String
        var items: [String]
    }

    private struct Catalog: Codable {
        var releases: [Release]
    }

    /// Legacy single-release file shape (pre multi-version history).
    private struct LegacyPayload: Codable {
        var version: String
        var items: [String]
    }

    static var releases: [Release] {
        guard let url = Bundle.module.url(forResource: "whatsnew", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return fallback
        }
        if let catalog = try? JSONDecoder().decode(Catalog.self, from: data),
           !catalog.releases.isEmpty {
            return catalog.releases.filter { !$0.items.isEmpty }
        }
        if let legacy = try? JSONDecoder().decode(LegacyPayload.self, from: data),
           !legacy.items.isEmpty {
            return [Release(version: legacy.version, items: legacy.items)]
        }
        return fallback
    }

    private static var fallback: [Release] {
        [Release(version: AlwmVersion.string, items: ["See the README for the latest changes."])]
    }
}

/// Click “Gravar” then press a key combo; writes key + modifiers.
struct HotkeyRecorderField: View {
    @Binding var key: String
    @Binding var modifiers: [String]
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Text(display)
                .font(.body.monospaced())
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(recording ? Color.accentColor : Color.clear, lineWidth: 1.5)
                )
            Button(recording ? "Esc…" : "Gravar") {
                if recording {
                    stopRecording()
                } else {
                    startRecording()
                }
            }
            .buttonStyle(.bordered)
        }
        .onDisappear { stopRecording() }
    }

    private var display: String {
        if recording { return "Pressione…" }
        return HotkeyActions.chord(key: key, modifiers: modifiers)
    }

    private func startRecording() {
        stopRecording()
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // escape
                DispatchQueue.main.async { stopRecording() }
                return nil
            }
            var mods: [String] = []
            if event.modifierFlags.contains(.command) { mods.append("command") }
            if event.modifierFlags.contains(.option) { mods.append("option") }
            if event.modifierFlags.contains(.shift) { mods.append("shift") }
            if event.modifierFlags.contains(.control) { mods.append("control") }
            if let name = Self.keyName(from: event) {
                DispatchQueue.main.async {
                    key = name
                    modifiers = mods
                    stopRecording()
                }
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        recording = false
    }

    private static func keyName(from event: NSEvent) -> String? {
        let code = event.keyCode
        let map: [UInt16: String] = [
            0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
            11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
            18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
            31: "o", 32: "u", 34: "i", 35: "p", 37: "l", 38: "j", 40: "k", 45: "n", 46: "m",
            123: "left", 124: "right", 125: "down", 126: "up",
            49: "space", 48: "tab", 36: "return", 53: "escape",
            43: ",", 47: ".",
            27: "-", 24: "=",
            33: "[", 30: "]",
            50: "grave",
            10: "grave", // ISO section — often the `~ key on ABNT/ISO
            39: "'"
        ]
        return map[code]
    }
}

enum ConfigWriter {
    static func write(_ config: AlwmConfig) {
        writeSettings(config.settings)
        writeHotkeys(config.hotkeys)
        writeGestures(config.settings.gestures.bindings)
        writeWorkspaces(config.workspaces)
        writeRules(config.rules)
    }

    static func writeSettings(_ settings: LayoutSettings) {
        let text = """
        gap = \(settings.gap)
        outerGap = \(settings.outerGap)
        defaultColumnWidthRatio = \(settings.defaultColumnWidthRatio)
        minColumnWidth = \(settings.minColumnWidth)
        animationDuration = \(settings.animationDuration)
        focusFollowsMouse = \(settings.focusFollowsMouse)
        moveMouseToFocusedWindow = \(settings.moveMouseToFocusedWindow)
        warpCursorOnEmptyWorkspace = \(settings.warpCursorOnEmptyWorkspace)
        ipcEnabled = \(settings.ipcEnabled)
        developerMode = \(settings.developerMode)
        theme = "\(settings.theme.rawValue)"
        language = "\(settings.language.rawValue)"
        showMenuBarStatusLabel = \(settings.showMenuBarStatusLabel)
        preventDisplaySleep = \(settings.preventDisplaySleep)
        launchAtLogin = \(settings.launchAtLogin)
        onboardingCompleted = \(settings.onboardingCompleted)
        bordersEnabled = \(settings.borders.enabled)
        borderWidth = \(settings.borders.width)
        borderColor = "\(settings.borders.colorHex)"
        workspaceBarEnabled = \(settings.workspaceBar.enabled)
        workspaceBarHeight = \(settings.workspaceBar.height)
        workspaceBarWidthScale = \(settings.workspaceBar.widthScale)
        workspaceBarPosition = "\(settings.workspaceBar.position.rawValue)"
        workspaceBarAlignment = "\(settings.workspaceBar.alignment.rawValue)"
        workspaceBarHorizontalOffset = \(settings.workspaceBar.horizontalOffset)
        workspaceBarShowLabels = \(settings.workspaceBar.showLabels)
        workspaceBarShowAppIcons = \(settings.workspaceBar.showAppIcons)
        workspaceBarDeduplicateAppIcons = \(settings.workspaceBar.deduplicateAppIcons)
        workspaceBarShowFocusedStatus = \(settings.workspaceBar.showFocusedStatus)
        workspaceBarBackgroundOpacity = \(settings.workspaceBar.backgroundOpacity)
        workspaceBarReserveLayoutSpace = \(settings.workspaceBar.reserveLayoutSpace)
        quakeEnabled = \(settings.quake.enabled)
        quakeBundleID = "\(settings.quake.bundleID)"
        quakeSizeRatio = \(settings.quake.sizeRatio)
        quakeLengthRatio = \(settings.quake.lengthRatio)
        quakeAnimationDuration = \(settings.quake.animationDuration)
        quakeInset = \(settings.quake.inset)
        quakeEdge = "\(settings.quake.edge.rawValue)"
        quakeBlur = \(settings.quake.blur)
        quakeBlurIntensity = \(settings.quake.blurIntensity)
        quakeOpacity = \(settings.quake.opacity)
        notepadEnabled = \(settings.notepad.enabled)
        notepadSizeRatio = \(settings.notepad.sizeRatio)
        notepadLengthRatio = \(settings.notepad.lengthRatio)
        notepadAnimationDuration = \(settings.notepad.animationDuration)
        notepadInset = \(settings.notepad.inset)
        notepadEdge = "\(settings.notepad.edge.rawValue)"
        notepadBlur = \(settings.notepad.blur)
        notepadBlurIntensity = \(settings.notepad.blurIntensity)
        notepadOpacity = \(settings.notepad.opacity)
        gesturesEnabled = \(settings.gestures.enabled)
        scrollSnap = \(settings.gestures.scrollSnap)
        swipeScrollFactor = \(settings.gestures.swipeScrollFactor)
        invertScroll = \(settings.gestures.invertScroll)
        """
        try? text.write(to: ConfigPaths.settings, atomically: true, encoding: .utf8)
    }

    static func writeHotkeys(_ hotkeys: [HotkeyBinding]) {
        var lines: [String] = []
        for hk in hotkeys {
            let mods = hk.modifiers.map { "\"\($0)\"" }.joined(separator: ", ")
            lines.append("""
            [[bindings]]
            action = "\(hk.action)"
            key = "\(hk.key)"
            modifiers = [\(mods)]
            """)
        }
        try? lines.joined(separator: "\n\n").write(to: ConfigPaths.hotkeys, atomically: true, encoding: .utf8)
    }

    static func writeGestures(_ bindings: [GestureBinding]) {
        var lines: [String] = []
        for b in bindings {
            lines.append("""
            [[bindings]]
            id = "\(b.id)"
            enabled = \(b.enabled)
            fingers = \(b.fingers)
            direction = "\(b.direction.rawValue)"
            action = "\(b.action)"
            """)
        }
        try? lines.joined(separator: "\n\n").write(to: ConfigPaths.gestures, atomically: true, encoding: .utf8)
    }

    static func writeWorkspaces(_ workspaces: [WorkspaceDefinition]) {
        var lines: [String] = []
        for ws in workspaces {
            var block = """
            [[workspaces]]
            id = "\(ws.id)"
            name = "\(ws.name)"
            layout = "\(ws.layout.rawValue)"
            """
            if let idx = ws.monitorIndex {
                block += "\nmonitorIndex = \(idx)"
            }
            lines.append(block)
        }
        try? lines.joined(separator: "\n\n").write(to: ConfigPaths.workspaces, atomically: true, encoding: .utf8)
    }

    static func writeRules(_ rules: [AppRule]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: ConfigPaths.appRulesDir, withIntermediateDirectories: true)
        if let existing = try? fm.contentsOfDirectory(at: ConfigPaths.appRulesDir, includingPropertiesForKeys: nil) {
            for url in existing where url.pathExtension == "toml" {
                try? fm.removeItem(at: url)
            }
        }
        for (index, rule) in rules.enumerated() {
            let slug = (rule.bundleID ?? rule.appName ?? "rule-\(index)")
                .replacingOccurrences(of: ".", with: "-")
                .replacingOccurrences(of: " ", with: "-")
                .lowercased()
            var lines = ["mode = \"\(rule.mode.rawValue)\""]
            if let bid = rule.bundleID { lines.insert("bundleID = \"\(bid)\"", at: 0) }
            if let name = rule.appName { lines.append("appName = \"\(name)\"") }
            if let ws = rule.workspace { lines.append("workspace = \"\(ws)\"") }
            if let idx = rule.monitorIndex { lines.append("monitorIndex = \(idx)") }
            if let w = rule.minWidth { lines.append("minWidth = \(w)") }
            if let h = rule.minHeight { lines.append("minHeight = \(h)") }
            if let w = rule.width { lines.append("width = \(w)") }
            if let h = rule.height { lines.append("height = \(h)") }
            if let x = rule.x { lines.append("x = \(x)") }
            if let y = rule.y { lines.append("y = \(y)") }
            let url = ConfigPaths.appRulesDir.appendingPathComponent("\(slug).toml")
            try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
