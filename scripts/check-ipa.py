#!/usr/bin/env python3
"""Check the actual native IPA and its Python framework mappings. Does not run iOS."""

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import struct
import zipfile


PROJECT = Path(__file__).resolve().parent.parent


def macho(data):
    assert len(data) >= 32, "Truncated Mach-O header"
    container_magic = struct.unpack_from(">I", data)[0]
    if container_magic in (0xCAFEBABE, 0xBEBAFECA, 0xCAFEBABF, 0xBFBAFECA):
        endian = ">" if container_magic in (0xCAFEBABE, 0xCAFEBABF) else "<"
        wide = container_magic in (0xCAFEBABF, 0xBFBAFECA)
        slice_count = struct.unpack_from(endian + "I", data, 4)[0]
        assert slice_count == 1, "Expected exactly one arm64 slice in the iOS binary"
        entry_format = endian + ("IIQQII" if wide else "IIIII")
        table_end = 8 + struct.calcsize(entry_format)
        assert table_end <= len(data), "Truncated FAT architecture table"
        cpu, subtype, offset, slice_size, alignment, *_ = struct.unpack_from(entry_format, data, 8)
        assert cpu == 0x100000C, "Expected an arm64 FAT slice"
        assert alignment < 64 and offset % (1 << alignment) == 0, "Invalid FAT slice alignment"
        assert offset >= table_end and slice_size >= 32 and offset + slice_size <= len(data), "Invalid FAT slice bounds"
        data = data[offset:offset + slice_size]
        assert struct.unpack_from("<I", data, 8)[0] == subtype, "FAT slice subtype disagrees with Mach-O header"
    magic, cpu, _, kind, count, _, _, _ = struct.unpack_from("<8I", data)
    assert magic == 0xFEEDFACF and cpu == 0x100000C, "Expected a thin arm64 Mach-O"
    cursor = 32
    result = {"kind": kind, "dependencies": [], "signature_command": False}
    for _ in range(count):
        command, size = struct.unpack_from("<II", data, cursor)
        assert size >= 8 and cursor + size <= len(data)
        if command == 0x32:
            platform, minimum, sdk, _ = struct.unpack_from("<4I", data, cursor + 8)
            result.update(platform=platform, minimum=version(minimum), sdk=version(sdk))
        if command in (0xC, 0xD, 0x80000018, 0x80000023):
            offset = struct.unpack_from("<I", data, cursor + 8)[0]
            name = data[cursor + offset:cursor + size].split(b"\0")[0].decode()
            if command == 0xD: result["install_name"] = name
            else: result["dependencies"].append(name)
        result["signature_command"] |= command == 0x1D
        cursor += size
    return result


def version(value): return [value >> 16, (value >> 8) & 255, value & 255]


