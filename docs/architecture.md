# Architecture

SwiftUI owns the application. Core Data stores the original six-field library model. Media files, thumbnails, details, and the queue journal remain in private app storage.

| Component | Responsibility |
| --- | --- |
| YoinksCore | Validated links/files, source formats, quality selection, queue snapshots, and recoverable file transactions. |
| AddLinkView | Native link entry, asynchronous inspection, source metadata, and video/audio quality pickers. |
| NativeExtractor | Swift's asynchronous boundary to the bundled C/Python runtime, cancellation, and progress callbacks. |
| ExtractorBridge | Isolated CPython initialization, operation lifetimes, and bounded QuickJS challenge execution. |
| iyoinks_extract.py | yt-dlp inspection, selected source acquisition, stream checkpoints, and media preparation requests. |
| DownloadQueue | Attempt identities, state, scheduling, pause/cancel/retry, staging, and commit completion. |
| SourceBackgroundWork | iOS continued-processing requests, actual progress, finite fallback time, and expiration. |
| MediaLibrary and MediaStorage | AVFoundation validation and durable file/Core Data commits. |

## Social downloads

All extraction and media processing run in the iOS application process. Python resolves public webpages through bundled yt-dlp. QuickJS handles YouTube challenges without spawning a process or downloading runtime components. iOS subprocess creation is blocked. Swift serializes native FFmpeg calls and retains operation callbacks until processing and queued callbacks finish.

Source metadata exposes only available formats. Video choices collapse duplicate resolutions and use the shorter dimension for portrait media. Audio uses audio bitrates, including when its only source is a combined video. The queue stores the stable webpage and selection. It resolves fresh stream URLs on each attempt.

Each source job has a private work directory. Stream filenames include a hash of their source format ID. Completed and partial streams survive pause and preparation/save failures. They are removed after a successful library commit or explicit cancellation/removal. Relaunch also cleans successful jobs' remaining checkpoints.

FFmpeg prepares MP4 video and playable audio. Supported video/audio codecs copy through where possible. Unsupported video converts with VideoToolbox HEVC, and incompatible video audio converts to AAC. Unsupported audio-only codecs convert to FLAC without upsampling. Compatible audio inside video remuxes without re-encoding. A small libavformat probe reads actual stream codecs, avoiding the upstream ffprobe CLI's duplicate globals.

## State and background execution

Social jobs move through queued, extracting, downloading, processing, saving, and completed. Pause/cancel wait for native work to release its operation before the next source acquisition. Saving is a separate durable commit phase. Attempt UUIDs reject late events from replaced attempts.

The queue permits two occupied slots and one social acquisition at a time. Direct URLSession transfers keep their existing background-session behavior. Source jobs use iOS 26's continued-processing API when accepted. Actual transferred bytes and FFmpeg timestamps supply progress. UIKit finite background time covers older iOS and rejected submissions. Expiration cancels source work and preserves a resumable paused job. Queued social jobs start while the app is foregrounded.

Library commits validate the real file through AVFoundation before saving metadata. Receiving all bytes or finishing conversion does not itself complete the job. Atomic operation records recover interrupted file/metadata transactions. The installed 0.2.0 Core Data model and old download jobs remain readable.

## Dependency preparation and evidence

Native archive URLs and hashes are pinned in `scripts/native-dependencies.json`. `prepare-native.py` installs generated dependencies and applies exact local patches. `package-python.py` creates `.fwork`/`.origin` mappings and embedded module frameworks. The same packaging is required for xtool and Xcode.

The FFmpeg integration is GPL-3.0. Its licensing and source requirements apply to redistribution. Distribution licensing and the corresponding source package need completion before redistributing the app to others.

Core tests, host extractor tests, actual public downloads, and arm64 packaging provide separate evidence. Host FFmpeg execution does not establish native iOS FFmpeg execution. Python startup, native rendering, VideoToolbox conversion, AVKit playback, signing, and background behavior remain phone checks.

## Appearance and accent themes

`RootView` retains the existing `appearance` UserDefaults key for System, Light and Dark. `AppTheme` independently persists Neutral, Sage, Lavender, Amber, Ocean or Dynamic through `ThemePreferences` under `accentTheme`. New installations default to Sage. The root shares the theme with all tabs and sheets. Standard text and backgrounds use appearance-dependent semantic colours, not the media accent.

Opening a saved player selects that item for Dynamic. The selection stays when returning to the library or changing tabs. Deleting the selected item clears it. Add Link temporarily previews the inspected artwork, then restores the saved-media selection when its input resets or the sheet closes. Selection is session state, so launching without a selected item uses neutral for Dynamic.

`ArtworkPaletteCache` downsamples artwork to at most 48 pixels per dimension in sRGB off the UI actor. Its 64-entry least-recently-used cache includes neutral results from unsuitable artwork, but not missing data or failed requests, so reopening a preview can retry a transient failure. Remote preview downloads have a 15-second request timeout and a 5 MB limit. `MediaPaletteExtractor` clusters colour samples, ignores transparent, near-black, near-white and near-monochrome samples, and ranks useful clusters rather than selecting the dominant pixel. The chosen hue receives restrained saturation and separate light/dark luminance adjustments. The accent meets a 4.5:1 contrast threshold against the defined light and dark surfaces; primary buttons choose contrasting text.

Request identities reject results from replaced selections. Reopening the same selected item does not restart extraction. Accent updates animate over 400 ms unless Reduce Motion is enabled. Tests exercise portable colour selection, contrast, preferences and stale-result handling. Native sampling and rendered transitions still require phone verification.

Downloads shows active and queued jobs. History uses the existing terminal jobs, grouped by their creation date, with search, retry, removal and clear-history actions. Neither presentation changes the queue journal or the six-field Core Data model. See [icon packaging](icons.md) for Xcode appearance assets and the xtool alternate-icon fallback.
