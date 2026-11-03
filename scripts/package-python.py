#!/usr/bin/env python3
"""Package CPython extension modules as signed-framework inputs for iOS."""

import argparse
from pathlib import Path
import plistlib
import shutil
import struct
import tempfile
import zipfile


def set_install_name(binary, name):
    data = bytearray(binary.read_bytes())
    if struct.unpack_from("<I", data)[0] != 0xFEEDFACF:
        raise ValueError(f"Expected a thin 64-bit Mach-O module: {binary.name}")
    commands = struct.unpack_from("<I", data, 16)[0]
    cursor = 32
    for _ in range(commands):
        command, size = struct.unpack_from("<II", data, cursor)
        if command == 0xD:
            offset = struct.unpack_from("<I", data, cursor + 8)[0]
            encoded = name.encode() + b"\0"
            capacity = size - offset
            if len(encoded) > capacity:
                raise ValueError(f"The module install name has insufficient space: {binary.name}")
            data[cursor + offset:cursor + size] = encoded.ljust(capacity, b"\0")
            binary.write_bytes(data)
            return
        cursor += size
    raise ValueError(f"Missing Mach-O library ID: {binary.name}")


def package_app(app, project, sdk, arch):
    resources = list(app.glob("**/Resources/Extractor/iyoinks_extract.py"))
    if len(resources) != 1:
        raise ValueError("The app must contain exactly one bundled extractor.")
    resource_root = resources[0].parent.parent
    extractor = resource_root / "Extractor"
    for name in ("iyoinks_dependencies.py", "dependencies.json"):
        if not (extractor / name).is_file():
            raise ValueError("The app is missing its dependency updater or baseline manifest.")
    for module in ("yt_dlp", "yt_dlp_ejs", "certifi"):
        tree = extractor / module
        if tree.exists(): shutil.rmtree(tree)
        for metadata in extractor.glob(module + "-*.dist-info"): shutil.rmtree(metadata)
    python = project / "Packages/YoinksExtractor/Vendor/Python.xcframework"
    identifier = "ios-arm64" if sdk == "iphoneos" else "ios-arm64_x86_64-simulator"
    platform = "iPhoneOS" if sdk == "iphoneos" else "iPhoneSimulator"
    architecture_lib = python / identifier / ("lib-" + arch) / "python3.15"
    destination_lib = resource_root / "Python/lib/python3.15"
    destination_lib.mkdir(parents=True, exist_ok=True)
    for source in architecture_lib.iterdir():
        if source.is_file(): shutil.copy2(source, destination_lib / source.name)
    dynload = destination_lib / "lib-dynload"
    dynload.mkdir(exist_ok=True)
    for obsolete in dynload.iterdir():
        if obsolete.is_file(): obsolete.unlink()
    frameworks = app / "Frameworks"
    frameworks.mkdir(exist_ok=True)
    python_framework = frameworks / "Python.framework"
    if not python_framework.exists():
        shutil.copytree(python / identifier / "Python.framework", python_framework, symlinks=True)
    if not (python_framework / "Python").is_file():
        raise ValueError("The app is missing its Python framework executable.")
    for obsolete in frameworks.glob("py[0-9][0-9][0-9].framework"):
        shutil.rmtree(obsolete)
    count = 0
    for source in sorted((architecture_lib / "lib-dynload").glob("*.so")):
        module = source.name.split(".")[0]
        executable = f"py{count:03d}"
        framework = frameworks / (executable + ".framework")
        framework.mkdir(exist_ok=True)
        binary = framework / executable
        shutil.copy2(source, binary)
        binary.chmod(0o755)
        set_install_name(binary, f"@rpath/{executable}.framework/{executable}")
        marker = dynload / source.name.replace(".so", ".fwork")
        marker.write_text(str(binary.relative_to(app)) + "\n")
        (framework / (executable + ".origin")).write_text(str(marker.relative_to(app)) + "\n")
        info = {
            "CFBundleIdentifier": "com.maynkudu.iyoinks.python." + executable,
            "CFBundleName": module, "CFBundleExecutable": executable,
            "CFBundlePackageType": "FMWK", "CFBundleVersion": "1",
            "CFBundleShortVersionString": "3.15.0", "MinimumOSVersion": "17.0",
            "CFBundleSupportedPlatforms": [platform],
        }
        (framework / "Info.plist").write_bytes(plistlib.dumps(info))
        count += 1
    if not count:
        raise ValueError("No CPython extension modules were found.")
    for name in ("Headers", "PrivateHeaders", "Modules"):
        directory = python_framework / name
        if directory.is_dir(): shutil.rmtree(directory)
    if any(resource_root.rglob("*.so")):
        raise ValueError("Unpackaged Python binary modules remain in Resources.")
    return count


def package_ipa(path, project, sdk, arch):
    with tempfile.TemporaryDirectory(prefix="iyoinks-runtime-") as temporary:
        root = Path(temporary)
        with zipfile.ZipFile(path) as archive:
            for info in archive.infolist():
                archive.extract(info, root)
                mode = info.external_attr >> 16
                if mode and not info.is_dir(): (root / info.filename).chmod(mode & 0o777)
        apps = list((root / "Payload").glob("*.app"))
        if len(apps) != 1: raise ValueError("Expected one application in the IPA.")
        count = package_app(apps[0], project, sdk, arch)
        replacement = path.with_suffix(".runtime.ipa")
        with zipfile.ZipFile(replacement, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
            for file in sorted(root.rglob("*")):
                if file.is_file(): archive.write(file, file.relative_to(root))
        replacement.replace(path)
    print(f"Packaged {count} Python modules in {path}")


def main():
    parser = argparse.ArgumentParser()
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--ipa", type=Path)
    target.add_argument("--app", type=Path)
    parser.add_argument("--sdk", choices=("iphoneos", "iphonesimulator"), default="iphoneos")
    parser.add_argument("--arch", choices=("arm64", "x86_64"), default="arm64")
    args = parser.parse_args()
    project = Path(__file__).resolve().parent.parent
    if args.ipa: package_ipa(args.ipa.resolve(), project, args.sdk, args.arch)
    else: print(f"Packaged {package_app(args.app.resolve(), project, args.sdk, args.arch)} Python modules")


if __name__ == "__main__": main()
