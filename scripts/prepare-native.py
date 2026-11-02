#!/usr/bin/env python3
"""Fetch pinned native dependencies, verify hashes, and prepare bundled Python resources."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.parse
import urllib.request
import zipfile


PROJECT = Path(__file__).resolve().parent.parent
SCRIPTS = PROJECT / "scripts"
MANIFEST = SCRIPTS / "native-dependencies.json"
RESOURCES = PROJECT / "iYoinks/Resources"


def digest(path):
    with path.open("rb") as source: return hashlib.file_digest(source, "sha256").hexdigest()


def acquire(entry, cache, offline):
    name = Path(urllib.parse.urlsplit(entry["url"]).path).name
    destination = cache / name
    if destination.exists():
        if digest(destination) != entry["sha256"]: raise ValueError(f"Checksum mismatch: {destination}")
        return destination
    if offline: raise FileNotFoundError(f"Missing cached dependency: {destination}")
    request = urllib.request.Request(entry["url"], headers={"User-Agent": "iYoinks-native-build"})
    with urllib.request.urlopen(request, timeout=45) as response, tempfile.NamedTemporaryFile(dir=cache, delete=False) as temporary:
        pending = Path(temporary.name)
        try:
            shutil.copyfileobj(response, temporary)
            temporary.flush()
            if digest(pending) != entry["sha256"]: raise ValueError(f"Checksum mismatch: {name}")
            pending.replace(destination)
        finally:
            pending.unlink(missing_ok=True)
    return destination


def unpack(path, destination):
    destination.mkdir(parents=True, exist_ok=True)
    if zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as archive:
            for item in archive.infolist():
                target = (destination / item.filename).resolve()
                if not target.is_relative_to(destination.resolve()): raise ValueError("Archive path escapes its destination")
                archive.extract(item, destination)
                mode = item.external_attr >> 16
                if mode and not item.is_dir(): target.chmod(mode & 0o777)
    else:
        with tarfile.open(path) as archive: archive.extractall(destination, filter="data")


def replace_tree(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination.parent, prefix=".iyoinks-vendor-") as temporary:
        root = Path(temporary)
        replacement = root / "new"
        previous = root / "previous"
        shutil.copytree(source, replacement, symlinks=True)
        if destination.exists(): destination.rename(previous)
        try: replacement.rename(destination)
        except BaseException:
            if previous.exists(): previous.rename(destination)
            raise


def prepare(cache, offline):
    manifest = json.loads(MANIFEST.read_text())
    patches = sorted((SCRIPTS / "patches").glob("*.patch"))
    inputs = MANIFEST.read_bytes() + Path(__file__).read_bytes() + b"".join(path.read_bytes() for path in patches)
    fingerprint = hashlib.sha256(inputs).hexdigest()
    stamp = cache / "prepared.sha256"
    expected = [PROJECT / "Packages/YoinksExtractor/Vendor/Python.xcframework", PROJECT / "Vendor/SwiftFFmpeg-iOS",
                PROJECT / "Packages/YoinksExtractor/Sources/QuickJS/quickjs.c", RESOURCES / "Python/lib/python3.15/encodings",
                RESOURCES / "Extractor/yt_dlp", RESOURCES / "Extractor/yt_dlp_ejs", RESOURCES / "Extractor/certifi",
                RESOURCES / "Legal/ThirdPartyNotices.txt"]
    if stamp.exists() and stamp.read_text() == fingerprint and all(path.exists() for path in expected):
        print("Pinned native dependencies are ready.")
        return
    with tempfile.TemporaryDirectory(prefix="iyoinks-native-") as temporary:
        root = Path(temporary)
        for key in ("python", "ffmpeg", "quickjs"):
            unpack(acquire(manifest[key], cache, offline), root / key)
        python = root / "python/Python.xcframework"
        replace_tree(python, PROJECT / "Packages/YoinksExtractor/Vendor/Python.xcframework")
        ffmpeg = root / "ffmpeg/SwiftFFmpeg-iOS"
        for patch in patches:
            subprocess.run(["patch", "-t", "-p1", "-F", "0", "-i", str(patch)], cwd=ffmpeg, check=True)
        replace_tree(ffmpeg, PROJECT / "Vendor/SwiftFFmpeg-iOS")

        quickjs = next((root / "quickjs").glob("*/quickjs.c")).parent
        selected = root / "quickjs-selected"
        selected.mkdir()
        for name in ("quickjs.c", "dtoa.c", "libregexp.c", "libunicode.c", "LICENSE"):
            shutil.copy2(quickjs / name, selected / name)
        for path in quickjs.glob("*.h"): shutil.copy2(path, selected / path.name)
        (selected / "include").mkdir()
        (selected / "include/quickjs.h").write_text('#pragma once\n#include "../quickjs.h"\n')
        replace_tree(selected, PROJECT / "Packages/YoinksExtractor/Sources/QuickJS")

        stdlib = root / "stdlib"
        shutil.copytree(python / "lib/python3.15", stdlib,
                        ignore=shutil.ignore_patterns("__pycache__", "test", "tests", "idlelib", "tkinter", "turtledemo", "ensurepip"))
        replace_tree(stdlib, RESOURCES / "Python/lib/python3.15")
        legal = root / "legal"
        legal.mkdir()
        shutil.copy2(python / "lib/python3.15/LICENSE.txt", legal / "Python.txt")
        shutil.copy2(ffmpeg / "LICENSE", legal / "SwiftFFmpeg-GPL-3.0.txt")
        shutil.copytree(ffmpeg / "Licenses", legal / "FFmpeg-dependencies")
        shutil.copy2(quickjs / "LICENSE", legal / "QuickJS-MIT.txt")
        modules = {"yt-dlp": "yt_dlp", "yt-dlp-ejs": "yt_dlp_ejs", "certifi": "certifi"}
        for entry in manifest["packages"]:
            wheel = root / entry["name"]
            unpack(acquire(entry, cache, offline), wheel)
            module = modules[entry["name"]]
            replace_tree(wheel / module, RESOURCES / "Extractor" / module)
            metadata = next(wheel.glob("*.dist-info"))
            for old in (RESOURCES / "Extractor").glob(module + "-*.dist-info"):
                if old.name != metadata.name: shutil.rmtree(old)
            replace_tree(metadata, RESOURCES / "Extractor" / metadata.name)
            licenses = metadata / "licenses"
            if licenses.is_dir(): shutil.copytree(licenses, legal / entry["name"])
            else:
                target = legal / entry["name"]
                target.mkdir()
                for path in metadata.glob("*LICENSE*"): shutil.copy2(path, target / path.name)
        notices = """iYoinks native extractor dependencies

