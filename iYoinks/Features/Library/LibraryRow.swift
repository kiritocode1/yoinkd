import SwiftUI
import YoinksCore

@MainActor
struct LibraryRow: View {
    @EnvironmentObject private var library: MediaLibrary
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var item: LibraryItem
    var isList = false
    var metadata: String? = nil

    var body: some View {
        Group {
            if isList && !dynamicTypeSize.isAccessibilitySize {
                HStack(spacing: 12) {
                    thumbnail.frame(width: 96)
                    titleAndMetadata
                }
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    thumbnail
                    titleAndMetadata
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Open the saved media player")
    }

    private var titleAndMetadata: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title).font(AppTypography.font(isList ? .body : .subheadline, weight: .medium))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .foregroundStyle(theme.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let metadata {
                Text(metadata).font(AppTypography.font(.subheadline)).foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var thumbnail: some View {
        MediaThumbnail(id: item.id, kind: item.mediaKind ?? .video)
                .aspectRatio(AppStyle.thumbnailRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: AppStyle.cornerRadius))
                .overlay(alignment: .bottomLeading) {
                    if let details = library.details[item.id] {
                        Text(MediaPresentation.duration(details.duration))
                            .font(AppTypography.font(.caption2, weight: .medium)).monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4).padding(.vertical, 2)
                            .background(.black.opacity(0.65), in: Capsule())
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "play.fill").font(.caption2)
                        .foregroundStyle(.white).padding(6)
                        .background(.black.opacity(0.65), in: Circle()).padding(6)
                }
                .accessibilityHidden(true)
    }
}

@MainActor
struct MediaThumbnail: View {
    @EnvironmentObject private var library: MediaLibrary
    @EnvironmentObject private var theme: AppTheme
    let id: UUID
    let kind: MediaKind
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                theme.controlBackground
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else {
                    Image(systemName: kind == .audio ? "waveform" : "play.rectangle")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(kind == .audio ? theme.accent : theme.secondaryText)
                }
            }
        }
        .accessibilityHidden(true)
        .task(id: id) {
            image = nil
            if let data = await library.storage.readThumbnail(id: id), !Task.isCancelled { image = UIImage(data: data) }
        }
    }
}
