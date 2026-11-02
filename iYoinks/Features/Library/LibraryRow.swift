import SwiftUI
import YoinksCore

@MainActor
struct LibraryRow: View {
    @EnvironmentObject private var library: MediaLibrary
    @ObservedObject var item: LibraryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            MediaThumbnail(id: item.id, kind: item.mediaKind ?? .video)
                .aspectRatio(1.5, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .bottomLeading) {
                    if let details = library.details[item.id] {
                        Text(MediaPresentation.duration(details.duration))
                            .font(.caption.weight(.medium)).monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(.black.opacity(0.65), in: Capsule())
                            .padding(8)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "play.fill").font(.caption)
                        .foregroundStyle(.white).padding(9)
                        .background(.black.opacity(0.65), in: Circle()).padding(8)
                }
                .accessibilityHidden(true)
            Text(item.title).font(.headline).lineLimit(2)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Text(item.mediaKind == .audio ? "Audio" : "Video")
                Spacer(minLength: 4)
                if let details = library.details[item.id] { Text(MediaPresentation.bytes(details.byteCount)) }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Open the saved media player")
    }
}

@MainActor
struct MediaThumbnail: View {
    @EnvironmentObject private var library: MediaLibrary
    let id: UUID
    let kind: MediaKind
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(uiColor: .secondarySystemBackground)
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else {
                    Image(systemName: kind == .audio ? "waveform" : "play.rectangle")
                        .font(.system(size: 36, weight: .light)).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityHidden(true)
        .task(id: id) {
            if let data = await library.storage.readThumbnail(id: id) { image = UIImage(data: data) }
        }
    }
}
