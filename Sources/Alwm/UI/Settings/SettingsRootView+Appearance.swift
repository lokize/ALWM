import AppKit
import SwiftUI
import AlwmPluginAPI

// MARK: - SettingsRootView — Workspace bar / Borders

extension SettingsRootView {

    /// Settings only (no plugin order) — lives in the upper ScrollView.
    var workspaceBarSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
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
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            GroupBox("Placement") {
                VStack(alignment: .leading, spacing: 10) {
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            GroupBox("Content") {
                VStack(alignment: .leading, spacing: 10) {
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
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Alterações aplicam e gravam automaticamente.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onChange(of: config.settings.workspaceBar) { _, bar in
            if bar.position == .overlayMenuBar, bar.reserveLayoutSpace {
                config.settings.workspaceBar.reserveLayoutSpace = false
            }
        }
    }

    /// Fixed bottom panel with its own scroller — never clipped by the settings ScrollView.
    var workspaceBarPluginOrderPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("wsbar.plugins_order"))
                .font(.headline)
            if pluginOrderRows.isEmpty {
                Text(L10n.t("wsbar.plugins_order.empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
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
                            .padding(.vertical, 4)
                            if index < pluginOrderRows.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
                .frame(height: 200)
            }
            Text(L10n.t("wsbar.plugins_order.help"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.bar)
    }

    /// Kept for paneForm switch compatibility.
    var workspaceBarPane: some View {
        workspaceBarSettings
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
