import SwiftUI
import YoinksCore

@MainActor
struct AddLinkView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var queue: DownloadQueue
    @EnvironmentObject private var theme: AppTheme
    @EnvironmentObject private var library: MediaLibrary
    let onEnqueued: () -> Void
    @State private var input = ""
    @State private var errorMessage: String?
    @State private var isAdding = false
    @State private var isChecking = false
    @State private var media: SourceMedia?
    @State private var kind = MediaKind.video
    @State private var formatID = ""
    @State private var outputFormat = SourceOutputFormat.automatic
    @State private var availableOutputs: [SourceOutputFormat] = [.automatic]
    @State private var outputAvailabilityError: String?
    @State private var checkTask: Task<Void, Never>?
    @State private var checkID = UUID()
    @State private var linkControlSize = CGSize(width: 80, height: 44)
    @FocusState private var isLinkFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        linkInput
                        if let media {
                            formatSections(media)
                        }
                        if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            captureAction
                        }
                        if isChecking {
                            HStack(spacing: 12) { ProgressView(); Text("Checking source").font(AppTypography.font(.body)) }
                        }
                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.circle").font(AppTypography.font(.body)).foregroundStyle(.red)
                        }
                        if !queue.isReady {
                            Text(queue.restoreError ?? "Opening downloads...").font(AppTypography.font(.body)).foregroundStyle(theme.secondaryText)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .foregroundStyle(theme.primaryText, theme.secondaryText)
            .background(theme.background)
            .appNativeChrome()
            .navigationTitle("yoink!")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel Download") { dismiss() }.disabled(isAdding)
                }
            }
        }
        .interactiveDismissDisabled(isAdding)
        .task { isLinkFocused = true }
        .task(id: kind) {
            do {
                let formats = try await NativeExtractor.availableOutputFormats(for: kind)
                guard !Task.isCancelled else { return }
                availableOutputs = formats
                outputAvailabilityError = nil
                if !formats.contains(outputFormat) { outputFormat = .automatic }
            } catch {
                guard !Task.isCancelled else { return }
                availableOutputs = [.automatic]
                outputFormat = .automatic
                outputAvailabilityError = error.localizedDescription
            }
        }
        .onDisappear {
            checkTask?.cancel()
            theme.endPreview()
        }
    }

    private var linkInput: some View {
        HStack(spacing: 10) {
            Image(systemName: "link").foregroundStyle(theme.secondaryText).accessibilityHidden(true)
            linkField
                .mask {
                    HStack(spacing: 0) {
                        Rectangle().fill(.black)
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: isLinkFocused && !input.isEmpty ? 0 : 16)
                    }
                }
                .padding(.trailing, linkControlSize.width + 8)
        }
        .overlay(alignment: .trailing) {
            linkControl
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { geometry in
                    geometry.size
                } action: { size in
                    linkControlSize = size
                }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(theme.controlBackground, in: RoundedRectangle(cornerRadius: 16))
    }

    private var captureAction: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            if isAdding {
                ProgressView().accessibilityLabel("Adding download")
            }
            Button(media != nil || isDirectFile ? "yoink!" : "Check link") { performAction() }
                .buttonStyle(AppSecondaryButtonStyle())
                .disabled(isAdding || isChecking || !queue.isReady || library.isChangingFolder)
        }
    }

    private var linkField: some View {
        TextField("Paste a video or audio link", text: $input)
            .font(AppTypography.font(.body))
            .accessibilityLabel("Media link")
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($isLinkFocused)
            .submitLabel(.go)
            .frame(minWidth: 0, minHeight: max(44, linkControlSize.height))
            .disabled(isAdding)
            .onChange(of: input) { _, _ in resetInspection() }
            .onSubmit { performAction() }
    }

    @ViewBuilder
    private var linkControl: some View {
        if input.isEmpty {
            pasteControl
        } else {
            Button("Clear link", systemImage: "xmark") {
                input = ""
                isLinkFocused = true
            }
            .labelStyle(.iconOnly)
            .buttonStyle(AppCompactButtonStyle())
            .frame(minWidth: 44, minHeight: 44)
            .disabled(isAdding)
        }
    }

    private var pasteControl: some View {
        PasteButton(payloadType: String.self) { values in
            if let value = values.first { input = value; isLinkFocused = true }
        }
        .buttonBorderShape(.capsule)
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .labelStyle(.titleOnly)
        .frame(minWidth: 44, minHeight: 44)
        .disabled(isAdding)
    }

    private func formatSections(_ media: SourceMedia) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                GeometryReader { geometry in
                    ZStack {
                        theme.controlBackground
                        if let thumbnail = media.thumbnailURL, thumbnail.scheme == "https" {
                            AsyncImage(url: thumbnail) { image in
                                image.resizable().scaledToFill()
                                    .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                            } placeholder: {
                                Image(systemName: "play.rectangle").font(AppTypography.font(.largeTitle)).foregroundStyle(theme.secondaryText)
                            }
                        } else {
                            Image(systemName: "play.rectangle").font(AppTypography.font(.largeTitle)).foregroundStyle(theme.secondaryText)
                        }
                    }
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: AppStyle.cornerRadius))
                .overlay(alignment: .bottomTrailing) {
                    if let duration = media.duration {
                        Text(MediaPresentation.duration(duration)).font(AppTypography.font(.caption)).monospacedDigit()
                            .foregroundStyle(.white).padding(4)
                            .background(.black.opacity(0.65), in: Capsule()).padding(6)
                    }
                }
                .accessibilityHidden(true)
                Text(media.title).font(AppTypography.font(.title3, weight: .semibold)).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
                if let uploader = media.uploader, !uploader.isEmpty {
                    Text(uploader).font(AppTypography.font(.subheadline)).foregroundStyle(theme.secondaryText)
                }
            }
            VStack(spacing: 0) {
                LabeledContent("Source", value: media.platformLabel).padding(.vertical, 10)
                if let duration = media.duration {
                    Divider().overlay(theme.separator)
                    LabeledContent("Duration", value: MediaPresentation.duration(duration)).padding(.vertical, 10)
                }
                Divider().overlay(theme.separator)
            }
            .font(AppTypography.font(.body))
            VStack(alignment: .leading, spacing: 4) {
                Text("Media").font(AppTypography.font(.headline, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Picker("Media type", selection: $kind) {
                    ForEach(availableKinds(media), id: \.self) { option in
                        Text(option == .video ? "Video" : "Audio").tag(option)
                    }
                }
                .appSegmentedControl()
                .padding(.vertical, 16)
                .onChange(of: kind) { _, _ in formatID = ""; outputFormat = .automatic; availableOutputs = [.automatic] }
            }
            VStack(spacing: 8) {
                NavigationLink {
                    AddLinkQualityPicker(selection: $formatID,
                                         formats: kind == .video ? media.videoChoices : media.audioChoices,
                                         title: formatLabel, detail: formatDetail,
                                         size: { media.downloadSize(kind: kind, formatID: $0) })
                } label: {
                    LabeledContent {
                        HStack(spacing: 6) {
                            Text(qualitySummary(media)).multilineTextAlignment(.trailing)
                            Image(systemName: "chevron.right").font(AppTypography.font(.caption)).accessibilityHidden(true)
                        }
                        .foregroundStyle(theme.secondaryText)
                    } label: { Text("Source quality") }
                    .font(AppTypography.font(.body))
                    .frame(minHeight: 48)
                }
                .buttonStyle(.borderless)
                Divider().overlay(theme.separator)
                LabeledContent("Download size", value: sizeLabel(media.downloadSize(kind: kind, formatID: formatID.isEmpty ? nil : formatID)))
                    .font(AppTypography.font(.body))
                    .frame(minHeight: 44)
                Picker("Save as", selection: $outputFormat) {
                    ForEach(availableOutputs, id: \.self) { format in Text(format.label).tag(format) }
                }
                .pickerStyle(.menu)
                .font(AppTypography.font(.body))
                .frame(minHeight: 44)
                LabeledContent {
                    Text(library.mediaFolderName).foregroundStyle(theme.secondaryText)
                } label: { Text("Save to") }
                .font(AppTypography.font(.body))
                .frame(minHeight: 44)
            }
            Text(outputExplanation).font(AppTypography.font(.subheadline)).foregroundStyle(theme.secondaryText)
            if let outputAvailabilityError {
                Text(outputAvailabilityError).font(AppTypography.font(.subheadline)).foregroundStyle(theme.secondaryText)
            }
        }
    }

    private func availableKinds(_ media: SourceMedia) -> [MediaKind] {
        [.video, .audio].filter { $0 == .video ? !media.videoFormats.isEmpty : !media.audioFormats.isEmpty }
    }

    private func qualitySummary(_ media: SourceMedia) -> String {
        let selected = media.formats.first { $0.id == formatID }
        return selected.map(formatLabel) ?? "Best available"
    }

    private func formatLabel(_ format: SourceFormat) -> String {
        let rawCodec = ((kind == .audio ? format.audioCodec : format.videoCodec) ?? "").lowercased()
        let codec: String
        if rawCodec.hasPrefix("mp4a") || rawCodec == "aac" { codec = "AAC" }
        else if rawCodec.hasPrefix("avc1") || rawCodec == "h264" { codec = "H.264" }
        else if rawCodec.hasPrefix("hvc1") || rawCodec.hasPrefix("hev1") || rawCodec == "hevc" { codec = "HEVC" }
        else if rawCodec.hasPrefix("vp09") || rawCodec == "vp9" { codec = "VP9" }
        else if rawCodec.hasPrefix("av01") || rawCodec == "av1" { codec = "AV1" }
        else { codec = ["unknown", "none", ""].contains(rawCodec) ? format.container.uppercased() : rawCodec.uppercased() }
        return (kind == .audio ? format.audioQualityLabel : format.qualityLabel) + " · " + codec
    }

    private func formatDetail(_ format: SourceFormat) -> String {
        var details = [format.container.uppercased()]
        if kind == .audio, let rate = format.audioSampleRate, rate.isFinite, rate > 0 {
            details.append("\((rate / 1_000).formatted(.number.precision(.fractionLength(0...1)))) kHz")
        }
        if kind == .audio, let channels = format.audioChannels, channels.isFinite, channels > 0, channels < 100 {
            details.append("\(Int(channels.rounded())) channels")
        }
        if let range = format.dynamicRange, range != "SDR" { details.append(range) }
        if let language = format.language { details.append(Locale.current.localizedString(forLanguageCode: language) ?? language) }
        if kind == .audio, format.containsVideo { details.append("From video") }
        details.append("ID \(format.id)")
        return details.joined(separator: " · ")
    }

    private var outputExplanation: String {
        if kind == .video { return "Some source formats need conversion for iPhone playback. Saved file size may change." }
        switch outputFormat {
        case .flac, .alac:
            return "Stores decoded audio. It does not restore detail lost in a lossy source. Saved file size may change."
        case .wav, .aiff, .caf:
            return "Uncompressed audio. Saved file size can be much larger than the download."
        case .automatic:
            return "Keeps playable source audio. Other audio saves as FLAC. Conversion does not improve source quality."
        default:
            return "Audio may need conversion to this format. Saved file size may change."
        }
    }

    private var isDirectFile: Bool {
        guard let link = try? MediaLink(input) else { return false }
        return ["mp4", "mov", "m4v", "mp3", "m4a", "aac", "wav", "flac", "aiff", "aif", "caf"].contains(link.url.pathExtension.lowercased())
    }

    private func resetInspection() {
        theme.endPreview()
        checkID = UUID()
        checkTask?.cancel()
        isChecking = false
        media = nil
        errorMessage = nil
        formatID = ""
        outputFormat = .automatic
    }

    private func performAction() {
        guard !isAdding, !isChecking, queue.isReady, !library.isChangingFolder else { return }
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
                    theme.previewArtwork(url: result.thumbnailURL, id: result.sourceURL.absoluteString)
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
                    let selection = try media.selection(kind: kind, formatID: formatID.isEmpty ? nil : formatID, outputFormat: outputFormat)
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

@MainActor
private struct AddLinkQualityPicker: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var theme: AppTheme
    @Binding var selection: String
    let formats: [SourceFormat]
    let title: (SourceFormat) -> String
    let detail: (SourceFormat) -> String
    let size: (String?) -> SourceDownloadSize?

    var body: some View {
        List {
            option("Best available", detail: nil, id: "")
            ForEach(formats) { format in option(title(format), detail: detail(format), id: format.id) }
        }
        .scrollContentBackground(.hidden)
        .foregroundStyle(theme.primaryText)
        .background(theme.background)
        .appNativeChrome()
        .navigationTitle("Source quality")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }

    private func option(_ title: String, detail: String?, id: String) -> some View {
        Button {
            selection = id
            dismiss()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(AppTypography.font(.body, weight: .medium)).foregroundStyle(theme.primaryText)
                    if let detail { Text(detail).font(AppTypography.font(.subheadline)).foregroundStyle(theme.secondaryText) }
                    Text(size(id.isEmpty ? nil : id).map { downloadSize in "Download \(sizeLabel(downloadSize))" } ?? "Download size unavailable")
                        .font(AppTypography.font(.subheadline)).foregroundStyle(theme.secondaryText)
                }
                Spacer(minLength: 8)
                if selection == id { Image(systemName: "checkmark").foregroundStyle(theme.accent) }
            }
            .padding(.vertical, 6)
            .frame(minHeight: 52)
        }
        .buttonStyle(.borderless)
        .listRowBackground(theme.surface)
        .listRowSeparatorTint(theme.separator)
        .accessibilityAddTraits(selection == id ? .isSelected : [])
    }
}

private func sizeLabel(_ size: SourceDownloadSize?) -> String {
    guard let size else { return "Unavailable" }
    return (size.isEstimate ? "about " : "") + MediaPresentation.bytes(size.byteCount)
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
