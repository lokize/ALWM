import AppKit
import SwiftUI
import AlwmPluginAPI

@MainActor
enum WallpaperDirectoryPickerPresentation {
    static func configure(_ panel: NSOpenPanel) {
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Usar pasta"
        panel.level = .statusBar
    }

    static func present(
        _ panel: NSOpenPanel,
        from parent: NSWindow?,
        completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        if let parent, parent.isVisible {
            panel.beginSheetModal(for: parent, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }
}

// MARK: - SettingsRootView — Workspace bar / Borders

extension SettingsRootView {

    var wallpapersPane: some View {
        Form {
            Section("Papel de parede") {
                Toggle("Gerenciar papéis de parede pelo ALWM", isOn: $config.settings.wallpaper.enabled)
                HStack {
                    TextField("Pasta de imagens e vídeos", text: $config.settings.wallpaper.directory)
                    Button("Escolher…") {
                        chooseWallpaperDirectory { path in
                            guard let path else { return }
                            config.settings.wallpaper.directory = path
                        }
                    }
                }
                Text("Formatos: JPG, PNG, HEIC, TIFF, WebP, MP4, MOV e M4V. Os vídeos são reproduzidos sem som por padrão.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Incluir subpastas", isOn: $config.settings.wallpaper.recursive)
                Toggle("Silenciar vídeos", isOn: $config.settings.wallpaper.videoMuted)
            }

            Section("Rotação automática") {
                Toggle("Mudar automaticamente", isOn: $config.settings.wallpaper.rotationEnabled)
                Picker("Ordem", selection: $config.settings.wallpaper.order) {
                    Text("Aleatória").tag(WallpaperOrder.random)
                    Text("Alfabética").tag(WallpaperOrder.alphabetical)
                }
                HStack {
                    Text("Intervalo")
                    Spacer()
                    TextField("Intervalo", value: Binding(
                        get: {
                            config.settings.wallpaper.intervalUnit.displayValue(
                                from: config.settings.wallpaper.intervalSeconds
                            )
                        },
                        set: { value in
                            config.settings.wallpaper.intervalSeconds = config.settings.wallpaper.intervalUnit
                                .intervalSeconds(from: value)
                        }
                    ), format: .number.precision(.fractionLength(0...2)))
                        .frame(width: 100)
                    Picker("Unidade do intervalo", selection: $config.settings.wallpaper.intervalUnit) {
                        ForEach(WallpaperIntervalUnit.allCases) { unit in
                            Text(unit.label).tag(unit)
                        }
                    }
                    .labelsHidden()
                }
                .disabled(!config.settings.wallpaper.rotationEnabled)
                Button("Próximo papel de parede") {
                    WallpaperController.shared.advance()
                }
                .disabled(!config.settings.wallpaper.enabled)
            }

            Section("Monitores") {
                Toggle("Selecionar arquivo separadamente por monitor", isOn: $config.settings.wallpaper.separatePerMonitor)
                if config.settings.wallpaper.separatePerMonitor {
                    ForEach(monitors, id: \.id) { monitor in
                        HStack {
                            Text(monitor.name.isEmpty ? "Monitor \(monitor.id)" : monitor.name)
                                .frame(width: 170, alignment: .leading)
                            TextField("Usar pasta principal", text: Binding(
                                get: { config.settings.wallpaper.monitorDirectories[String(monitor.id)] ?? "" },
                                set: { config.settings.wallpaper.monitorDirectories[String(monitor.id)] = $0 }
                            ))
                            Button("Escolher…") {
                                chooseWallpaperDirectory { path in
                                    guard let path else { return }
                                    config.settings.wallpaper.monitorDirectories[String(monitor.id)] = path
                                }
                            }
                        }
                    }
                    Text("Deixe a pasta de um monitor vazia para usar a pasta principal.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: config.settings.wallpaper.intervalSeconds) { _, interval in
            let valid = min(86400, max(1, interval.isFinite ? interval : 1800))
            if interval != valid { config.settings.wallpaper.intervalSeconds = valid }
        }
    }

    func chooseWallpaperDirectory(completion: @escaping (String?) -> Void) {
        let panel = NSOpenPanel()
        WallpaperDirectoryPickerPresentation.configure(panel)
        let parent = NSApp.windows.first {
            $0.identifier?.rawValue == SettingsWindowController.windowIdentifier
                && $0.isVisible
        } ?? NSApp.keyWindow
        WallpaperDirectoryPickerPresentation.present(panel, from: parent) { response in
            completion(response == .OK ? panel.url?.path : nil)
        }
    }

    /// Form settings only — plugin order lives in a separate bottom inset so
    /// reordering does not remount / jump the Form scroll.
    var workspaceBarPane: some View {
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
                Text("Offset zero centraliza a barra. Outros valores partem do alinhamento selecionado.")
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
                Toggle("Plugins em badges separados", isOn: $config.settings.workspaceBar.separatePluginBadges)
                    .toggleStyle(.switch)
                labeledSlider(
                    "Espaço entre badges",
                    value: $config.settings.workspaceBar.pluginBadgeSpacing,
                    range: 2...20,
                    id: "wsbar.badge_spacing"
                )
                .disabled(!config.settings.workspaceBar.separatePluginBadges)
                Text("Cada plugin ganha uma cápsula própria; os workspaces continuam agrupados.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Badges dos plugins")
            }

            Section {
                Toggle("Show labels", isOn: $config.settings.workspaceBar.showLabels)
                    .toggleStyle(.switch)
                Toggle("Show app icons", isOn: $config.settings.workspaceBar.showAppIcons)
                    .toggleStyle(.switch)
                Toggle("Deduplicate icons", isOn: $config.settings.workspaceBar.deduplicateAppIcons)
                    .toggleStyle(.switch)
                    .disabled(!config.settings.workspaceBar.showAppIcons)
                Toggle(L10n.t("wsbar.focused_status"), isOn: $config.settings.workspaceBar.showFocusedStatus)
                    .toggleStyle(.switch)
                Text(L10n.t("wsbar.focused_status.help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Content")
            } footer: {
                Text("Alterações aplicam e gravam automaticamente.")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .onChange(of: config.settings.workspaceBar) { _, bar in
            if bar.position == .overlayMenuBar, bar.reserveLayoutSpace {
                config.settings.workspaceBar.reserveLayoutSpace = false
            }
        }
    }

    /// Bottom inset panel — own scroll; reordering does not touch the Form above.
    var workspaceBarPluginOrderPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("wsbar.plugins_order"))
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 10)

            HStack(spacing: 12) {
                Text(L10n.t("wsbar.plugins_default_monitor"))
                    .foregroundStyle(.secondary)
                Picker(L10n.t("wsbar.plugins_default_monitor"), selection: Binding(
                    get: { PluginManager.shared.settings.defaultDisplayMonitorID },
                    set: { id in
                        PluginManager.shared.settings.setDefaultDisplayMonitorID(id)
                        PluginManager.shared.requestBarRefresh()
                    }
                )) {
                    ForEach(Array(monitors.enumerated()), id: \.element.id) { index, monitor in
                        let name = monitor.name.isEmpty
                            ? String(format: L10n.t("plugins.display.unnamed"), index + 1)
                            : monitor.name
                        Text(name).tag(monitor.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
                .disabled(monitors.isEmpty)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)

            if pluginOrderRows.isEmpty {
                Text(L10n.t("wsbar.plugins_order.empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            } else {
                let listHeight = min(220, CGFloat(pluginOrderRows.count) * 36 + 8)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(pluginOrderRows.enumerated()), id: \.element.id) { index, row in
                            HStack(spacing: 8) {
                                Text("\(index + 1)")
                                    .font(.system(.body, design: .monospaced).weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22, alignment: .trailing)
                                Text(row.name)
                                    .font(.body.weight(.medium))
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Button {
                                    PluginOrderInline.move(id: row.id, delta: -1)
                                } label: {
                                    Image(systemName: "chevron.up")
                                }
                                .buttonStyle(.borderless)
                                .disabled(index == 0)
                                Button {
                                    PluginOrderInline.move(id: row.id, delta: 1)
                                } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .buttonStyle(.borderless)
                                .disabled(index >= pluginOrderRows.count - 1)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 4)
                            if index < pluginOrderRows.count - 1 {
                                Divider().padding(.horizontal, 20)
                            }
                        }
                    }
                }
                .frame(height: listHeight)

                Text(L10n.t("wsbar.plugins_order.help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.bar)
    }

    var bordersPane: some View {
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
}
