# Architecture

SwiftUI owns the application. Core Data stores the original six-field library model. Media defaults to the app's visible Documents folder, or a bookmarked folder selected in Settings. Thumbnails, optional artist details, operation records and the queue journal remain in private Application Support storage.

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
| MediaFolderPreferences | Security-scoped folder bookmarks and the default Documents location. |
| MediaPlayback and MediaDetailView | Artwork-first audio, embedded video, shared fullscreen player and playback lifecycle. |
| ExtractorDependencies | Verified pure-package acquisition, complete generations and cold-launch activation. |

## Social downloads

All extraction and media processing run in the iOS application process. Python resolves public webpages through a verified downloaded yt-dlp generation. QuickJS handles YouTube challenges without spawning a process or downloading native runtime components. iOS subprocess creation is blocked. Swift serializes native FFmpeg calls and retains operation callbacks until processing and queued callbacks finish.

Source metadata exposes every usable source variant. Portrait labels use the shorter dimension. Audio choices include combined streams alongside audio-only streams. Source selection and output conversion are separate typed values. New optional fields preserve old job decoding. Displayed sizes identify exact source bytes, estimates or unknown information, rather than promising a converted file size. Each attempt resolves fresh stream URLs from the persisted webpage.

Each source job has a private work directory. Stream filenames include a hash of their source format ID. Completed and partial streams survive pause and preparation/save failures. They are removed after a successful library commit or explicit cancellation/removal. Relaunch also cleans successful jobs' remaining checkpoints.

FFmpeg prepares native-playable video and audio. Supported codecs copy through where possible. Unsupported video converts with VideoToolbox HEVC, and incompatible video audio converts to AAC. Automatic unsupported audio converts to FLAC without upsampling. Explicit output choices use available native encoders. A small libavformat probe reads actual codecs, avoiding the upstream ffprobe CLI's duplicate globals. Bounded HTTPS artwork is normalized to a JPEG, embedded where supported and retained as a thumbnail fallback. A durable source-result manifest preserves optional artwork and artist metadata across interrupted saves. Attached cover pictures do not change audio classification.

## State and background execution

Social jobs move through queued, extracting, downloading, processing, saving, and completed. Pause/cancel wait for native work to release its operation before the next source acquisition. Saving is a separate durable commit phase. Attempt UUIDs reject late events from replaced attempts.

The queue permits two occupied slots and one social acquisition at a time. Direct URLSession transfers keep their existing background-session behavior. Source jobs use iOS 26's continued-processing API when accepted. Actual transferred bytes and FFmpeg timestamps supply progress. UIKit finite background time covers older iOS and rejected submissions. Expiration cancels source work and preserves a resumable paused job. Queued social jobs start while the app is foregrounded.

Library commits validate the real file through AVFoundation before saving metadata. Receiving all bytes or finishing conversion does not itself complete the job. Atomic operation records recover interrupted file/metadata transactions. The installed 0.2.0 Core Data model and old download jobs remain readable.

## Dependency preparation and evidence

Native archive URLs and hashes are pinned in `scripts/native-dependencies.json`. `prepare-native.py` installs generated native dependencies and applies exact local patches. `package-python.py` creates `.fwork`/`.origin` mappings and embedded module frameworks. The same packaging is required for xtool and Xcode. Third-party pure-package payloads are removed from the final bundle.

The bundled stdlib-only dependency helper validates official PyPI universal wheels, package names, size/hash, Python/EJS compatibility and archive entries. Complete package generations live outside user media in Application Support. Startup and media requests share dependency acquisition. The runtime retains one generation after importing extraction code; later updates are staged for the next cold launch. Failed or interrupted activation retains the previous confirmed generation. CPython, signed extension modules, QuickJS and FFmpeg cannot be updated this way.

`MediaFileStore` separates its media directory from its private root. Relocation verifies only managed files and never overwrites a different destination file. The bookmark is persisted before old managed copies are removed. Save, rollback and deletion support different filesystem volumes. Storage changes are blocked during imports and unfinished downloads. A missing folder bookmark reports a recoverable Settings error without deleting library records.

The FFmpeg integration is GPL-3.0. Its licensing and source requirements apply to redistribution. Distribution licensing and the corresponding source package need completion before redistributing the app to others.

Core tests, host extractor tests, actual public downloads, and arm64 packaging provide separate evidence. Host FFmpeg execution does not establish native iOS FFmpeg execution. Python startup, native rendering, VideoToolbox conversion, AVKit playback, signing, and background behavior remain phone checks.

## Appearance and accent themes

`RootView` retains the existing `appearance` UserDefaults key for System, Light and Dark. `AppTheme` independently persists Neutral, Sage, Lavender, Amber, Ocean or Dynamic through `ThemePreferences` under `accentTheme`. New installations default to Sage. Shared palettes coordinate text, surfaces and controls, with restrained dark backgrounds. `AppTypography` registers licensed Stack Sans Text/Notch and supplies Dynamic Type-aware SwiftUI and native control fonts. Native chrome remains system-owned. The launcher follows phone appearance rather than a manual choice.

Opening a saved player selects that item for Dynamic. The selection stays when returning to the library or changing tabs. Deleting the selected item clears it. Add Link temporarily previews the inspected artwork, then restores the saved-media selection when its input resets or the sheet closes. Selection is session state, so launching without a selected item uses neutral for Dynamic.

`ArtworkPaletteCache` downsamples artwork to at most 48 pixels per dimension in sRGB off the UI actor. Its 64-entry least-recently-used cache includes neutral results from unsuitable artwork, but not missing data or failed requests, so reopening a preview can retry a transient failure. Remote preview downloads have a 15-second request timeout and a 5 MB limit. `MediaPaletteExtractor` clusters colour samples, ignores transparent, near-black, near-white and near-monochrome samples, and ranks useful clusters rather than selecting the dominant pixel. The chosen hue receives restrained saturation and separate light/dark luminance adjustments. The accent meets a 4.5:1 contrast threshold against the defined light and dark surfaces; primary buttons choose contrasting text.

Request identities reject results from replaced selections. Reopening the same selected item does not restart extraction. Accent updates animate over 400 ms unless Reduce Motion is enabled. Tests exercise portable colour selection, contrast, preferences and stale-result handling. Native sampling and rendered transitions still require phone verification.

Downloads shows active and queued jobs. History uses the existing terminal jobs, grouped by their creation date, with search, retry, removal and clear-history actions. Neither presentation changes the queue journal or the six-field Core Data model. See [icon packaging](icons.md) for Xcode appearance assets and the xtool alternate-icon fallback.
