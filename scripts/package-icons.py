#!/usr/bin/env python3
"""Package explicit alternate icons into an unsigned xtool IPA. Run with doc-python."""

import argparse
import io
from pathlib import Path
import plistlib
import struct
import tempfile
import zipfile
import zlib


PROJECT = Path(__file__).resolve().parent.parent
ICON_SET = PROJECT / "iYoinks/Assets.xcassets/AppIcon.appiconset"
ALTERNATE_NAME = "AppIconDark"
FALLBACK_KEY = "IYoinksUsesAlternateIconFallback"
ICON_POINTS = (20, 29, 40, 60)
ICON_SCALES = (2, 3)


def check_png(data, size, opaque=False):
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "Invalid PNG signature"
    cursor = 8
    chunks = []
    compressed = bytearray()
    while cursor < len(data):
        assert cursor + 12 <= len(data), "Truncated PNG chunk"
        length, kind = struct.unpack_from(">I4s", data, cursor)
        end = cursor + 12 + length
        assert end <= len(data), "Truncated PNG payload"
        payload = data[cursor + 8:end - 4]
        checksum = struct.unpack_from(">I", data, end - 4)[0]
        assert zlib.crc32(kind + payload) == checksum, "PNG CRC failure"
        if kind == b"IHDR":
            assert not chunks and length == 13, "Invalid PNG header"
            width, height, depth, color, compression, filtering, interlace = struct.unpack(">IIBBBBB", payload)
            assert (width, height) == (size, size), f"Expected {size}x{size} PNG"
            assert depth == 8 and color in (2, 6), "Expected 8-bit RGB or RGBA PNG"
            assert (compression, filtering, interlace) == (0, 0, 0), "Unsupported PNG encoding"
        if kind == b"IDAT":
            compressed.extend(payload)
        chunks.append(kind)
        cursor = end
        if kind == b"IEND":
            assert length == 0 and cursor == len(data), "Invalid PNG ending"
            break
    assert chunks and chunks[0] == b"IHDR" and chunks[-1] == b"IEND", "Incomplete PNG"
    assert chunks.count(b"IHDR") == 1 and compressed, "Missing or duplicate PNG data"
    if opaque:
        assert color == 2 and b"tRNS" not in chunks, "Launcher PNG must be opaque RGB"
    stride = width * (3 if color == 2 else 4) + 1
    pixels = zlib.decompress(compressed)
    assert len(pixels) == stride * height, "Invalid PNG scanline length"
    assert all(pixels[offset] <= 4 for offset in range(0, len(pixels), stride)), "Invalid PNG filter"


def icon_files(name):
    return [f"{name}{points}x{points}" for points in ICON_POINTS]


def icon_images():
    from PIL import Image

    images = {}
    for name in ("AppIcon", ALTERNATE_NAME):
        source = (ICON_SET / (name + ".png")).read_bytes()
        check_png(source, 1024, opaque=True)
        images[name + ".png"] = source
        with Image.open(io.BytesIO(source)) as image:
            for points, base in zip(ICON_POINTS, icon_files(name)):
                for scale in ICON_SCALES:
                    resized = image.resize((points * scale, points * scale), Image.Resampling.LANCZOS)
                    output = io.BytesIO()
                    resized.save(output, format="PNG")
                    data = output.getvalue()
                    check_png(data, points * scale, opaque=True)
                    images[f"{base}@{scale}x.png"] = data
    return images


def icon_info(info):
    result = dict(info)
    icons = dict(result.get("CFBundleIcons", {}))
    primary = dict(icons.get("CFBundlePrimaryIcon", {}))
    primary["CFBundleIconFiles"] = icon_files("AppIcon")
    icons["CFBundlePrimaryIcon"] = primary
    alternates = dict(icons.get("CFBundleAlternateIcons", {}))
    dark = dict(alternates.get(ALTERNATE_NAME, {}))
    dark["CFBundleIconFiles"] = icon_files(ALTERNATE_NAME)
    alternates[ALTERNATE_NAME] = dark
    icons["CFBundleAlternateIcons"] = alternates
    result["CFBundleIcons"] = icons
    result[FALLBACK_KEY] = True
    return result


def package_ipa(path):
    images = icon_images()
    prefix = "Payload/iYoinks.app/"
    plist_path = prefix + "Info.plist"
    with tempfile.TemporaryDirectory(prefix="iyoinks-icons-", dir=path.parent) as temporary:
        replacement = Path(temporary) / path.name
        with zipfile.ZipFile(path) as archive:
            names = archive.namelist()
            if len(names) != len(set(names)):
                raise ValueError("Duplicate paths in the IPA")
            if any("/_CodeSignature/" in name or name.endswith("/embedded.mobileprovision") for name in names):
                raise ValueError("Package icons before signing the IPA")
            info = plistlib.loads(archive.read(plist_path))
            if info.get("CFBundleIdentifier") != "com.maynkudu.iyoinks":
                raise ValueError("Expected the iYoinks app")
            if info.get("CFBundleIconFile") != "AppIcon":
                raise ValueError("Expected xtool's AppIcon primary configuration")
            if archive.read(prefix + "AppIcon.png") != images["AppIcon.png"]:
                raise ValueError("Rebuild the IPA with the current light icon before packaging")
            entries = {prefix + name: data for name, data in images.items()}
            entries[plist_path] = plistlib.dumps(icon_info(info))
            with zipfile.ZipFile(replacement, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as output:
                output.comment = archive.comment
                for entry in archive.infolist():
                    data = entries.pop(entry.filename) if entry.filename in entries else archive.read(entry)
                    output.writestr(entry, data)
                for name, data in entries.items():
                    output.writestr(name, data)
        replacement.replace(path)
    print(f"Packaged light primary and {ALTERNATE_NAME} alternate icons in {path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ipa", required=True, type=Path)
    args = parser.parse_args()
    package_ipa(args.ipa.resolve())


if __name__ == "__main__":
    main()
