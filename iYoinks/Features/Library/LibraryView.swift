import CoreData
import SwiftUI
import YoinksCore

private enum LibraryFilter: String, CaseIterable { case all = "All", video = "Video", audio = "Audio" }
private enum LibrarySort: String, CaseIterable {
    case newest = "Newest first", oldest = "Oldest first", title = "Title", reverseTitle = "Title, Z to A"
}
private enum LibraryDisplay: String, CaseIterable { case grid = "Grid", list = "List" }

@MainActor
struct LibraryView: View {
    @EnvironmentObject private var library: MediaLibrary
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \LibraryItem.addedAt, ascending: false)]) private var items: FetchedResults<LibraryItem>
    let onImport: () -> Void
    let onAddLink: () -> Void
    @State private var search = ""
    @State private var showsSearch = false
    @State private var filter = LibraryFilter.all
    @AppStorage("librarySort") private var sort = LibrarySort.newest
    @AppStorage("libraryDisplay") private var display = LibraryDisplay.grid
    @State private var renameItem: LibraryItem?
    @State private var renameText = ""
    @State private var showsRename = false
    @State private var deleteItem: LibraryItem?
    @State private var audioItem: LibraryItem?
    @State private var videoItem: LibraryItem?
    @State private var photosOutcome: PhotosSaver.Outcome?

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 280 : 160), spacing: 12)]
    }

    private var visibleItems: [LibraryItem] {
        let filtered = items.filter {
            (filter == .all || $0.mediaKind?.rawValue == filter.rawValue.lowercased()) &&
            (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search))
        }
        switch sort {
        case .newest: return filtered
        case .oldest: return Array(filtered.reversed())
        case .title: return filtered.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .reverseTitle: return filtered.sorted { $0.title.localizedStandardCompare($1.title) == .orderedDescending }
        }
    }

    private var summary: String? {
        guard !items.isEmpty else { return nil }
        return "\(items.count) \(items.count == 1 ? "file" : "files"), \(MediaPresentation.bytes(library.storedBytes))"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !showsSearch, let summary {
                    Text(summary).font(AppTypography.font(.subheadline)).foregroundStyle(theme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20).padding(.top, 8)
                }
                if let progress = library.importProgress {
                    HStack(spacing: 12) {
                        ProgressView()
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Importing \(progress.name)").font(AppTypography.font(.subheadline)).lineLimit(2)
                            Text("\(progress.completed) of \(progress.total) files processed").font(AppTypography.font(.caption)).foregroundStyle(theme.secondaryText)
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
                        Text("Import a video or audio file, or add a direct media link.").foregroundStyle(theme.secondaryText)
                    } actions: {
                        Button("Import files", systemImage: "folder") { onImport() }
                            .buttonStyle(AppPrimaryButtonStyle()).disabled(library.importProgress != nil)
                        Button("yoink!", systemImage: "link") { onAddLink() }.buttonStyle(AppSecondaryButtonStyle())
                    }
                } else {
                    Picker("Media type", selection: $filter) {
                        ForEach(LibraryFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .appSegmentedControl()
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    if visibleItems.isEmpty {
                        ContentUnavailableView {
                            Label("No matching media", systemImage: "magnifyingglass")
                        } description: {
                            Text("Try another name or media type.").foregroundStyle(theme.secondaryText)
                        }
                    } else if display == .list {
                        List {
                            ForEach(visibleItems, id: \.objectID) { item in
                                Button { openMedia(item) } label: {
                                    LibraryRow(item: item, isList: true, metadata: metadata(item))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .contextMenu { itemActions(item) }
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
                                .listRowSeparatorTint(theme.separator)
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .scrollDismissesKeyboard(.interactively)
                    } else {
                        ScrollView {
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                                ForEach(visibleItems, id: \.objectID) { item in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Button { openMedia(item) } label: { LibraryRow(item: item) }
                                            .buttonStyle(.plain)
                                            .contextMenu { itemActions(item) }
                                        HStack(spacing: 8) {
                                            Text(metadata(item)).font(AppTypography.font(.caption)).foregroundStyle(theme.secondaryText)
                                                .fixedSize(horizontal: false, vertical: true)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            itemMenu(item)
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 20).padding(.bottom, 20)
                        }
                        .scrollDismissesKeyboard(.interactively)
                    }
                }
            }
            .foregroundStyle(theme.primaryText)
            .background(theme.background)
            .appTabContent(for: .library)
            .appNativeChrome()
            .navigationTitle(showsSearch ? "" : "Library")
            .toolbarTitleDisplayMode(.inlineLarge)
            .appToolbarSearch(text: $search, isPresented: $showsSearch, prompt: "Search saved media")
            .navigationDestination(item: $videoItem) { MediaDetailView(item: $0) }
            .sheet(item: $audioItem) { item in
                MediaDetailView(item: item)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .toolbar {
                if !showsSearch {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Picker("Sort by", selection: $sort) {
                                ForEach(LibrarySort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                            Picker("Display", selection: $display) {
                                ForEach(LibraryDisplay.allCases, id: \.self) { option in
                                    Label(option.rawValue, systemImage: option == .grid ? "square.grid.2x2" : "list.bullet").tag(option)
                                }
                            }
                        } label: {
                            SortIcon().stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                                .frame(width: 24, height: 24)
                        }
                        .accessibilityLabel("Sort and display")
                    }
                    if #available(iOS 26, *) { ToolbarSpacer(.fixed, placement: .topBarTrailing) }
                }
                if #available(iOS 26, *) {
                    DefaultToolbarItem(kind: .search, placement: .topBarTrailing)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Import files", systemImage: "folder") { onImport() }.disabled(library.importProgress != nil)
                        Button("yoink!", systemImage: "link") { onAddLink() }
                    } label: { Label("Add media", systemImage: "ellipsis") }
                    .labelStyle(.iconOnly)
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
            } message: { Text("This removes the saved copy from yoink'd.") }
            .alert(photosOutcome?.title ?? "", isPresented: Binding(get: { photosOutcome != nil }, set: { if !$0 { photosOutcome = nil } })) {
                Button("OK", role: .cancel) { photosOutcome = nil }
            } message: { Text(photosOutcome?.message ?? "") }
        }
    }

    private func openMedia(_ item: LibraryItem) {
        showsSearch = false
        if item.mediaKind == .audio { audioItem = item }
        else { videoItem = item }
    }

    private func metadata(_ item: LibraryItem) -> String {
        let kind = item.mediaKind == .audio ? "Audio" : "Video"
        guard let details = library.details[item.id] else { return kind }
        return "\(kind) · \(MediaPresentation.bytes(details.byteCount))"
    }

    private func itemMenu(_ item: LibraryItem) -> some View {
        Menu { itemActions(item) } label: { Label("Actions for \(item.title)", systemImage: "ellipsis") }
            .labelStyle(.iconOnly)
            .buttonStyle(AppCompactButtonStyle())
    }

    @ViewBuilder
    private func itemActions(_ item: LibraryItem) -> some View {
        if let media = sharedMedia(item) {
            ShareLink(item: media, preview: SharePreview(item.title)) {
                Label("Share file", systemImage: "square.and.arrow.up")
            }
        }
        if item.mediaKind != .audio, let media = sharedMedia(item) {
            Button("Save to Photos", systemImage: "photo.badge.plus") {
                Task { photosOutcome = await PhotosSaver.save(videoAt: media.url) }
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
