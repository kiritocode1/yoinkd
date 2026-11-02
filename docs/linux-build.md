# Build on Arch Linux

Use Swift, xtool, Python 3.12 or newer, GNU patch, and the Darwin iPhoneOS SDK. This workspace uses `/usr/bin/swift` 6.4.2, xtool, and SDK 27.2. The app targets iOS 17 and uses native SwiftUI.

Icon packaging also requires `doc-python` with Pillow in the existing document environment. Check it with `doc-python -c 'from PIL import Image; print(Image.__version__)'`. Do not install Pillow into Arch's system Python. Both project and IPA checks use only the Python standard library.

Prepare dependencies and run the focused core checks:

```sh
python3 scripts/prepare-native.py
/usr/bin/swift test --package-path Packages/YoinksCore
```

The preparation script verifies pinned archive hashes, applies the local FFmpeg probe/callback patches, and bundles Python packages and license notices. Generated dependencies stay outside version control. Cached archives allow `prepare-native.py --offline`.

Build, package Python's extension modules, and inspect the actual unsigned IPA:

```sh
env PATH="/usr/bin:$PATH" bash scripts/build-native.sh
```

The output is `xtool/iYoinks.ipa`. The checker validates arm64, iOS 17, the linked SDK, branding, bundled source, and all Python framework mappings. `build/release-check.json` records its SHA-256 and sizes.

Plain `xtool dev build --ipa` is an intermediate archive. It needs the Python and icon packaging steps before signing or installation. The wrapper performs both steps. It does not authenticate, sign, or install. See [Light and dark icons](icons.md) for the explicit alternate-icon contract and Xcode luminosity support.

For extractor checks on Linux, install host FFmpeg and a C compiler, then run:

```sh
python3 scripts/verify-extractor.py
```

This builds the actual C/QuickJS bridge for the host, downloads controlled loopback fixtures, and uses desktop FFmpeg through a host callback. It checks merging, audio preservation, FLAC conversion, cancellation, partial resume, retry checkpoints, and JavaScript interruption. It does not execute the iOS FFmpeg binary.

Optional live checks accept a public link. Inspection saves source metadata without signed media URLs:

```sh
python3 scripts/verify-extractor.py --live 'https://www.youtube.com/watch?v=aqz-KE-bpKQ' --output build/source-check.json
```

Add `--download video` or `--download audio` with `--directory` to acquire real media. `--format` chooses an exact source ID. Live downloads consume network data.

Sign the final IPA with your existing tool and install manually. Every bundled framework needs signing. Native launch, playback, UI, and background behavior are separate checks.
