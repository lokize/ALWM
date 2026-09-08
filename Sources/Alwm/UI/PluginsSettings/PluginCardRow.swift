import AppKit
import SwiftUI
import AlwmPluginAPI

/// Merged remote + local plugin row for Settings → Plugins.

// MARK: - Plugin card row

struct PluginCardRow: View {
    @ObservedObject var loc = LocalizationController.shared
    let item: SettingsPluginItem
    var onToggle: (Bool) -> Void
    var onDownload: () -> Void
    var onUninstall: () -> Void
    var onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                previewThumb
                    .frame(width: 64, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(item.manifest.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text("v\(item.manifest.version)")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    HStack(spacing: 6) {
                        Text(L10n.t(item.manifest.resolvedCategory.l10nKey))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                        PluginAuthorLabel(author: item.manifest.author, style: .card)
                    }
                }
                Spacer(minLength: 0)

                if item.isEnabled {
                    Text(L10n.t("plugins.badge.active"))
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.green.opacity(0.22))
                        .foregroundStyle(Color.green)
                        .clipShape(Capsule())
                } else if item.isInstalled {
                    Text(L10n.t("plugins.badge.installed"))
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.18))
                        .foregroundStyle(.secondary)
                        .clipShape(Capsule())
                }
            }

            if !catalogSummary.isEmpty {
                Text(catalogSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                if item.isBusy {
                    ProgressView().controlSize(.small)
                } else if item.isInstalled {
                    Toggle(L10n.t("plugins.enable"), isOn: Binding(
                        get: { item.isEnabled },
                        set: {
                            onToggle($0)
                            NSApp.keyWindow?.makeFirstResponder(nil)
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .focusable(false)
                    .focusEffectDisabled()
                    .help(L10n.t("plugins.enable"))
                }

                Spacer(minLength: 0)

                if item.isBusy {
                    EmptyView()
                } else if !item.isInstalled {
                    Button(L10n.t("plugins.install")) {
                        onDownload()
                        NSApp.keyWindow?.makeFirstResponder(nil)
                    }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .focusable(false)
                        .focusEffectDisabled()
                } else {
                    Button(L10n.t("plugins.uninstall")) {
                        onUninstall()
                        NSApp.keyWindow?.makeFirstResponder(nil)
                    }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .focusable(false)
                        .focusEffectDisabled()
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    item.isEnabled ? Color.green.opacity(0.35) : Color.primary.opacity(0.06),
                    lineWidth: item.isEnabled ? 1.5 : 1
                )
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }

    var catalogSummary: String {
        _ = loc.revision
        return PluginCatalogCopy.summary(id: item.id, fallback: item.manifest.summary)
    }

    @ViewBuilder
    var previewThumb: some View {
        if let url = item.discovered?.previewURL,
           let img = NSImage(contentsOf: url) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color.secondary.opacity(0.12)
                Image(systemName: "puzzlepiece.extension")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