Python 3.15-b3. Python Software Foundation license and bundled notices.
https://github.com/beeware/Python-Apple-support/releases/tag/3.15-b3

SwiftFFmpeg-iOS 1.2.0. GPL-3.0, with the local native-probe and callback patches.
Its binary records build commit 3e0a3f4. See SwiftFFmpeg-GPL-3.0.txt and FFmpeg-dependencies.
https://github.com/tfourj/SwiftFFmpeg-iOS/releases/tag/1.2.0

QuickJS-NG 0.16.2. MIT.
https://github.com/quickjs-ng/quickjs/releases/tag/v0.16.2

yt-dlp 2026.10.26, yt-dlp-ejs 0.8.0, certifi 2026.10.23.
Their license files are included in this directory and their bundled package metadata.
https://github.com/yt-dlp/yt-dlp
https://github.com/yt-dlp/ejs
https://github.com/certifi/python-certifi

Source dependencies and checksums are pinned in scripts/native-dependencies.json.
Seal and Palladium supplied workflow references. No application code from either is bundled.
"""
        (legal / "ThirdPartyNotices.txt").write_text(notices)
        replace_tree(legal, RESOURCES / "Legal")
        for directory in (RESOURCES / "Extractor").rglob("__pycache__"): shutil.rmtree(directory)
    stamp.write_text(fingerprint)
    print("Prepared pinned Python, QuickJS, FFmpeg, extractor packages, and license notices.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", type=Path, default=PROJECT / ".cache/native-dependencies")
    parser.add_argument("--offline", action="store_true", help="Require cached archives; do not access the network")
    args = parser.parse_args()
    args.cache.mkdir(parents=True, exist_ok=True)
    prepare(args.cache.resolve(), args.offline)


if __name__ == "__main__": main()