def check(path):
    spec = importlib.util.spec_from_file_location("project_check", PROJECT / "scripts/check-project.py")
    project_check = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(project_check)
    icons = project_check.PACKAGE_ICONS
    source_info = plistlib.loads((PROJECT / "iYoinks/Info.plist").read_bytes())
    prefix = "Payload/iYoinks.app/"
    with zipfile.ZipFile(path) as archive:
        assert archive.testzip() is None, "IPA CRC failure"
        names = set(archive.namelist())
        assert len(names) == len(archive.namelist()), "Duplicate IPA entries"
        info = plistlib.loads(archive.read(prefix + "Info.plist"))
        for key in ("CFBundleShortVersionString", "CFBundleVersion", "MinimumOSVersion", "BGTaskSchedulerPermittedIdentifiers", "UIBackgroundModes"):
            assert info[key] == source_info[key], key
        assert info["CFBundleIdentifier"] == "com.maynkudu.iyoinks"
        assert info["CFBundlePackageType"] == "APPL"
        assert info["UIDeviceFamily"] == [1]
        assert info["CFBundleSupportedPlatforms"] == ["iPhoneOS"]
        assert "UIDesignRequiresCompatibility" not in info
        executable = macho(archive.read(prefix + info["CFBundleExecutable"]))
        assert executable["kind"] == 2 and executable["platform"] == 2
        assert executable["minimum"] == [17, 0, 0]
        assert executable["sdk"] >= [26, 0, 0]
        assert "@rpath/Python.framework/Python" in executable["dependencies"]
        assert archive.read(prefix + "AppIcon.png") == (PROJECT / "iYoinks/Assets.xcassets/AppIcon.appiconset/AppIcon.png").read_bytes()
        assert info[icons.FALLBACK_KEY] is True, "Missing xtool icon fallback flag"
        assert info["CFBundleIconFile"] == "AppIcon"
        packaged_icons = info["CFBundleIcons"]
        assert packaged_icons["CFBundlePrimaryIcon"]["CFBundleIconFiles"] == icons.icon_files("AppIcon")
        assert packaged_icons["CFBundleAlternateIcons"][icons.ALTERNATE_NAME]["CFBundleIconFiles"] == icons.icon_files(icons.ALTERNATE_NAME)
        for icon_name in ("AppIcon", icons.ALTERNATE_NAME):
            data = archive.read(prefix + icon_name + ".png")
            assert data == (icons.ICON_SET / (icon_name + ".png")).read_bytes()
            icons.check_png(data, 1024, opaque=True)
            for points, base in zip(icons.ICON_POINTS, icons.icon_files(icon_name)):
                for scale in icons.ICON_SCALES:
                    icons.check_png(archive.read(prefix + f"{base}@{scale}x.png"), points * scale, opaque=True)
        scripts = [name for name in names if name.endswith("/Resources/Extractor/iyoinks_extract.py")]
        assert len(scripts) == 1
        resource_root = scripts[0].removesuffix("Extractor/iyoinks_extract.py")
        assert archive.read(scripts[0]) == (PROJECT / "iYoinks/Resources/Extractor/iyoinks_extract.py").read_bytes()
        assert archive.read(resource_root + "BrandMark.png") == (PROJECT / "iYoinks/Resources/BrandMark.png").read_bytes()
        light_brand = archive.read(resource_root + "BrandMarkLight.png")
        assert light_brand == (PROJECT / "iYoinks/Resources/BrandMarkLight.png").read_bytes()
        icons.check_png(light_brand, 512)
        for relative in ("Python/lib/python3.15/encodings/__init__.py", "Extractor/yt_dlp/__init__.py",
                         "Extractor/yt_dlp_ejs/__init__.py", "Extractor/certifi/cacert.pem", "Legal/ThirdPartyNotices.txt"):
            assert resource_root + relative in names, relative
        assert not any(name.endswith(".so") or "/__pycache__/" in name for name in names)

        expected = PROJECT / "Packages/YoinksExtractor/Vendor/Python.xcframework/ios-arm64/lib-arm64/python3.15/lib-dynload"
        modules = sorted(expected.glob("*.so"))
        assert modules
        for index, source in enumerate(modules):
            name = f"py{index:03d}"
            binary = f"Frameworks/{name}.framework/{name}"
            marker = resource_root + "Python/lib/python3.15/lib-dynload/" + source.name.replace(".so", ".fwork")
            assert archive.read(marker).decode().strip() == binary
            origin = prefix + f"Frameworks/{name}.framework/{name}.origin"
            assert archive.read(origin).decode().strip() == marker.removeprefix(prefix)
            framework = plistlib.loads(archive.read(prefix + f"Frameworks/{name}.framework/Info.plist"))
            assert framework["CFBundleExecutable"] == name
            details = macho(archive.read(prefix + binary))
            assert details["kind"] == 6 and details["platform"] == 2
            assert details["minimum"] <= [17, 0, 0]
            assert details["install_name"] == "@rpath/" + binary.removeprefix("Frameworks/")
            for dependency in details["dependencies"]:
                if dependency.startswith("@rpath/") and not dependency.startswith("@rpath/libswift"):
                    assert prefix + "Frameworks/" + dependency.removeprefix("@rpath/") in names, dependency
        python = macho(archive.read(prefix + "Frameworks/Python.framework/Python"))
        assert python["kind"] == 6 and python["platform"] == 2 and python["minimum"] <= [17, 0, 0]
        assert python["install_name"] == "@rpath/Python.framework/Python"
        for forbidden in ("Headers/", "PrivateHeaders/", "Modules/"):
            assert not any(name.startswith(prefix + "Frameworks/Python.framework/" + forbidden) for name in names)
        unpacked_bytes = sum(item.file_size for item in archive.infolist())
    return {
        "project": project_check.check(), "archive": str(path.resolve()),
        "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
        "archive_size_bytes": path.stat().st_size, "unpacked_size_bytes": unpacked_bytes,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "architecture": "arm64", "minimum_ios": executable["minimum"], "linked_sdk": executable["sdk"],
        "python_module_frameworks": len(modules), "python_framework_mappings": "passed", "zip_crc": "passed",
        "branding_matches_source": True, "bundled_extractor_matches_source": True,
        "launcher_icon_pngs": "passed; both masters and eight sizes per appearance are opaque RGB",
        "alternate_icon_name": icons.ALTERNATE_NAME,
        "alternate_icon_fallback_flag": info[icons.FALLBACK_KEY],
        "apple_signing": "not_established_by_this_check", "native_runtime": "unverified; manual iPhone review required",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path, nargs="?", default=PROJECT / "xtool/iYoinks.ipa")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    result = json.dumps(check(args.ipa), indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(result)
    print(result, end="")


if __name__ == "__main__": main()
