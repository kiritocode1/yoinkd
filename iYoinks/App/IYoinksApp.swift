import CoreData
import SwiftUI
import YoinksCore

@main
@MainActor
struct IYoinksApp: App {
    @UIApplicationDelegateAdaptor(IYoinksAppDelegate.self) private var appDelegate
    @State private var storage = Storage.loading
    @State private var loadRequest = 0
    /// Held here because a `yoinkd://add` link can arrive while the library is still opening.
    @State private var pendingCapture: CaptureRequest?

    init() { AppTypography.registerFonts() }

    var body: some Scene {
        WindowGroup {
            Group {
                switch storage {
                case .loading:
                    ProgressView("Opening library")
                case .ready(let container, let library, let queue):
                    RootView(pendingCapture: $pendingCapture)
                        .environment(\.managedObjectContext, container.viewContext)
                        .environmentObject(library)
                        .environmentObject(queue)
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Library unavailable", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try again") { loadRequest += 1 }
                    }
                }
            }
            .task(id: loadRequest) {
                storage = .loading
                let result = await Self.openStorage(appDelegate: appDelegate)
                guard !Task.isCancelled else { return }
                storage = result
            }
            .task { await ExtractorDependencies.shared.refreshOnLaunch() }
            .onOpenURL { url in
                if let request = CaptureRequest(url: url) { pendingCapture = request }
            }
        }
    }

    private static func openStorage(appDelegate: IYoinksAppDelegate) async -> Storage {
        let container = NSPersistentContainer(name: "iYoinks", managedObjectModel: LibraryItem.makeModel())
        container.persistentStoreDescriptions.first?.shouldAddStoreAsynchronously = true
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                container.loadPersistentStores { _, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
            container.viewContext.automaticallyMergesChangesFromParent = true
            guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw CocoaError(.fileNoSuchFile)
            }
            let mediaStorage = try await MediaStorage.open(root: support.appendingPathComponent("iYoinks", isDirectory: true))
            let library = MediaLibrary(context: container.viewContext, storage: mediaStorage)
            try await library.restore()
            let queue = DownloadQueue(library: library, appDelegate: appDelegate)
            library.canChangeMediaFolder = { [weak queue] in
                queue?.jobs.allSatisfy { $0.phase.isTerminal } ?? false
            }
            await queue.restore()
            return .ready(container, library, queue)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private enum Storage {
        case loading
        case ready(NSPersistentContainer, MediaLibrary, DownloadQueue)
        case failed(String)
    }
}
