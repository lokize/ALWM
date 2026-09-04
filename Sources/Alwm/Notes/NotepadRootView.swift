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
                .frame(width: 200)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.55))

            Divider()

            VStack(spacing: 0) {
                tabBar
                Divider()
                NotepadEditorView(store: store)
            }
        }
        .background(
            VisualEffectBackground(material: .underWindowBackground, blendingMode: .withinWindow)
                .opacity(0.98)
        )
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 8) {
                Button {
                    _ = store.createPage(categoryID: store.selectedCategoryID)
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help(L10n.t("notepad.new_page"))

                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .help(L10n.t("notepad.close"))
            }
            .padding(10)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.t("notepad.categories"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 6)

            List(selection: $store.selectedCategoryID) {
                ForEach(store.index.categories.sorted(by: { $0.sortOrder < $1.sortOrder })) { cat in
                    Text(cat.name).tag(Optional(cat.id))
                }
            }
            .listStyle(.sidebar)
            .frame(maxHeight: 120)

            HStack {
                TextField(L10n.t("notepad.search"), text: $store.searchQuery)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)

            Text(L10n.t("notepad.pages"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)

            List {
                ForEach(store.filteredSummaries()) { summary in
                    Button {
                        store.openTab(summary.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(summary.title)
                                .lineLimit(1)
                            Text(summary.updatedAt, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(L10n.t("notepad.delete"), role: .destructive) {
                            store.deletePage(summary.id)
                        }
                    }
                }
            }
            .listStyle(.plain)

            Divider()

            HStack {
                Button {
                    showNewCategory.toggle()
                } label: {
                    Label(L10n.t("notepad.new_category"), systemImage: "folder.badge.plus")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
            .padding(10)

            if showNewCategory {
                HStack {
                    TextField(L10n.t("notepad.category_name"), text: $newCategoryName)
                        .textFieldStyle(.roundedBorder)
                    Button(L10n.t("common.add")) {
                        let name = newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else { return }
                        store.addCategory(name: name)
                        newCategoryName = ""
                        showNewCategory = false
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(store.openTabIDs, id: \.self) { tabID in
                    if let summary = store.index.pages.first(where: { $0.id == tabID }) {
                        HStack(spacing: 4) {
                            Button {
                                store.activePageID = tabID
                            } label: {
                                Text(summary.title)
                                    .lineLimit(1)
                                    .font(.caption.weight(store.activePageID == tabID ? .semibold : .regular))
                            }
                            .buttonStyle(.plain)

                            Button {
                                store.closeTab(tabID)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            store.activePageID == tabID
                                ? Color.accentColor.opacity(0.18)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
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
