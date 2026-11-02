# Light and dark icons

The supplied `reference/ui/light-icon.png` stays unchanged. `AppIcon.appiconset/AppIcon.png` composites it over white, then resizes it to 1024x1024 RGB with Lanczos filtering. `Resources/BrandMarkLight.png` resizes the supplied transparent artwork to 512x512 without flattening its alpha channel.

The original dark launcher PNG is preserved byte-for-byte as `AppIcon.appiconset/AppIconDark.png`. The separate `AppIconDark.appiconset` uses the same bytes. `Resources/BrandMark.png` stays unchanged.

## Xcode

The primary `AppIcon` set includes the real dark artwork in its `luminosity: dark` appearance slot. On supported iOS versions, the Home Screen's icon appearance determines which slot renders. The app's own appearance and accent preference do not determine the Home Screen mode.

Keep `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`. Set `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES = AppIconDark` in both target configurations to compile the separate alternate set and generate its plist entry. No include-all-icons setting is required for this named set.

The existing asset catalog and Resources folder registrations include these new files. No individual PNG registration is needed. Leave `CFBundleIcons` and `IYoinksUsesAlternateIconFallback` out of the source `Info.plist`; Xcode generates its icon metadata and does not need the fallback picker.

## Linux xtool

The installed xtool 1.23.0 `PackLib/Packer.swift` copies `iconPath` unchanged to the app root and sets the generated plist's `CFBundleIconFile` to `AppIcon`. It does not compile this appearance catalog.

After xtool and Python-runtime packaging, `scripts/build-native.sh` runs `doc-python scripts/package-icons.py --ipa xtool/iYoinks.ipa`. This uses Pillow from the existing document environment, not Arch's system Python. It must run before signing.

The step adds both 1024px originals and each appearance's 20, 29, 40 and 60-point PNGs at 2x and 3x. It merges `CFBundlePrimaryIcon` and `CFBundleAlternateIcons` into the generated plist, retaining unrelated keys, primary metadata and other alternate entries. It inserts `IYoinksUsesAlternateIconFallback = true` only in this IPA. Existing ZIP entry permissions and unrelated payload bytes are retained. Running it again produces the same payload.

The primary icon is light. The alternate dictionary key is exactly `AppIconDark`, not `Dark`.

## Explicit selection contract

Settings shows the icon picker only when `Bundle.main.object(forInfoDictionaryKey: "IYoinksUsesAlternateIconFallback") as? Bool == true`. It calls UIKit only after the user explicitly chooses an icon:

- Dark uses `UIApplication.shared.setAlternateIconName("AppIconDark", completionHandler: ...)`.
- Light uses `UIApplication.shared.setAlternateIconName(nil, completionHandler: ...)`.
- Check `supportsAlternateIcons`, compare `alternateIconName`, prevent concurrent requests and show any completion error. The completion callback is not guaranteed to run on the main queue.

Do not synchronize the launcher on appearance changes, accent changes or launch. Icon changes can display system confirmation. Read `alternateIconName` for the current selection instead of assuming a request succeeded.

xtool's loose PNGs do not provide automatic native luminosity switching. Home Screen customization, tinted rendering, alternate-icon support, confirmation and persistence need a phone check. An explicit light choice selects the primary artwork; it does not override system Home Screen effects.

## Checks

`python3 scripts/check-project.py` verifies both catalogs, PNG integrity and opaque launcher sources, both brand images, preserved dark hashes, absence of the fallback flag in source and the Xcode alternate setting. `python3 scripts/check-ipa.py xtool/iYoinks.ipa` checks the actual ZIP, both masters and all sixteen scaled PNGs, the explicit alternate plist entry, fallback flag and bundled brand bytes alongside existing executable/runtime checks.

Packaging checks do not establish native rendering or UIKit behavior. Xcode catalog compilation still needs an Apple toolchain.
