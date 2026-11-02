# iYoinks

A native iPhone adaptation of [Yoinks](https://github.com/pablostanley/yoinks), written in Swift and SwiftUI. [Seal](https://github.com/junkfood02/Seal) supplied the social-download workflow reference.

Version 0.3.0 adds public social-media links to the local media library. Check a link, choose Video or Audio, select an available source quality, and download. Video choices start at 360p when the source supplies those resolutions. Best available selects the source maximum. Audio offers the source's available bitrates.

Video saves as MP4. Supported video codecs copy through; others need conversion for iPhone playback. Audio keeps its playable source format, extracts compatible audio without re-encoding, or converts unsupported audio to FLAC. FLAC preserves decoded source quality and can produce a larger file.

Downloads show extraction, transfer, preparation, and saving. Pause and retry preserve source streams where the server supports resuming. Every attempt refreshes the webpage, so the queue does not retain expiring media URLs. A validated file and a successful metadata save produce the library item.

File imports, direct HTTPS downloads, offline AVKit playback, search, filters, rename, sharing, and deletion remain available. The existing Core Data model and supplied Y icon are preserved.

The extraction engine runs on the iPhone through bundled CPython, yt-dlp, QuickJS, and FFmpeg. It uses no companion server. These dependencies add to the app size. The FFmpeg integration uses GPL-3.0, so redistribution requires compatible licensing and the required source. Dependency versions, hashes, and local patches are included in `scripts/`.

The minimum deployment target is iOS 17. Native Liquid Glass requires iOS 26 or newer. Continued background processing uses iOS 26's task API when permitted, with finite UIKit background time as a fallback. Expiration pauses the source job. Force-quitting interrupts source work.

Private links, sign-in challenges, DRM, playlists, multi-video posts, and active livestreams are outside this release. Support depends on the source. Legacy X media services can be unavailable even when current X posts work.

- [Build on Arch Linux](docs/linux-build.md)
- [Build with Xcode](docs/mac-build.md)
- [Architecture](docs/architecture.md)
- [Verification results](docs/verification.md)
- [Phone testing guide](docs/phone-testing.md)

The current IPA is unsigned for manual signing and installation. Host checks cover real YouTube, Instagram, and X downloads. Native runtime, UI, codec conversion, and background behavior still require phone review for this version.
