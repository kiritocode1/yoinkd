import SwiftUI
import YoinksCore

@MainActor
struct LibraryRow: View {
    @EnvironmentObject private var library: MediaLibrary
    @ObservedObject var item: LibraryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MediaThumbnail(id: item.id, kind: item.mediaKind ?? .video)
                .aspectRatio(1.5, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: AppStyle.cornerRadius))
                .overlay(alignment: .bottomLeading) {
                    if let details = library.details[item.id] {
                        Text(MediaPresentation.duration(details.duration))
                            .font(.caption.weight(.medium)).monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 3)
                            .background(.black.opacity(0.65), in: Capsule())
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "play.fill").font(.caption)
                        .foregroundStyle(.white).padding(7)
                        .background(.black.opacity(0.65), in: Circle()).padding(6)
                }
                .accessibilityHidden(true)
            Text(item.title).font(.subheadline.weight(.medium)).lineLimit(2)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Open the saved media player")
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
                AppStyle.surface
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else {
                    Image(systemName: kind == .audio ? "waveform" : "play.rectangle")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(kind == .audio ? theme.accent : Color.secondary)
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
