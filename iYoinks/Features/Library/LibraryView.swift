import CoreData
import SwiftUI
import YoinksCore

private enum LibraryFilter: String, CaseIterable { case all = "All", video = "Video", audio = "Audio" }
private enum LibrarySort: String, CaseIterable { case newest = "Newest first", title = "Title" }

@MainActor
struct LibraryView: View {
    @EnvironmentObject private var library: MediaLibrary
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \LibraryItem.addedAt, ascending: false)]) private var items: FetchedResults<LibraryItem>
    let onImport: () -> Void
    let onAddLink: () -> Void
    @State private var search = ""
    @State private var filter = LibraryFilter.all
    @State private var sort = LibrarySort.newest
    @State private var renameItem: LibraryItem?
    @State private var renameText = ""
    @State private var showsRename = false
    @State private var deleteItem: LibraryItem?

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
    }

    private var visibleItems: [LibraryItem] {
        let filtered = items.filter {
            (filter == .all || $0.mediaKind?.rawValue == filter.rawValue.lowercased()) &&
            (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search))
        }
        return sort == .title ? filtered.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } : filtered
    }

    private var summary: String? {
        guard !items.isEmpty else { return nil }
        return "\(items.count) \(items.count == 1 ? "file" : "files"), \(MediaPresentation.bytes(library.storedBytes))"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let summary {
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 12)
                }
                if let progress = library.importProgress {
                    HStack(spacing: 12) {
                        ProgressView()
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Importing \(progress.name)").font(.subheadline).lineLimit(2)
                            Text("\(progress.completed) of \(progress.total) files processed").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 20).padding(.bottom, 16)
                    .accessibilityElement(children: .combine)
                }
                if items.isEmpty {
                    ContentUnavailableView {
                        AppBrand.image(for: colorScheme).resizable().scaledToFit().frame(width: 80, height: 80)
                        Text("No saved media")
                    } description: {
                        Text("Import a video or audio file, or add a direct media link.")
                    } actions: {
                        Button("Import files", systemImage: "folder") { onImport() }
                            .buttonStyle(AppPrimaryButtonStyle()).disabled(library.importProgress != nil)
                        Button("Add link", systemImage: "link") { onAddLink() }.buttonStyle(AppSecondaryButtonStyle())
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            AppPillPicker(label: "Media type", options: LibraryFilter.allCases, selection: $filter, title: { $0.rawValue })
                            if visibleItems.isEmpty {
                                ContentUnavailableView {
                                    Label("No matching media", systemImage: "magnifyingglass")
                                } description: {
                                    Text("Try another name or media type.")
                                }
                            } else {
                                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                                    ForEach(visibleItems, id: \.objectID) { item in
                                        VStack(alignment: .leading, spacing: 0) {
                                            NavigationLink { MediaDetailView(item: item) } label: { LibraryRow(item: item) }
                                                .buttonStyle(.plain)
                                            HStack(alignment: .top, spacing: 4) {
                                                Text(metadata(item)).font(.caption).foregroundStyle(.secondary)
                                                    .fixedSize(horizontal: false, vertical: true)
                                                    .padding(.top, 6)
                                                Spacer(minLength: 0)
                                                Menu { itemActions(item) } label: {
                                                    Image(systemName: "ellipsis")
                                                        .padding(.top, 6)
                                                        .frame(width: 44, height: 44, alignment: .top)
                                                        .contentShape(Rectangle())
                                                }
                                                .buttonStyle(.borderless)
                                                .foregroundStyle(.secondary)
                                                .accessibilityLabel("Actions for \(item.title)")
                                            }
                                        }
                                        .contextMenu { itemActions(item) }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 20).padding(.bottom, 24)
                    }
                }
            }
            .background(AppStyle.background)
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search saved media")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !items.isEmpty {
                        Menu {
                            Picker("Sort by", selection: $sort) {
                                ForEach(LibrarySort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                        } label: { Image(systemName: "line.3.horizontal.decrease").frame(minWidth: 44, minHeight: 44) }
                        .accessibilityLabel("Sort library")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Import files", systemImage: "folder") { onImport() }.disabled(library.importProgress != nil)
                        Button("Add link", systemImage: "link") { onAddLink() }
                    } label: { Image(systemName: "plus").frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel("Add media")
                }
            }
            .alert("Rename media", isPresented: $showsRename) {
                TextField("Title", text: $renameText)
                Button("Save") {
                    guard let item = renameItem else { return }
                    do { try library.rename(item, to: renameText) } catch { library.errorMessage = error.localizedDescription }
                    renameItem = nil
                }.disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) { renameItem = nil }
            }
            .confirmationDialog("Delete this file?", isPresented: Binding(get: { deleteItem != nil }, set: { if !$0 { deleteItem = nil } }), titleVisibility: .visible) {
                Button("Delete file", role: .destructive) {
                    guard let item = deleteItem else { return }
                    deleteItem = nil
                    Task {
                        do { try await library.delete(item) } catch { library.errorMessage = error.localizedDescription }
                    }
                }
            } message: { Text("This removes the saved copy from iYoinks.") }
        }
    }

    private func metadata(_ item: LibraryItem) -> String {
        let kind = item.mediaKind == .audio ? "Audio" : "Video"
        guard let details = library.details[item.id] else { return kind }
        return "\(kind) · \(MediaPresentation.bytes(details.byteCount))"
    }

    @ViewBuilder
    private func itemActions(_ item: LibraryItem) -> some View {
        if let media = sharedMedia(item) {
            ShareLink(item: media, preview: SharePreview(item.title)) {
                Label("Share file", systemImage: "square.and.arrow.up")
            }
        }
        Button("Rename", systemImage: "pencil") {
            renameItem = item; renameText = item.title; showsRename = true
        }
        Button("Delete file", systemImage: "trash", role: .destructive) { deleteItem = item }
    }

    private func sharedMedia(_ item: LibraryItem) -> SharedMedia? {
        guard let file = try? MediaFileName(item.relativeFileName) else { return nil }
        return SharedMedia(url: library.storage.files.mediaURL(file), title: item.title, kind: item.mediaKind ?? .video)
    }
}
