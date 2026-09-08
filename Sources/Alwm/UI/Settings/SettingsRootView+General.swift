import AppKit
import SwiftUI
import AlwmPluginAPI

// MARK: - SettingsRootView — General / About / Diagnostics

extension SettingsRootView {

    // MARK: General

    var generalPane: some View {
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
                    .disabled(config.settings.workspaceBar.enabled)
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


    var aboutPane: some View {
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
            Section(L10n.t("about.contributors")) {
                creditsPeopleSection(
                    people: credits.contributors,
                    state: credits.contributorsState,
                    emptyKey: "about.contributors.empty",
                    showContributionCount: true
                )
            }
            Section(L10n.t("about.donors")) {
                Text(L10n.t("about.donors.blurb"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                creditsPeopleSection(
                    people: credits.donors,
                    state: credits.donorsState,
                    emptyKey: "about.donors.empty",
                    showContributionCount: false
                )
            }
            Section(L10n.t("settings.whats_new")) {
                aboutWhatsNewList
            }
        }
        .formStyle(.grouped)
        .onAppear {
            updates.checkForUpdates()
            credits.refreshIfNeeded()
        }
    }


    var diagnosticsPane: some View {
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


    var aboutWhatsNewList: some View {
        let releases = AlwmWhatsNew.releases
        return Group {
            if releases.isEmpty {
                Text(L10n.t("about.whats_new.empty"))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(releases, id: \.version) { release in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(L10n.tf("about.whats_new.version", release.version))
                                    .font(.subheadline.weight(.semibold))
                                ForEach(Array(release.items.enumerated()), id: \.offset) { _, line in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text("•")
                                            .foregroundStyle(.secondary)
                                        Text(line)
                                            .font(.callout)
                                            .foregroundStyle(.primary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(minHeight: 140, maxHeight: 220)
            }
        }
    }


    @ViewBuilder
    func creditsPeopleSection(
        people: [CreditsService.Person],
        state: CreditsService.LoadState,
        emptyKey: String,
        showContributionCount: Bool
    ) -> some View {
        switch state {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.t("about.credits.loading"))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        case .failed(let message):
            Text(L10n.tf("about.credits.failed", message))
                .font(.caption)
                .foregroundStyle(.secondary)
        case .ready:
            if people.isEmpty {
                Text(L10n.t(emptyKey))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(people) { person in
                    creditsPersonRow(person, showContributionCount: showContributionCount)
                }
            }
        }
    }


    @ViewBuilder
    var updateStatusRow: some View {
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

    func creditsPersonRow(_ person: CreditsService.Person, showContributionCount: Bool) -> some View {
        Button {
            if let url = person.profileURL {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 12) {
                CreditsAvatarView(url: person.avatarURL, name: person.name)
                VStack(alignment: .leading, spacing: 2) {
                    Text(person.name)
                        .foregroundStyle(.primary)
                    if showContributionCount, let detail = person.detail {
                        Text(L10n.tf("about.contributors.commits", detail))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let detail = person.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if person.profileURL != nil {
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(person.profileURL == nil)
    }
}
