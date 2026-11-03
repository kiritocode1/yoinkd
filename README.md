# yoink'd

A native iPhone adaptation of [Yoinks](https://github.com/pablostanley/yoinks), written in Swift and SwiftUI. [Seal](https://github.com/junkfood02/Seal) supplied the social-download workflow reference.

Version 0.5.0 uses native tabs and glass controls, Stack Sans Text and Notch, an artwork-first audio player and embedded video playback with fullscreen. Neutral, Sage, Lavender, Amber, Ocean and Dynamic themes coordinate backgrounds, surfaces, text and controls. Dark appearance uses near-black content and restrained tinted surfaces. Dynamic uses the selected media's artwork, with neutral grey when no suitable colour is available. Theme, appearance, sorting and grid/list choices persist.

Open `yoink!`, check a link, choose Video or Audio, select a source quality and saved output format, then download. All usable source variants remain available, including lower resolutions, codecs, frame rates and combined audio/video streams. Best available selects the source maximum. Sizes distinguish reported source bytes, estimates and unavailable information. Conversion can change the saved file size.

Automatic video saves as MP4. Supported codecs copy through; others need conversion for iPhone playback. Automatic audio keeps a playable source format or converts unsupported audio to FLAC. Explicit audio outputs include FLAC and other available native encoders. FLAC preserves decoded audio, but does not restore quality lost in a lossy source. Audio artwork and artist metadata are saved when available. Supported containers receive embedded cover art, with a saved thumbnail fallback.

Downloads show extraction, transfer, preparation, and saving. Pause and retry preserve source streams where the server supports resuming. Every attempt refreshes the webpage, so the queue does not retain expiring media URLs. A validated file and a successful metadata save produce the library item.

File imports, direct HTTPS downloads, offline AVKit playback, search, filters, rename, sharing, and deletion remain available. The existing Core Data model and supplied Y icon are preserved.

The extraction engine runs on the iPhone through bundled CPython, QuickJS and FFmpeg. It uses no companion server. On first use it downloads a verified, compatible yt-dlp, EJS and certifi package set. Settings checks and updates packages individually or together. Updates after the engine starts apply on the next launch; the previous verified set remains available for rollback. First installation requires internet access. Native runtimes stay bundled because iOS requires signed binaries. Downloaded interpreted-code updates need a separate App Store policy review.

Saved media defaults to the app's Documents folder, visible as `yoink'd` in Files. Settings can relocate managed files to a selected folder using a persistent security-scoped bookmark. Folder changes copy and verify media before switching, and are unavailable during imports or unfinished downloads. Metadata, thumbnails and the queue remain private.

The FFmpeg integration uses GPL-3.0, so redistribution requires compatible licensing and the required source. Native dependency versions, hashes and local patches are included in `scripts/`.

The minimum deployment target is iOS 17. Native Liquid Glass requires iOS 26 or newer. Continued background processing uses iOS 26's task API when permitted, with finite UIKit background time as a fallback. Expiration pauses the source job. Force-quitting interrupts source work.

Private links, sign-in challenges, DRM, playlists, multi-video posts, and active livestreams are outside this release. Support depends on the source. Legacy X media services can be unavailable even when current X posts work.

- [Build on Arch Linux](docs/linux-build.md)
- [Build with Xcode](docs/mac-build.md)
- [Architecture](docs/architecture.md)
- [Verification results](docs/verification.md)
- [Phone testing guide](docs/phone-testing.md)
- [Changelog](CHANGELOG.md)

The repository is [maynkudu/yoinkd](https://github.com/maynkudu/yoinkd). Internal target names, bundle identifiers, the Core Data store and queue identifiers remain unchanged. Existing media migrates to the visible folder without creating a new library.

The current IPA is unsigned for manual signing and installation. Host checks cover real YouTube, Instagram, and X downloads. See the verification results for this version's checked behavior and remaining phone checks.
