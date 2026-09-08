import AppKit
import SwiftUI
import AlwmPluginAPI

/// Merged remote + local plugin row for Settings → Plugins.

// MARK: - Remote plugin detail sheet

struct PluginRemoteDetailSheet: View {
    let item: SettingsPluginItem
    var onDownload: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.manifest.name).font(.title2.weight(.semibold))
                    HStack(spacing: 8) {
                        PluginAuthorLabel(author: item.manifest.author, style: .detail)
                        Text("v\(item.manifest.version)")
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(L10n.t("plugins.close")) { onClose() }
                    .keyboardShortcut(.cancelAction)
            }
            Text(PluginCatalogCopy.summary(id: item.id, fallback: item.manifest.summary))
                .foregroundStyle(.secondary)
            if item.isBusy {
                ProgressView().controlSize(.small)
            } else {
                Button(L10n.t("plugins.install")) { onDownload() }
                    .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 240)
    }
}
