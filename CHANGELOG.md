# Changelog

## 0.5.2, build 8

- Fix extraction-package installation through valid sandbox parent-directory aliases, including iOS `/var` and `/private/var`. Resolve the absolute private directory once instead of rejecting a different canonical spelling.
- Use the same canonical directory for package state, downloads, generations and runtime activation. Alias and canonical requests no longer create separate activation-session identities.
- Keep relative paths, parent traversal, dependency-directory symlinks and symlinked download/generation directories rejected. Archive, checksum, native-code and compatibility checks remain unchanged.
- Add directory-alias regression coverage through the production Python control endpoint and actual C bridge, including installation, activation and shared persisted state. Keep the official package wheels unmodified.
- Retain the 0.5.1 UI fixes, `yoink'd` display name, bundle identifier and existing media/settings. No dependency-state reset is required.

## 0.5.1, build 7

- Fix first installation of the unmodified official yt-dlp wheel. Validate and omit its desktop share documentation without allowing extra import roots, scripts, native payloads or unsafe archive entries.
- Replace repacked-wheel activation fixtures with the original pinned official downloads. Add first-install and ancillary-data safety coverage.
- Strip generated Python bytecode caches during packaging so local validation cannot leak incompatible cache files into the IPA.
- Show per-package working state as soon as Get starts and retain errors beside the affected package. Make Check for updates and Update all independent native Form buttons.
- Close Library and History search when the query is cleared, restoring the heading and controls without a second Cancel tap.
- Limit tab transition animation to a small scale change, keeping text and layout out of the animation transaction.
- Add persistent History sort, Grid/List display and All/Video/Audio filters while preserving retry, removal and clear actions.
- Keep `yoink!` and Cancel Download at the capture drawer's top. Move Check link below the URL field and Download below its options. Replace trailing Paste with X for nonempty input and protect text beneath the overlay.
- Match Info and Share button sizing across audio and video. Use a two-line audio title, compact artwork/spacing and a bottom safe-area action row.
- Keep the phone's display name `yoink'd` and existing internal executable/bundle identifiers. Copied crash reports are from 0.3.0 build 3; they do not establish a crash in this release.

## 0.5.0, build 6

### Controls and appearance

- Fix search dismissal through an explicit Cancel action that ends focus, clears the query and restores the heading and menus.
- Rename the link workflow and download entry actions to `yoink!`. Remove suggested platforms from the link drawer and nested button styling from its toolbar. Keep one Cancel Download action.
- Register licensed Stack Sans Text and Stack Sans Notch. Use shared Dynamic Type-aware typography for app content, native headings and segmented controls.
- Increase shared segmented-control labels and maintain native control sizing across Library, Settings and download format selection.
- Replace directional page sliding with a short scale-and-opacity pop. Reduce Motion removes decorative movement.
- Retain one native tab bar, native glass buttons, menus and search. Add limited symbol/selection feedback and finite download-card entry/reflection animation.
- Replace platform stand-ins with actual YouTube, Instagram, X and TikTok vector logos. Use a descending three-line sort glyph inside the native circular menu.
- Use near-black dark content, restrained themed surfaces and a coordinated colour palette. Preserve Neutral, Sage, Lavender, Amber, Ocean and artwork-driven Dynamic selection.
- Remove Library list-row backgrounds, chevrons and overflow controls. Keep share, rename and delete in context menus and file info.
- Remove manual Home Screen icon selection. Use the native dark asset slot or the Linux archive's automatic phone-appearance alternate-icon fallback.

### Downloads and playback

- Show every usable source variant, including low-resolution and same-resolution codec/frame-rate choices and combined audio/video streams.
- Separate source quality from saved output format. Add explicit FLAC and other available native audio outputs. Automatic output retains its existing compatible-source/fallback policy.
- Label exact source sizes, estimates and unknown sizes honestly. Converted file size may differ; converting lossy audio to FLAC does not restore lost information.
- Fetch bounded HTTPS audio artwork, normalize a saved thumbnail and embed cover art where supported. Retain a playable audio file and thumbnail if embedding fails.
- Preserve artist/uploader and thumbnail result metadata across interrupted source saves without changing the six-field Core Data model.
- Open audio in an artwork-first sheet with seek, play/pause, 15-second skips, system volume, Info and native Share. Remove star and overflow controls from the player.
- Keep videos playable inside the app and add fullscreen using the same AVPlayer. Clean up the periodic time observer and audio session on dismissal.

### Files and updates

- Default saved media to the app's Documents directory, visible as `yoink'd` in Files. Keep thumbnails, metadata, queue, staging and work files private.
- Add a persistent folder selection in Settings. Copy and verify managed media before activating a new destination. Preserve unrelated files and reject conflicting names.
- Support save, rollback and deletion across filesystem volumes. Block relocation during imports or unfinished downloads, including paused jobs.
- Download compatible pure-Python yt-dlp, EJS and certifi packages on first use instead of bundling their payloads in the IPA.
- Check for package updates at launch and expose individual updates, Update All, real progress, installed/latest versions and errors in Settings.
- Verify official universal wheels, checksums, sizes, archive entries and adapter compatibility. Publish complete generations and retain the previous working set.
- Freeze the imported extraction generation for the process lifetime. Later updates activate after relaunch rather than replacing modules during a download.
- Keep signed CPython, native extension modules, QuickJS and FFmpeg bundled. These require an app update. Initial extraction-package installation needs connectivity.

### Earlier uncommitted fixes included

- Rename the app to `yoink'd` and the repository slug to `yoinkd`, while retaining bundle, queue and Core Data identifiers.
- Remove duplicate custom/native tab bars and custom touch-control shells. Restore native tab badges and persistent sort/grid/list options.
- Expand accent-only settings to full coordinated light/dark palettes with contrast checks and stale artwork protection.
- Keep Dynamic neutral without a valid selection and avoid caching failed artwork downloads as permanent neutral results.
- Fix the SwiftUI AsyncRenderer colour-provider actor assertion by making the provider nonisolated and capturing immutable RGB values.
- Preserve download attempt identities, pause/cancel/retry checkpoints, metadata commit recovery, extraction callbacks and native framework packaging.
- Preserve both supplied icon appearances and verify their generated package metadata and sizes.

### Verification

See `docs/verification.md` for release-specific tests, artifact metadata and evidence limits. A successful host test or arm64 build does not establish native rendering, touch behavior, playback or crash-free operation. Exact visual fidelity and the new phone flows require signed installation and focused device checks.
