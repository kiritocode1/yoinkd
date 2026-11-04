# Build with Xcode

Use Xcode 27 or newer for the current SDK APIs. iOS 26 continued-processing calls are guarded; the app retains an iOS 17 minimum.

Prepare pinned dependencies with Python 3.12 or newer, then run core tests:

```sh
python3 scripts/prepare-native.py
swift test --package-path Packages/YoinksCore
```

The core tests use Swift Testing. With Xcode selected, the command above is enough. With Command Line Tools only, pass the Testing macro plugin explicitly:

```sh
swift test --package-path Packages/YoinksCore \
  -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
```

`scripts/verify-dependencies.py` and `scripts/verify-extractor.py` run on macOS and Linux. The extractor suite needs FFmpeg (`brew install ffmpeg`) and finds its libraries through `pkg-config` or Homebrew.

The Xcode target links YoinksCore, YoinksExtractor, and SwiftFFmpeg. Its final runtime phase packages Python extension modules as frameworks. When signing is enabled, that phase signs the generated Python frameworks with the target's existing identity.

Build a simulator app on an Apple silicon Mac:

```sh
xcodebuild \
  -project iYoinks.xcodeproj \
  -scheme iYoinks \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData \
  ARCHS=arm64 \
  build
```

`ARCHS=arm64` is required because SwiftFFmpeg ships no x86_64 simulator slice. Keep signing enabled. The packaging phase rewrites each Python module's install name, which invalidates its signature, and it re-signs the modules only when signing is allowed. A build with `CODE_SIGNING_ALLOWED=NO` installs, but iOS kills it at launch with a code-signing `invalid-page` exit. Without a team, Xcode signs the simulator build ad hoc.

The app's bundled files live in `iYoinks/AppResources`. Do not name that folder `Resources`: a top-level `Resources` folder in an iOS app makes the bundle loader look for `Resources/Info.plist`, and the install fails with "Missing bundle ID".

Select your Apple team through Xcode's existing signing settings for a device build. Keep credentials and provisioning files outside the project. Use Organizer to export an IPA with your available provisioning method.

The command above was verified with Xcode 27.2 on an iOS 27.2 iPhone 17 simulator: the app installs and opens to the Library screen. A signed device installation remains unverified from this Mac.

`scripts/yoinkctl build` and `scripts/yoinkctl install` wrap the build and install. The saved Argent flows in `.argent/flows/` cover adding video and audio, playback, themes, pause/resume and relaunching mid-download; run one with `argent flow run add-video --device <udid>`. The `yoinkd-verify` skill (`.claude/skills/yoinkd-verify/SKILL.md`) and `docs/feature-map.md` describe the loop and the simulator gotchas.

Still check by hand on an iOS target: cancel during inspection, background expiration, keyboard behavior, Dynamic Type, and older-iOS fallback behavior.
