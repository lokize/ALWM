import AppKit
import SwiftUI

struct NotepadRootView: View {
    @ObservedObject var store: NotesStore
    var onClose: () -> Void

    @State private var newCategoryName = ""
    @State private var showNewCategory = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 228)
                .background(Color.primary.opacity(0.045))

            Divider().opacity(0.5)

            VStack(spacing: 0) {
                topChrome
                Divider().opacity(0.5)
                NotepadEditorView(store: store)
            }
        }
        .background(
            VisualEffectBackground(material: .underWindowBackground, blendingMode: .withinWindow)
                .opacity(0.98)
        )
    }

    private var topChrome: some View {
        HStack(spacing: 10) {
            tabBar
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .help(L10n.t("notepad.close"))
            .padding(.trailing, 10)
        }
        .padding(.leading, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.03))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "note.text")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 26, height: 26)
                    .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.t("pane.notepad"))
                        .font(.subheadline.weight(.semibold))
                    Text(L10n.t("notepad.categories"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 10)

            sectionLabel(L10n.t("notepad.categories"))

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(store.index.categories.sorted(by: { $0.sortOrder < $1.sortOrder })) { cat in
                        NotepadCategoryRow(
                            name: cat.name,
                            isActive: store.selectedCategoryID == cat.id,
                            onSelect: { store.selectedCategoryID = cat.id }
                        )
                    }
                }
                .padding(.horizontal, 8)
            }
            .frame(maxHeight: 110)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
                TextField(L10n.t("notepad.search"), text: $store.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.callout)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            sectionLabel(L10n.t("notepad.pages"))

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(store.filteredSummaries()) { summary in
                        NotepadPageRow(
                            summary: summary,
                            isActive: store.activePageID == summary.id,
                            onOpen: { store.openTab(summary.id) },
                            onDelete: { store.deletePage(summary.id) }
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            }

            Divider().opacity(0.5)

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    showNewCategory.toggle()
                } label: {
                    Label(L10n.t("notepad.new_category"), systemImage: "folder.badge.plus")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                if showNewCategory {
                    HStack(spacing: 6) {
                        TextField(L10n.t("notepad.category_name"), text: $newCategoryName)
                            .textFieldStyle(.roundedBorder)
                        Button(L10n.t("common.add")) {
                            let name = newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !name.isEmpty else { return }
                            store.addCategory(name: name)
                            newCategoryName = ""
                            showNewCategory = false
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }
            .padding(10)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.bottom, 4)
            .padding(.top, 2)
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(store.openTabIDs, id: \.self) { tabID in
                    if let summary = store.index.pages.first(where: { $0.id == tabID }) {
                        let active = store.activePageID == tabID
                        HStack(spacing: 6) {
                            Button {
                                store.activePageID = tabID
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "doc.text")
                                        .font(.system(size: 9, weight: .semibold))
                                    Text(summary.title.isEmpty ? L10n.t("notepad.untitled") : summary.title)
                                        .lineLimit(1)
                                        .font(.caption.weight(active ? .semibold : .regular))
                                }
                            }
                            .buttonStyle(.plain)

                            Button {
                                store.closeTab(tabID)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 14, height: 14)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(active ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(active ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
                        )
                    }
                }

                Button {
                    _ = store.createPage(categoryID: store.selectedCategoryID)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.t("notepad.new_page"))
            }
            .padding(.vertical, 4)
        }
    }
}

private struct NotepadCategoryRow: View {
    let name: String
    let isActive: Bool
    let onSelect: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: isActive ? "folder.fill" : "folder")
                    .font(.caption)
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                Text(name)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(rowFill)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }

    private var rowFill: Color {
        if isActive { return Color.accentColor.opacity(0.16) }
        if hovered { return Color.primary.opacity(0.10) }
        return Color.clear
    }
}

private struct NotepadPageRow: View {
    let summary: NotePageSummary
    let isActive: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isActive ? "doc.text.fill" : "doc.text")
                    .font(.caption)
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.title.isEmpty ? L10n.t("notepad.untitled") : summary.title)
                        .lineLimit(1)
                        .font(.callout.weight(isActive ? .semibold : .regular))
                        .foregroundStyle(.primary)
                    Text(summary.updatedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(rowFill)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .contextMenu {
            Button(L10n.t("notepad.delete"), role: .destructive, action: onDelete)
        }
    }

    private var rowFill: Color {
        if isActive { return Color.accentColor.opacity(0.16) }
        if hovered { return Color.primary.opacity(0.10) }
        return Color.clear
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
