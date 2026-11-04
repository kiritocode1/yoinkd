import CoreText
import ObjectiveC
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import YoinksCore

/// The share sheet's yoink'd card. It reads the shared link, lets the user pick Video or Audio, saves
/// the request to the App Group inbox, then tries to open the app with `yoinkd://add`. If the app
/// can't be opened, the inbox hands the link over the next time yoink'd comes to the foreground.
/// The extension never downloads: Python, yt-dlp and FFmpeg don't fit its memory budget.
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        ShareTypography.register()
        model.cancel = { [weak self] in self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled)) }
        model.done = { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
        model.send = { [weak self] request in self?.hand(request) }
        let host = UIHostingController(rootView: ShareCard(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        Task { @MainActor [model] in
            model.link = await SharedLink.first(in: items)
            model.loaded = true
        }
    }

    /// Saves first, so the link survives even if iOS refuses to open the app.
    private func hand(_ request: CaptureRequest) {
        let inbox = CaptureInbox.shared()
        let saved = inbox.map { (try? $0.add(request)) != nil } ?? false
        Task { @MainActor [weak self] in
            guard let self else { return }
            if await self.openApp(request.url) {
                self.extensionContext?.completeRequest(returningItems: nil)
            } else {
                self.model.outcome = saved ? .saved : .failed
            }
        }
    }

    /// Extensions have no supported way to open their app, and `UIApplication.open` is unavailable
    /// when compiling for an extension. The extension process still has a UIApplication in its
    /// responder chain, so this calls that method's implementation directly. Verified on iOS 27.2;
    /// when it stops working, the inbox fallback still delivers the link.
    private func openApp(_ url: URL) async -> Bool {
        #if FORCE_SHARE_FALLBACK
        // Test builds only (`yoinkctl build --force-share-fallback`): exercise the inbox path.
        return false
        #endif
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                return await Self.open(url, with: application)
            }
            responder = current.next
        }
        return false
    }

    private static func open(_ url: URL, with application: UIApplication) async -> Bool {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        guard let method = class_getInstanceMethod(object_getClass(application), selector) else { return false }
        typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, @escaping @convention(block) (Bool) -> Void) -> Void
        let implementation = unsafeBitCast(method_getImplementation(method), to: Open.self)
        return await withCheckedContinuation { continuation in
            implementation(application, selector, url as NSURL, NSDictionary()) { continuation.resume(returning: $0) }
        }
    }
}

/// Finds the first HTTPS link in what another app shared: a URL attachment, or text containing one.
/// Main-actor isolated because the extension items it reads are not Sendable.
@MainActor
enum SharedLink {
    static func first(in items: [NSExtensionItem]) async -> URL? {
        for item in items {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL,
                   url.scheme?.lowercased() == "https" {
                    return url
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String,
                   let url = link(in: text) {
                    return url
                }
            }
            if let text = item.attributedContentText?.string, let url = link(in: text) { return url }
        }
        return nil
    }

    static func link(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        return detector?.matches(in: text, range: range).compactMap(\.url).first { $0.scheme?.lowercased() == "https" }
    }
}

enum ShareOutcome { case saved, failed }

@MainActor
final class ShareModel: ObservableObject {
    @Published var link: URL?
    @Published var loaded = false
    @Published var kind = MediaKind.video
    @Published var outcome: ShareOutcome?
    var cancel: () -> Void = {}
    var done: () -> Void = {}
    var send: (CaptureRequest) -> Void = { _ in }

    func yoink() {
        guard let link else { return }
        send(CaptureRequest(link: link.absoluteString, kind: kind))
    }
}

/// The app's typefaces, loaded from the containing app's bundle instead of copying them here.
enum ShareTypography {
    private static let faces = ["StackSansText-Regular", "StackSansText-Medium", "StackSansNotch-SemiBold"]

    static func register() {
        let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        for face in faces {
            let url = app.appendingPathComponent("AppResources/Fonts/\(face).ttf")
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static func font(_ face: String, _ size: CGFloat, relativeTo style: Font.TextStyle) -> Font {
        UIFont(name: face, size: size) == nil ? .system(style) : .custom(face, size: size, relativeTo: style)
    }
}

struct ShareCard: View {
    @ObservedObject var model: ShareModel
    @Environment(\.colorScheme) private var colorScheme

    private var accent: Color {
        let rgb = colorScheme == .dark ? AccentTheme.sage.palette.dark : AccentTheme.sage.palette.light
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                if let link = model.link {
                    Label(link.absoluteString, systemImage: "link")
                        .font(ShareTypography.font("StackSansText-Regular", 17, relativeTo: .body))
                        .lineLimit(2)
                    if let outcome = model.outcome {
                        switch outcome {
                        case .saved:
                            Label("Saved. Open yoink'd to finish.", systemImage: "checkmark.circle")
                                .font(ShareTypography.font("StackSansText-Medium", 17, relativeTo: .body))
                        case .failed:
                            Label("Couldn't reach yoink'd. Copy the link and paste it there.", systemImage: "exclamationmark.circle")
                                .font(ShareTypography.font("StackSansText-Medium", 17, relativeTo: .body))
                                .foregroundStyle(.red)
                        }
                    } else {
                        Picker("Media type", selection: $model.kind) {
                            Text("Video").tag(MediaKind.video)
                            Text("Audio").tag(MediaKind.audio)
                        }
                        .pickerStyle(.segmented)
                    }
                } else if model.loaded {
                    Label("No link in this share.", systemImage: "exclamationmark.circle")
                        .font(ShareTypography.font("StackSansText-Medium", 17, relativeTo: .body))
                        .foregroundStyle(.red)
                } else {
                    ProgressView()
                }
                Spacer()
            }
            .padding(20)
            .navigationTitle("yoink'd")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.outcome != nil {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { model.done() } }
                } else {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.cancel() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("yoink!") { model.yoink() }
                            .font(ShareTypography.font("StackSansNotch-SemiBold", 17, relativeTo: .headline))
                            .disabled(model.link == nil)
                    }
                }
            }
        }
        .tint(accent)
    }
}
