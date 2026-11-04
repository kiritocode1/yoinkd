import Photos
import UIKit

/// Adds a saved video to the photo library, only when the user chooses Save to Photos.
/// Uses add-only access, so yoink'd never reads the user's photos.
enum PhotosSaver {
    enum Outcome: Equatable {
        case saved
        case unsupportedFormat
        case notAllowed
        case failed(String)

        var title: String { self == .saved ? "Saved to Photos" : "Couldn't save to Photos" }

        var message: String {
            switch self {
            case .saved: "The video is in your photo library."
            case .unsupportedFormat: "Photos can't open this video's format. Use Share file to save it somewhere else."
            case .notAllowed: "Allow yoink'd to add photos in Settings > Privacy & Security > Photos."
            case .failed(let reason): reason
            }
        }
    }

    static func save(videoAt url: URL) async -> Outcome {
        guard UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(url.path) else { return .unsupportedFormat }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return .notAllowed }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
            return .saved
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
