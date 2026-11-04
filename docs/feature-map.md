# Feature map

What each feature does for the person using it, how to reach it, and how to verify it. This mirrors
the code; update it in the same change as the feature. Verification steps assume the
`yoinkd-verify` skill (`.claude/skills/yoinkd-verify/SKILL.md`).

| Feature | Verified by |
| --- | --- |
| [Add a link](#add-a-link) | `add-video`, `add-audio` |
| [yoinkd:// links](#yoinkd-links) | every download flow |
| [Share to yoink'd](#share-to-yoinkd) | `share-to-yoinkd` |
| [Shortcuts and Siri](#shortcuts-and-siri) | manual |
| [Live Activities](#live-activities) | manual |
| [Save to Photos](#save-to-photos) | manual |
| [Downloads queue](#downloads-queue) | `pause-resume`, `relaunch-mid-download` |
| [Library and playback](#library-and-playback) | `play-saved-media` |
| [Appearance and themes](#appearance-and-themes) | `switch-theme` |
| [Import files](#import-files) | not yet |
| [History](#history) | not yet |
| [Save folder](#save-folder) | not yet |
| [Extractor packages](#extractor-packages) | `yoinkctl state --deps`, nightly canary |

## Add a link

Paste a video or audio link, tap **Check link** to see the title, length, formats and download size,
choose Video or Audio and a quality, then **yoink!**. Nothing downloads before **yoink!**.

- **Reach it:** the **yoink!** button on the empty Library or Downloads screen, or **Add media** in
  the Library toolbar. `AddLinkView.swift`.
- **Verify:** `argent flow run add-video`, `argent flow run add-audio`. Then
  `scripts/yoinkctl state --library` shows the saved file and its size.
- **Gotchas:** sources needing sign-in (Reddit) fail with the sign-in message. TikTok fails in yt-dlp
  2026.10.26 itself. YouTube AV1 video fails to process on the simulator.

## yoinkd:// links

`yoinkd://add?url=<encoded link>&kind=audio` opens the yoink! sheet with the link filled in and the
kind preferred after the check. It never downloads by itself. A link that arrives while the library is
opening waits until it can be shown.

- **Reach it:** any app opening the URL; the share extension uses it.
- **Verify:** `scripts/yoinkctl link <url> --kind audio`, open the printed link with Argent
  `open-url`, and check the sheet shows the link. `CaptureRequestTests` cover parsing.
- **Gotchas:** iOS asks "Open in yoink'd?" when the app isn't in front. A link can't open the sheet
  over another sheet (the player).

## Share to yoink'd

Share a page from Safari, Instagram or another app to **yoink'd** in the share sheet, pick Video or
Audio, tap **yoink!**, and the app opens with the link filled in. If iOS won't open the app, the card
says "Saved. Open yoink'd to finish." and the link waits until the next launch.

- **Reach it:** the share sheet's app row. The `YoinkShare` extension target, `YoinkShare/`.
- **Verify:** `argent flow run share-to-yoinkd`. `scripts/yoinkctl state --inbox` lists links waiting
  in the App Group inbox; `scripts/yoinkctl build --force-share-fallback` builds an extension that
  never opens the app, to test the waiting path.
- **Conditions:** needs the App Group `group.com.maynkudu.iyoinks` on both targets. Without it the
  inbox is off and only the direct handoff works.
- **Gotchas:** opening the app from an extension is unofficial (responder chain); the inbox covers
  it if Apple blocks it. Unverified on a phone and in the real Instagram app.

## Shortcuts and Siri

**Add a link** opens the yoink! sheet filled in, like a shared link. **Download** checks the link and
adds it to Downloads at the best quality, without the sheet, for automations the user builds.

- **Reach it:** Shortcuts → Apps → yoink'd, Spotlight, or Siri ("Download with yoink'd").
  `iYoinks/App/AppIntents.swift`.
- **Verify:** run **Download** in Shortcuts with a link, then
  `scripts/yoinkctl wait --job newest --phase completed`. The built app's
  `Metadata.appintents/extract.actionsdata` lists both intents.
- **Gotchas:** errors appear in Shortcuts as written (for example the sign-in message). The link
  prompt is drawn by another process, so `await-ui-element` doesn't see it.

## Live Activities

A running download shows its title, status, progress and a pause or resume button on the Lock Screen
and in the Dynamic Island. It ends when the download finishes.

- **Reach it:** start a download, then leave the app. `YoinkActivity/`, `Shared/DownloadActivity.swift`,
  `iYoinks/Services/DownloadActivities.swift`.
- **Verify:** `argent flow run start-long-download`, press Home, check the island, long-press it to
  expand, tap Resume or Pause, and watch `scripts/yoinkctl state --jobs`.
- **Gotchas:** on the simulator iOS gives no background time, so the download pauses with "Paused
  because iOS ended background time" and a resumed job waits as Queued until the app is in front.

## Save to Photos

Adds a saved video to the photo library, only when chosen. Uses add-only access.

- **Reach it:** a video's **Info** → **Save to Photos**, or its **…** menu in the Library grid.
- **Verify:** the system asks once for add-only access; the newest file in the simulator's
  `data/Media/DCIM/100APPLE` matches the library file's size.
- **Gotchas:** formats Photos can't open say so and point to Share file. Audio has no Photos action.

## Downloads queue

Running and waiting downloads with progress, pause and resume. Two source downloads run at once.
Quitting the app pauses running downloads; they come back paused with "Paused when yoink'd closed.
Resume to continue."

- **Reach it:** the **Downloads** tab.
- **Verify:** `argent flow run pause-resume`, `argent flow run relaunch-mid-download`. Watch a job
  with `scripts/yoinkctl wait --job newest --phase completed`.
- **Gotchas:** the row's controls move between the downloading and paused layouts. The queue
  journal (`queue.json`) can lag the in-memory byte count.

## Library and playback

Saved videos and audio, sortable and filterable, with a player that shows artwork, position,
format, and 15-second skips.

- **Reach it:** the **Library** tab; tap an item.
- **Verify:** `argent flow run play-saved-media` (playback reaches 0:03).
  `scripts/yoinkctl state --library` lists items and whether each file exists.
- **Gotchas:** audio artwork showed in the player but the grid showed a waveform after a relaunch.
  Not investigated.

## Appearance and themes

System, Light or Dark appearance and six accent themes (Neutral, Sage, Lavender, Amber, Ocean,
Dynamic). Dynamic follows the selected media's artwork.

- **Reach it:** **Settings** → Appearance.
- **Verify:** `argent flow run switch-theme`. `scripts/yoinkctl state --prefs` shows `appearance` and
  `accentTheme`.
- **Gotchas:** preferences reach disk a few seconds after the tap.

## Import files

Import videos or audio from Files into the library.

- **Reach it:** **Import files** on the empty Library, or **Add media**.
- **Verify:** not covered yet. Needs a file in the simulator's Files app first.

## History

Finished, failed and cancelled downloads, with filter, sort and display options.

- **Reach it:** the **History** tab.
- **Verify:** not covered yet. `scripts/yoinkctl state --jobs` lists the same jobs.

## Save folder

Media saves to **On My iPhone / yoink'd** or a folder the user picks.

- **Reach it:** **Settings** → Saved media → **Choose folder** / **Use app folder**.
- **Verify:** not covered yet. Picking a folder needs the system document picker.

## Extractor packages

yt-dlp, yt-dlp-ejs and certifi download on the phone as verified generations with rollback, so site
fixes arrive without an app update.

- **Reach it:** **Settings** → Media links.
- **Verify:** `scripts/yoinkctl state --deps` shows the current generation and versions. The nightly
  canary (`.github/workflows/canary.yml`) runs real links against the pinned and latest yt-dlp.
