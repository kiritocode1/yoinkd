# Test iYoinks 0.3.0 on an iPhone

This version compiles and passes host and archive checks. Native launch, UI, playback, conversion, and background behavior remain unverified.

## Install

Follow the [Arch Linux build instructions](linux-build.md) to generate `xtool/iYoinks.ipa`. Sign it with your existing signing tool and install manually over the working app. The bundle identifier remains `com.maynkudu.iyoinks`. Sign every bundled framework as well as the app, including Python.framework and the 68 Python module frameworks.

Keep the existing app's data while updating. Check that previous library files still appear and play. Settings should show version 0.3.0. The icon and Y mark should stay the same.

## Check a link and choose quality

1. In Library, use the plus menu and Add link. Paste [the official Blender YouTube film](https://www.youtube.com/watch?v=aqz-KE-bpKQ).
2. Tap Check link. Confirm that Checking source resolves to a real title, thumbnail, duration, and source information.
3. Open Quality. Confirm that it contains the available video resolutions from 360p through the source maximum and Best available. Use 360p for the first test to limit data use.
4. Download. Check the Downloads row for the selected Video quality and real progress. Wait for Saved to library, then play the result with sound.
5. Add the same link again, choose Audio, and inspect the bitrate and codec choices. Download Best available. Confirm that its library entry is audio and plays.

Higher source video resolutions may need codec conversion. Test a short clip at its highest available quality after the first download succeeds. FLAC output may be larger than compressed source audio.

## Check Instagram and X

- [This Instagram reel](https://www.instagram.com/reel/Chunk8-jurw/) supplies a short portrait video. The checked example is silent. Its 720x1280 frame should display as 720p. Use another public reel with sound for an Instagram audio check.
- [This X post](https://x.com/TopHeroes_/status/2001950365332455490) supplied 720p video and about 128 kbps audio in host checks. Try Video, then Audio. Older X media services may fail even when current posts work.
- Try another public link. A source may require sign-in or reject access. A failed inspection must show an error rather than adding a library file.

## Check interruption and existing actions

1. Cancel an inspection. Reopen Add link and check a different link. Confirm that an old result does not replace the new link.
2. Pause a source download, then Resume. Some servers resume bytes; others restart. Confirm that the job completes and creates one library item.
3. Cancel an active job. Confirm that it stops, then test Retry. Pause and Cancel also apply while preparing source media. Saving to library is a separate commit phase.
4. Queue two source links. Confirm that the second waits while the first acquires its streams.
5. Background the app during a download. On supported iOS, continued processing may appear. If iOS ends background time, reopening should show a paused job that can resume. Force-quitting can interrupt source work.
6. After a successful download, turn off connectivity and play it. Relaunch the app and play again. Rename, share to Files, and delete the local result through the existing actions.

## Check the native sheet

Check URL keyboard submission, Cancel, quality navigation and selection, long titles, light/dark appearance, and larger text. With VoiceOver, confirm that the link field, Video/Audio picker, quality choices, and queue actions have usable labels. No screenshot or device interaction check has run for this version.

For a failure, report the link, selected Video/Audio quality, iOS version, last visible status, and exact error. A screen recording helps identify layout or transition issues. Keep cookies and signing credentials private.

See the [verification results](verification.md) and [architecture](architecture.md) for the checked build, engine, and background limits.
