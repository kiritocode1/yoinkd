import SwiftUI
import YoinksCore

@MainActor
struct AddLinkView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var queue: DownloadQueue
    let onEnqueued: () -> Void
    @State private var input = ""
    @State private var errorMessage: String?
    @State private var isAdding = false
    @State private var isChecking = false
    @State private var media: SourceMedia?
    @State private var kind = MediaKind.video
    @State private var formatID = ""
    @State private var checkTask: Task<Void, Never>?
    @State private var checkID = UUID()
    @FocusState private var isLinkFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Paste a video or audio link", text: $input)
                        .accessibilityLabel("Media link")
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($isLinkFocused)
                        .submitLabel(.go)
                        .disabled(isAdding)
                        .onChange(of: input) { _, _ in resetInspection() }
                        .onSubmit { performAction() }
                    PasteButton(payloadType: String.self) { values in
                        if let value = values.first { input = value; isLinkFocused = true }
                    }
                    .disabled(isAdding)
                } header: {
                    Text("Link")
                } footer: {
                    if media == nil { Text("YouTube, Instagram, X, and other supported sites. Direct file links also work.") }
                }
                if isChecking {
                    Section { HStack(spacing: 12) { ProgressView(); Text("Checking source") } }
                }
                if let media { formatSections(media) }
                if let errorMessage {
                    Section { Label(errorMessage, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
                }
                if !queue.isReady {
                    Section { Text(queue.restoreError ?? "Opening downloads...").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Add link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isAdding) }
                ToolbarItem(placement: .confirmationAction) {
                    if isAdding || isChecking { ProgressView() } else {
                        Button(media != nil || isDirectFile ? "Download" : "Check link") { performAction() }
                            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !queue.isReady)
                    }
                }
            }
            .interactiveDismissDisabled(isAdding)
            .task { isLinkFocused = true }
            .onDisappear { checkTask?.cancel() }
        }
    }

    @ViewBuilder
    private func formatSections(_ media: SourceMedia) -> some View {
        Section {
            if let thumbnail = media.thumbnailURL, thumbnail.scheme == "https" {
                AsyncImage(url: thumbnail) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Image(systemName: "play.rectangle").font(.largeTitle).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 140)
                }
                .frame(maxHeight: 220)
                .accessibilityHidden(true)
            }
            Text(media.title).font(.headline).lineLimit(3)
            if let uploader = media.uploader, !uploader.isEmpty {
                Text(uploader).foregroundStyle(.secondary)
            }
            LabeledContent("Source", value: media.platformLabel)
            if let duration = media.duration { LabeledContent("Duration", value: MediaPresentation.duration(duration)) }
        }
        Section {
            if !media.videoFormats.isEmpty, !media.audioFormats.isEmpty {
                Picker("Download", selection: $kind) {
                    Text("Video").tag(MediaKind.video)
                    Text("Audio").tag(MediaKind.audio)
                }
                .pickerStyle(.segmented)
                .onChange(of: kind) { _, _ in formatID = "" }
            }
            Picker("Quality", selection: $formatID) {
                Text("Best available").tag("")
                ForEach(kind == .video ? media.videoChoices : Array(media.audioFormats.reversed())) { format in
                    Text(formatLabel(format)).tag(format.id)
                }
            }
            .pickerStyle(.navigationLink)
            if let size = estimatedSize(media) {
                LabeledContent("Source download", value: "About \(MediaPresentation.bytes(size))")
            }
        } header: {
            Text(kind == .video ? "Video" : "Audio")
        } footer: {
            if kind == .video {
                Text("Video saves as MP4 at the selected resolution. Some formats need conversion for iPhone playback.")
            } else {
                Text("Audio keeps its playable source format, or saves as FLAC to preserve source quality. Conversion can change the file size.")
            }
        }
    }

    private func formatLabel(_ format: SourceFormat) -> String {
        guard kind == .audio else { return format.qualityLabel }
        let rawCodec = (format.audioCodec ?? "").lowercased()
        let codec = rawCodec.hasPrefix("mp4a") || rawCodec == "aac" ? "AAC" :
            (rawCodec == "unknown" || rawCodec == "none" || rawCodec.isEmpty ? format.container.uppercased() : rawCodec.uppercased())
        let language = format.language.flatMap { Locale.current.localizedString(forLanguageCode: $0) }
        return format.audioQualityLabel + " · " + codec + (language.map { " · \($0)" } ?? "")
    }

    private func estimatedSize(_ media: SourceMedia) -> Int64? {
        let formats = kind == .video ? media.videoFormats : media.audioFormats
        let selected = formatID.isEmpty ? formats.last : formats.first { $0.id == formatID }
        guard let selected, let size = selected.byteCount else { return nil }
        if kind == .video, !selected.containsAudio {
            guard let audio = media.audioFormats.last?.byteCount else { return nil }
            return size + audio
        }
        return size
    }

    private var isDirectFile: Bool {
        guard let link = try? MediaLink(input) else { return false }
        return ["mp4", "mov", "m4v", "mp3", "m4a", "aac", "wav", "flac", "aiff", "aif", "caf"].contains(link.url.pathExtension.lowercased())
    }

    private func resetInspection() {
        checkID = UUID()
        checkTask?.cancel()
        isChecking = false
        media = nil
        errorMessage = nil
        formatID = ""
    }

    private func performAction() {
        guard !isAdding, !isChecking, queue.isReady else { return }
        let link: MediaLink
        do { link = try MediaLink(input) } catch { errorMessage = error.userMessage; return }
        isLinkFocused = false
        if media == nil, !isDirectFile {
            isChecking = true
            errorMessage = nil
            let requestID = UUID()
            checkID = requestID
            checkTask = Task {
                do {
                    let result = try await NativeExtractor.inspect(link)
                    guard !Task.isCancelled, checkID == requestID else { return }
                    media = result
                    kind = result.videoFormats.isEmpty ? .audio : .video
                    formatID = ""
                } catch {
                    guard !Task.isCancelled, checkID == requestID else { return }
                    errorMessage = error.localizedDescription
                }
                if checkID == requestID { isChecking = false }
            }
            return
        }
        isAdding = true
        Task {
            do {
                if let media {
                    let selection = try media.selection(kind: kind, formatID: formatID.isEmpty ? nil : formatID)
                    try await queue.enqueue(media, selection: selection)
                } else { try await queue.enqueue(link) }
                onEnqueued()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isAdding = false
            }
        }
    }
}

private extension MediaLinkError {
    var userMessage: String {
        switch self {
        case .empty: "Enter a link."
        case .invalidURL: "Enter a full HTTPS link."
        case .httpsRequired: "Use an HTTPS link."
        case .credentialsNotAllowed: "Use a link without a username or password."
        }
    }
}
