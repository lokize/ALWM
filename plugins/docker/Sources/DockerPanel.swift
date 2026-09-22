import AppKit
import SwiftUI
import AlwmL10n
import AlwmPluginAPI

private final class DockerKeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
enum DockerPanelController {
    private static var window: DockerKeyPanel?

    static func close() {
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

    static func open(anchoredTo geometry: PluginPanelAnchor.Geometry?) {
        let geo = geometry ?? PluginPanelAnchor.remembered(forPlugin: "dev.alwm.docker")
        let root = DockerPanelView().pluginLocalized()
        let hosting = NSHostingController(rootView: root)
        let width: CGFloat = 560
        let height: CGFloat = 620

        if let old = window {
            PluginPanelOutsideClick.stop(for: old)
            old.orderOut(nil)
            window = nil
        }

        let win = DockerKeyPanel(
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
        window = win
        PluginPanelAnchor.attachBeforePresenting(win, size: NSSize(width: width, height: height), to: geo)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        PluginPanelAnchor.attachAfterPresenting(win, size: NSSize(width: width, height: height), to: geo)
        PluginPanelOutsideClick.watch(win)
        Task { await DockerStore.shared.refresh() }
    }
}

// MARK: - Root

struct DockerPanelView: View {
    @ObservedObject private var store = DockerStore.shared
    @State private var showNewProject = false
    @State private var editName = ""
    @State private var editYAML = ""
    @State private var editDockerfile = ""
    @State private var editNotes = ""
    @State private var editingProjectID: String?
    @State private var showLogs = false

    private var loc: String { store.localeCode() }
    private func t(_ key: String) -> String { PluginL10n.t(key, locale: loc) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            tabBar
            if !store.dockerAvailable {
                missingDocker
            } else {
                Group {
                    switch store.selectedTab {
                    case .containers: containersPane
                    case .compose: composePane
                    }
                }
            }
            footer
        }
        .padding(14)
        .frame(width: 560, height: 620, alignment: .topLeading)
        .pluginPanelChrome(cornerRadius: 14)
        .sheet(isPresented: $showNewProject) {
            projectEditorSheet
        }
        .sheet(isPresented: $showLogs) {
            logsSheet
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "shippingbox.fill")
                .foregroundStyle(Color(nsColor: store.barTint))
            Text(t("plugin.docker.title"))
                .font(.headline)
            Spacer()
            if let busy = store.busyMessage {
                ProgressView()
                    .controlSize(.small)
                Text(busy)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if !store.dockerVersion.isEmpty {
                Text("v\(store.dockerVersion)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help(t("plugin.common.refresh"))
        }
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            tabButton(.containers, title: t("plugin.docker.tab.containers"), icon: "cube.box")
            tabButton(.compose, title: t("plugin.docker.tab.compose"), icon: "square.stack.3d.up")
            Spacer()
            Text("\(store.runningCount)/\(store.totalCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func tabButton(_ tab: DockerTab, title: String, icon: String) -> some View {
        Button {
            store.selectedTab = tab
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(store.selectedTab == tab ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
    }

    private var missingDocker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t("plugin.docker.error.missing"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        Group {
            if let err = store.lastError, !err.isEmpty {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .textSelection(.enabled)
            } else if let path = store.lastExportPath {
                Text(t("plugin.docker.export.saved") + " " + path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: Containers

    private var containersPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                PluginPasteableTextField(
                    placeholder: t("plugin.docker.search"),
                    text: $store.containerFilter
                )
                .frame(minHeight: 22)
                Toggle(t("plugin.docker.show_all"), isOn: $store.showAllContainers)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )

            HStack(alignment: .top, spacing: 10) {
                containerList
                    .frame(width: 240)
                containerDetail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var containerList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if store.filteredContainers.isEmpty {
                    Text(t("plugin.docker.containers.empty"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
                ForEach(store.filteredContainers) { c in
                    Button {
                        store.selectedContainerID = c.id
                    } label: {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(stateColor(c))
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.name)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                Text(c.image)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(store.selectedContainerID == c.id
                                      ? Color.accentColor.opacity(0.15)
                                      : Color.primary.opacity(0.04))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var containerDetail: some View {
        Group {
            if let c = store.selectedContainer {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(c.name)
                            .font(.title3.weight(.semibold))
                        detailRow(t("plugin.docker.field.id"), c.shortID)
                        detailRow(t("plugin.docker.field.image"), c.image)
                        detailRow(t("plugin.docker.field.state"), c.stateLabel)
                        detailRow(t("plugin.docker.field.status"), c.status)
                        if !c.ports.isEmpty {
                            detailRow(t("plugin.docker.field.ports"), c.ports)
                        }
                        if let project = c.composeProject {
                            detailRow(t("plugin.docker.field.compose"), project)
                        }

                        Text(t("plugin.docker.restart_policy"))
                            .font(.caption.weight(.semibold))
                        Picker("", selection: Binding(
                            get: { DockerRestartPolicy.parse(c.restartPolicy) },
                            set: { policy in
                                Task { await store.setRestartPolicy(c, policy: policy) }
                            }
                        )) {
                            ForEach(DockerRestartPolicy.allCases) { p in
                                Text(p.title).tag(p)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 200, alignment: .leading)

                        Text(t("plugin.docker.actions"))
                            .font(.caption.weight(.semibold))
                            .padding(.top, 4)

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 6)], spacing: 6) {
                            actionBtn(t("plugin.docker.action.start"), "play.fill", enabled: !c.isRunning || c.isPaused) {
                                if c.isPaused {
                                    await store.unpauseContainer(c)
                                } else {
                                    await store.startContainer(c)
                                }
                            }
                            actionBtn(t("plugin.docker.action.stop"), "stop.fill", enabled: c.isRunning || c.isPaused) {
                                await store.stopContainer(c)
                            }
                            actionBtn(t("plugin.docker.action.restart"), "arrow.clockwise", enabled: true) {
                                await store.restartContainer(c)
                            }
                            actionBtn(
                                c.isPaused ? t("plugin.docker.action.unpause") : t("plugin.docker.action.pause"),
                                c.isPaused ? "play.fill" : "pause.fill",
                                enabled: c.isRunning || c.isPaused
                            ) {
                                if c.isPaused {
                                    await store.unpauseContainer(c)
                                } else {
                                    await store.pauseContainer(c)
                                }
                            }
                            actionBtn(t("plugin.docker.action.kill"), "xmark.octagon.fill", enabled: c.isRunning || c.isPaused) {
                                await store.killContainer(c)
                            }
                            actionBtn(t("plugin.docker.action.export"), "square.and.arrow.up", enabled: true) {
                                await store.exportContainer(c)
                            }
                            actionBtn(t("plugin.docker.action.logs"), "doc.text", enabled: true) {
                                await store.fetchLogs(c)
                                showLogs = true
                            }
                            actionBtn(t("plugin.docker.action.remove"), "trash", enabled: true) {
                                await store.removeContainer(c, force: false)
                            }
                            actionBtn(t("plugin.docker.action.remove_force"), "trash.fill", enabled: true) {
                                await store.removeContainer(c, force: true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(t("plugin.docker.containers.select"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    // MARK: Compose

    private var composePane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(t("plugin.docker.compose.projects"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    editingProjectID = nil
                    editName = ""
                    editYAML = Self.defaultComposeYAML
                    editDockerfile = ""
                    editNotes = ""
                    showNewProject = true
                } label: {
                    Label(t("plugin.docker.compose.new"), systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            HStack(alignment: .top, spacing: 10) {
                projectList
                    .frame(width: 200)
                projectDetail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var projectList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if store.projects.isEmpty {
                    Text(t("plugin.docker.compose.empty"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
                ForEach(store.projects) { p in
                    Button {
                        store.selectedProjectID = p.id
                        Task { await store.refreshComposeStatus(p) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: p.hasDockerfile ? "doc.badge.gearshape" : "doc.text")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                if p.hasDockerfile {
                                    Text("Dockerfile")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(store.selectedProjectID == p.id
                                      ? Color.accentColor.opacity(0.15)
                                      : Color.primary.opacity(0.04))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var projectDetail: some View {
        Group {
            if let p = store.selectedProject {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(p.name)
                                .font(.title3.weight(.semibold))
                            Spacer()
                            Button {
                                editingProjectID = p.id
                                editName = p.name
                                editYAML = p.composeYAML
                                editDockerfile = p.dockerfile ?? ""
                                editNotes = p.notes
                                showNewProject = true
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.plain)
                            .help(t("plugin.docker.compose.edit"))
                        }

                        if !p.notes.isEmpty {
                            Text(p.notes)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text(t("plugin.docker.compose.actions"))
                            .font(.caption.weight(.semibold))

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 6)], spacing: 6) {
                            actionBtn(t("plugin.docker.compose.up"), "play.fill", enabled: store.composeAvailable) {
                                await store.composeUp(p, build: false)
                            }
                            actionBtn(t("plugin.docker.compose.up_build"), "hammer.fill", enabled: store.composeAvailable) {
                                await store.composeUp(p, build: true)
                            }
                            actionBtn(t("plugin.docker.compose.stop"), "pause.fill", enabled: store.composeAvailable) {
                                await store.composeStop(p)
                            }
                            actionBtn(t("plugin.docker.compose.start"), "play", enabled: store.composeAvailable) {
                                await store.composeStart(p)
                            }
                            actionBtn(t("plugin.docker.compose.down"), "stop.fill", enabled: store.composeAvailable) {
                                await store.composeDown(p, volumes: false)
                            }
                            actionBtn(t("plugin.docker.compose.down_v"), "trash", enabled: store.composeAvailable) {
                                await store.composeDown(p, volumes: true)
                            }
                            actionBtn(t("plugin.docker.compose.pull"), "arrow.down.circle", enabled: store.composeAvailable) {
                                await store.composePull(p)
                            }
                            actionBtn(t("plugin.docker.compose.folder"), "folder", enabled: true) {
                                store.openProjectFolder(p)
                            }
                            actionBtn(t("plugin.docker.compose.delete"), "trash.fill", enabled: true) {
                                store.deleteProject(p)
                            }
                        }

                        if let status = store.composeStatus {
                            Text(t("plugin.docker.compose.status"))
                                .font(.caption.weight(.semibold))
                                .padding(.top, 4)
                            if status.services.isEmpty {
                                Text(t("plugin.docker.compose.status.empty"))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(status.services) { s in
                                    HStack {
                                        Text(s.name)
                                            .font(.caption)
                                        Spacer()
                                        Text(s.status)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }

                        DisclosureGroup(t("plugin.docker.compose.yaml_preview")) {
                            Text(p.composeYAML)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let docker = p.dockerfile, !docker.isEmpty {
                            DisclosureGroup("Dockerfile") {
                                Text(docker)
                                    .font(.system(.caption2, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(t("plugin.docker.compose.select"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    // MARK: Sheets

    private var projectEditorSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editingProjectID == nil
                 ? t("plugin.docker.compose.new")
                 : t("plugin.docker.compose.edit"))
                .font(.headline)

            Text(t("plugin.docker.compose.name"))
                .font(.caption.weight(.semibold))
            PluginPasteableTextField(
                placeholder: t("plugin.docker.compose.name_placeholder"),
                text: $editName
            )
            .frame(minHeight: 24)

            Text(t("plugin.docker.compose.yaml"))
                .font(.caption.weight(.semibold))
            TextEditor(text: $editYAML)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 160)
                .border(Color.primary.opacity(0.15))

            Text(t("plugin.docker.compose.dockerfile"))
                .font(.caption.weight(.semibold))
            Text(t("plugin.docker.compose.dockerfile_hint"))
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextEditor(text: $editDockerfile)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 100)
                .border(Color.primary.opacity(0.15))

            Text(t("plugin.docker.compose.notes"))
                .font(.caption.weight(.semibold))
            PluginPasteableTextField(
                placeholder: t("plugin.docker.compose.notes_placeholder"),
                text: $editNotes
            )
            .frame(minHeight: 24)

            HStack {
                Spacer()
                Button(t("plugin.docker.cancel")) {
                    showNewProject = false
                }
                .keyboardShortcut(.cancelAction)
                Button(t("plugin.common.save")) {
                    _ = store.saveProject(
                        id: editingProjectID,
                        name: editName,
                        composeYAML: editYAML,
                        dockerfile: editDockerfile,
                        notes: editNotes
                    )
                    if store.lastError == nil {
                        showNewProject = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 520, height: 560)
    }

    private var logsSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(t("plugin.docker.logs.title"))
                    .font(.headline)
                Spacer()
                Button(t("plugin.docker.close")) {
                    showLogs = false
                }
            }
            ScrollView {
                Text(store.lastLogs.isEmpty ? t("plugin.docker.logs.empty") : store.lastLogs)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(width: 520, height: 420)
    }

    // MARK: Helpers

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func actionBtn(
        _ title: String,
        _ icon: String,
        enabled: Bool,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            Label(title, systemImage: icon)
                .font(.caption2)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!enabled || store.busyMessage != nil)
    }

    private func stateColor(_ c: DockerContainer) -> Color {
        if c.isPaused { return .orange }
        if c.isRunning { return .green }
        if c.isExited { return .secondary }
        return .yellow
    }

    private static let defaultComposeYAML = """
    services:
      app:
        image: nginx:alpine
        ports:
          - "8080:80"
    """
}
