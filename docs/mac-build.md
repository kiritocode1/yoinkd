# Build with Xcode

Use Xcode 27 or newer for the current SDK APIs. iOS 26 continued-processing calls are guarded; the app retains an iOS 17 minimum.

Prepare pinned dependencies with Python 3.12 or newer, then run core tests:

```sh
python3 scripts/prepare-native.py
swift test --package-path Packages/YoinksCore
```

The Xcode target links YoinksCore, YoinksExtractor, and SwiftFFmpeg. Its final runtime phase packages Python extension modules as frameworks. When signing is enabled, that phase signs the generated Python frameworks with the target's existing identity.

Build a simulator app:

```sh
xcodebuild \
  -project iYoinks.xcodeproj \
  -scheme iYoinks \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Select your Apple team through Xcode's existing signing settings for a device build. Keep credentials and provisioning files outside the project. Use Organizer to export an IPA with your available provisioning method.

The Xcode project references and packaging configuration are checked on Linux. The Xcode build, simulator runtime, and signed installation remain unverified here. The Linux xtool build is the current verified build path.

Check link entry, metadata, available video/audio qualities, cancel during inspection, pause and retry, offline playback, background expiration, keyboard behavior, Dynamic Type, and appearance on an iOS target. Verify older-iOS fallback behavior separately.
