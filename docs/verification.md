# Verification results

These results cover iYoinks 0.3.0, build 3, on Arch Linux on 2026-11-02. The implementation received human approval through Plannotator. Native runtime and UI testing remain pending for this version.

## Build and focused checks

| Check | Observed result |
| --- | --- |
| Swift core | 28 tests passed with no failures. Source qualities, portrait labels, audio bitrate, old-job decoding, queue snapshots, and recoverable file transactions. |
| Host extractor | 11 tests passed through the actual C/QuickJS bridge and desktop FFmpeg callback. Stream merging, audio preservation, FLAC conversion, cancellation, Range resume, retry checkpoints, removed formats, and JavaScript interruption. |
| Native Release build | arm64 compilation completed in 38.67 seconds with the Darwin iPhoneOS 27.2 SDK and iOS 17 minimum. |
| Production IPA | ZIP CRC, platform/architecture, branding, bundled extractor, Xcode references, and all 68 Python module framework mappings passed. |
| iPhone runtime and UI | Unverified. Python startup, native FFmpeg execution, VideoToolbox conversion, AVKit playback, keyboard behavior, accessibility, and background handling need phone testing. |

The Core Data library model, app icon, and Y mark remained unchanged during the social-download implementation. Older direct-download snapshots remain readable.

## Real host downloads

These checks used the host C/QuickJS bridge and desktop FFmpeg. They do not establish iOS execution or playback.

| Public source | Observed output |
| --- | --- |
| [YouTube, official Blender film](https://www.youtube.com/watch?v=aqz-KE-bpKQ) | 640x360 H.264 video and AAC audio, 634.58 seconds, 41,795,474 bytes. |
| [Instagram reel](https://www.instagram.com/reel/Chunk8-jurw/) | 720x1280 silent H.264 video, 4.97 seconds, 1,949,872 bytes. |
| [X post](https://x.com/TopHeroes_/status/2001950365332455490) | 720x720 H.264 video and AAC audio, 30.33 seconds, 3,406,882 bytes. |
| Same X post, best source audio | AAC remuxed to M4A, 128 kbps, 30.33 seconds, 491,341 bytes. |

Two older X examples failed through an unavailable legacy media service. Source access can change, and a supported site can still reject a particular public link.

## Checked archive

The unsigned archive is generated at `xtool/iYoinks.ipa`. Build outputs and local review artifacts are excluded from Git.

| Property | Observed value |
| --- | --- |
| Version and build | 0.3.0, build 3 |
| Archive bytes | 29,457,836 |
| Sum of unpacked entry bytes | 81,908,956 |
| SHA-256 | `44655e872bf78e53202e1f49114572388d945f9fc1d0b624b6fec31658501e36` |
| Platform and architecture | iPhoneOS, arm64 |
| Minimum iOS and linked SDK | 17.0 and 27.2 |
| Python module frameworks | 68 |
| Signing | Manual signing and installation required. |

These measurements describe the checked ZIP, not installed disk allocation or runtime memory. Rebuilt archives can have different hashes. Launch time, memory, battery use, and native processing speed have not been measured.

## Reproduce

Prepare dependencies using the [Arch Linux build instructions](linux-build.md), then run these sequentially:

```sh
/usr/bin/swift test --package-path Packages/YoinksCore
python3 scripts/verify-extractor.py
env PATH="/usr/bin:$PATH" bash scripts/build-native.sh
```

Check an existing final IPA without rebuilding:

```sh
python3 scripts/check-ipa.py xtool/iYoinks.ipa --output build/release-check.json
```

Dependency archives, versions, and hashes are pinned in `scripts/native-dependencies.json`. The linked FFmpeg integration is GPL-3.0. Distribution licensing and corresponding source need completion before redistributing the app to others.

Use the [phone testing guide](phone-testing.md) for the remaining native checks. Xcode builds and older-iOS background fallback also remain unverified.
