# Test yoink'd 0.5.0 on an iPhone

This version compiles and passes host and archive checks. Native launch, UI, playback, conversion, and background behavior remain unverified.

## Install

Follow the [Arch Linux build instructions](linux-build.md) to generate `xtool/iYoinks.ipa`. Sign it with your existing signing tool and install manually over the working app. The bundle identifier remains `com.maynkudu.iyoinks`. Sign every bundled framework as well as the app, including Python.framework and the 68 Python module frameworks.

Keep the existing app's data while updating. Check that previous library files still appear and play. Settings should show version 0.5.0. The light/dark icon artwork is preserved. The launcher follows the phone's appearance automatically; Settings no longer has a manual icon picker. The new unsigned delivery is `build/yoinkd-0.5.0.ipa`.

## Check a link and choose quality

1. In Library, use the More menu and `yoink!`. Paste [the official Blender YouTube film](https://www.youtube.com/watch?v=aqz-KE-bpKQ).
2. Tap Check link. Confirm that Checking source resolves to a real title, thumbnail, duration, and source information.
3. Open Quality. Confirm that it includes lower resolutions and same-resolution codec/frame-rate variants, plus Best available. Check known, estimated and unavailable source sizes. Use a lower quality for the first test to limit data use.
4. Download. Check the Downloads row for the selected Video quality and real progress. When the transfer completes, find it in History or Library and play the result with sound.
5. Add the same link again, choose Audio and inspect all source bitrate/codec choices. Select FLAC as the saved output, separately from source quality. Confirm that it remains an audio item, has artwork when available and opens the artwork-first player. Repeat with Automatic and another available output.

Higher source video resolutions may need codec conversion. Test a short clip at its highest available quality after the first download succeeds. FLAC output may be larger than compressed source audio.

## Check Instagram and X

- [This Instagram reel](https://www.instagram.com/reel/Chunk8-jurw/) supplies a short portrait video. The checked example is silent. Its 720x1280 frame should display as 720p. Use another public reel with sound for an Instagram audio check.
- [This X post](https://x.com/TopHeroes_/status/2001950365332455490) supplied 720p video and about 128 kbps audio in host checks. Try Video, then Audio. Older X media services may fail even when current posts work.
- Try another public link. A source may require sign-in or reject access. A failed inspection must show an error rather than adding a library file.

## Check interruption and existing actions

1. Cancel an inspection using Cancel Download. Reopen `yoink!` and check a different link. Confirm that an old result does not replace the new link, and that there is no icon or nested control beneath Cancel Download.
2. Pause a source download, then Resume. Some servers resume bytes; others restart. Confirm that the job completes and creates one library item.
3. Cancel an active job. Confirm that it stops, then test Retry. Pause and Cancel also apply while preparing source media. Saving to library is a separate commit phase.
4. Queue two source links. Confirm that the second waits while the first acquires its streams.
5. Background the app during a download. On supported iOS, continued processing may appear. If iOS ends background time, reopening should show a paused job that can resume. Force-quitting can interrupt source work.
6. After a successful download, turn off connectivity and play it. Relaunch the app and play again. Rename, share to Files, and delete the local result through the existing actions.

## Check the native sheet

Check URL keyboard submission, Cancel, quality navigation and selection, long titles, light/dark appearance, and larger text. With VoiceOver, confirm that the link field, Video/Audio picker, quality choices, and queue actions have usable labels. No screenshot or device interaction check has run for this version.

## Search, controls and playback

1. Open Library search, enter text, then Cancel. Confirm that focus ends, the query clears and the heading/menus return. Repeat in History, including cancel with an empty field and keyboard dismissal.
2. Check the shared segmented labels in Library, Settings and `yoink!` at ordinary and accessibility text sizes. Switch tabs repeatedly during the subtle pop. There must be only one native tab bar and no horizontal page slide or touch-blocking overlay.
3. Switch Library to List. Confirm transparent rows without chevrons or overflow buttons. Long press still exposes Share, Rename and Delete. Audio opens a sheet; video opens the embedded player.
4. In audio, test play/pause, seeking, 15-second skips, system volume, Info and Share. Info opens from the bottom and contains file metadata and rename/delete. No star or overflow menu appears. Close the player and confirm it releases playback.
5. In video, seek and pause, enter fullscreen, then exit. The same player should retain position and playback state. Close the detail and confirm playback stops. Repeat opening/dismissing media to check observer cleanup and errors.

## Files and dependencies

1. Open Files, On My iPhone, `yoink'd`. Existing migrated media and new downloads should appear. Metadata, queue and source work must not appear there.
2. In Settings, choose another folder. Confirm verified media moves there, existing items still play and the folder persists after relaunch. An unfinished or paused download disables relocation. Switch back to the default folder. A denied, offline or conflicting destination must preserve the existing files.
3. On a first install, launch with connectivity and check dependency installation in Settings. Without connectivity, initial source extraction should give a retryable dependency error while imports/direct downloads still work. Do not uninstall the existing app to simulate this without first backing it up.
4. Check dependency versions and updates individually, then Update All. Test a connection failure. The previously usable set must remain intact. After extraction has started, a staged update should say it applies after relaunch. Relaunch and check activation. Native-runtime rows must not offer a downloadable binary update.

## Check themes and icons

1. In Settings, select each of Neutral, Sage, Lavender, Amber and Ocean. Check coordinated text, surfaces, selected tabs, primary buttons, filters and progress. Dark content should stay near-black, with restrained tint and readable contrast.
2. Change System, Light and Dark appearance independently of the accent. Check selected controls and button text contrast in both appearances.
3. Choose Dynamic after a fresh launch with no selection. It should use neutral grey. Open a colourful video, return to Library and switch tabs. The accent should follow that thumbnail and remain selected across tabs. Open a different video and confirm a smooth transition without an old result replacing it.
4. Open monochrome artwork or an audio file without artwork. Dynamic should fall back to neutral. Delete the selected item and check that the accent clears. Open the same media repeatedly and confirm there are no repeated colour flashes.
5. With Dynamic selected, inspect a link that has a thumbnail. Check the temporary artwork accent. Cancel, dismiss, or change the input and confirm the previous saved-media accent returns. Navigate into Quality without losing the preview selection.
6. Choose a static theme, close and relaunch the app, then check the saved selection. Repeat with Dynamic, which should remain the selected theme but initially show neutral until a media item is selected.
7. Enable Reduce Motion and larger text. Check all theme controls, History actions, cancel/pause/resume and library actions with VoiceOver.
8. Change the phone's light/dark mode, then foreground the app and check the Home Screen icon. In the xtool build, UIKit may show its normal icon-change confirmation. The icon must follow the phone even if the app has a different forced appearance. In Xcode builds, check the native dark appearance asset. In-app branding follows app appearance.

These are manual checks, not recorded device results. New references are pinned at `reference/ui/premium-pass/`; rendered fidelity has not been measured.

For a failure, report the link, selected Video/Audio quality, iOS version, last visible status, and exact error. A screen recording helps identify layout or transition issues. Keep cookies and signing credentials private.

See the [verification results](verification.md) and [architecture](architecture.md) for the checked build, engine, and background limits.
