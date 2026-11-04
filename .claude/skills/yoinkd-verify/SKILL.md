---
name: yoinkd-verify
description: Build, run and verify yoink'd on an iOS Simulator. Use before reporting any change to the app as working, when reproducing a bug report, or when adding a feature that needs a verification flow. Covers yoinkctl, the saved Argent flows in .argent/flows, and the known simulator gotchas.
---

# Verify yoink'd on the simulator

A change is done when the app shows it working on a simulator and `yoinkctl` confirms the app's own
state. A passing build or unit test is not enough. Find the feature in `docs/feature-map.md` first.

## Tools

- **`scripts/yoinkctl`** sets up the app and reads its state as JSON. It never taps. Run
  `scripts/yoinkctl --help` and `scripts/yoinkctl <command> --help` for every option.
- **Argent** drives the UI. Read the Argent rule and `argent-device-interact` before tapping.
- **Saved flows** in `.argent/flows/` replay the main journeys. Each one decides pass or fail with a
  `yoinkctl` check script in `.argent/flows/checks/`, not with a screenshot.

## Loop

```sh
scripts/yoinkctl doctor                      # every failed check names its fix
scripts/yoinkctl build                       # simulator build, arm64, signed ad hoc
scripts/yoinkctl install --boot              # or boot with Argent first
argent flow run add-video --device <udid>    # or flow-execute from an agent
scripts/yoinkctl state                       # queue, library, extractor packages, inbox, preferences
```

For a change with no flow, drive it with Argent, then prove the result with `yoinkctl state` or
`yoinkctl wait --job newest --phase completed`. Add a flow when the journey is worth repeating.

To fill in the yoink! sheet without typing, print a link with
`scripts/yoinkctl link <media url> --kind audio` and open it with Argent `open-url`.

## Flows

| Flow | Proves | Time |
| --- | --- | --- |
| `add-video` | Instagram reel → check → download → saved video in the library | ~17 s |
| `add-audio` | YouTube → kind=audio preferred → saved FLAC in the library | ~18 s |
| `play-saved-media` | Library item opens the player and playback reaches 0:03 | ~21 s |
| `switch-theme` | Dark + Lavender saved in preferences, then defaults restored | ~27 s |
| `pause-resume` | Pause holds the byte count; resume continues past it | ~24 s |
| `relaunch-mid-download` | Quitting mid-download brings the job back paused with the closed message | ~23 s |
| `share-to-yoinkd` | Safari share sheet → extension → app → saved video, inbox empty | ~32 s |
| `start-long-download` | Shared setup for the two above. Not a test on its own | |

Every e2e flow starts with `checks/reset.mjs`, which clears the queue, library, media and inbox
(`yoinkctl reset --keep-deps`). Flows pin an iPhone 17 on iOS 27.2: their point taps assume that
screen.

## Gotchas

- **Flow selectors can't see SwiftUI views.** `tap:`/`await:` resolve the UIView tree, where only
  UIKit elements exist (tab buttons, the large title). SwiftUI buttons and text don't. Gate steps
  with `tool: await-ui-element` (accessibility tree) and tap SwiftUI controls by point, with an echo
  naming the control. `tap: { text: "Library", role: Button }` works for tab buttons.
- **Tap after the screen settles.** A sheet sliding up or a scroll finishing swallows taps. Give the
  tap after a presentation or swipe `delayMs: 800`.
- **Download rows move.** The row's button is at y≈0.25 while downloading and y≈0.30 when paused
  (the paused row is taller). Wait with a `yoinkctl` check for the phase before tapping.
- **UserDefaults lag.** Appearance and theme reach the preferences file a few seconds after the tap.
  Checks poll for up to 15 s.
- **AV1 video fails on the simulator.** YouTube often picks AV1; the simulator can't encode HEVC with
  VideoToolbox, so processing fails with "could not be prepared". Use the Instagram reel or audio for
  completed-download tests. Unverified on a phone.
- **Keep signing on and ARCHS=arm64.** `CODE_SIGNING_ALLOWED=NO` builds install but are killed at
  launch (code-signing invalid-page). SwiftFFmpeg has no x86_64 simulator slice.
- **The bundled folder is `AppResources`.** A top-level `Resources` folder breaks install ("Missing
  bundle ID").
- **Simulator entitlements live in the binary.** Xcode writes them into `__entitlements` at build
  time; re-signing afterwards changes nothing. Pass `CODE_SIGN_ENTITLEMENTS=` to `xcodebuild`.
- **Two extensions are embedded.** `YoinkShare` (share sheet) and `YoinkActivity` (Live Activity).
  `scripts/yoinkctl build --force-share-fallback` builds a share extension that never opens the app,
  to test the inbox; rebuild without it afterwards.
- **System UI is another process.** The share sheet's app row, Shortcuts prompts and permission
  alerts aren't in the app's view tree. Wait with `await-ui-element` and tap by point.
- **Swipe twice to reach the sheet's yoink!.** One swipe sometimes stops short and the tap misses.
- **Instagram sometimes asks for sign-in** on a logged-out request for a minute or two after many
  fetches. Retry before treating it as a regression.
- **Logs.** `scripts/yoinkctl logs` shows the app's `com.maynkudu.iyoinks` subsystem; `--all` shows
  everything from the app and the share extension. Only while the simulator runs.

## When something hangs

Sample the app before guessing: `sample $(pgrep -f "iYoinks.app/iYoinks$") 3`. A thread waiting in
`NativeMediaProcessor.execute` holds the single media lock; find what the other thread waits on. For
descriptor leaks, `.plannotator/media-hang/fdtrace.c` traces `pipe`/`dup`/`dup2`/`fcntl` with call
stacks when loaded through `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES`.

## Keep this current

When a flow breaks because the UI changed, fix the flow and this table in the same change. When a
new gotcha costs more than one retry, add it here.
