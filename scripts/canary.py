#!/usr/bin/env python3
"""Run the extractor against real public links and report which sites still work.

Uses the same host C/QuickJS bridge and desktop FFmpeg as verify-extractor.py, so a pass here means
the extractor code and yt-dlp version resolve these sites. It does not establish iOS execution.

Set YOINKD_HOST_PACKAGES to test a different yt-dlp/EJS/certifi set, such as the latest releases
that phones would download, instead of the pinned baseline.

A link with "known_issue" is expected to fail: its failure is reported but does not fail the run,
and a pass is flagged so the note can be removed.

Exit status: 0 when every link without a known issue passes, 1 otherwise, 2 for bad input.
"""

import argparse
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import time

PROJECT = Path(__file__).resolve().parent.parent
DEFAULT_URLS = PROJECT / "scripts/canary-urls.json"


def load_harness():
    """verify-extractor.py builds the host bridge and imports the extractor; reuse it rather than duplicate it."""
    spec = importlib.util.spec_from_file_location("verify_extractor", PROJECT / "scripts/verify-extractor.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def check(harness, entry, download, directory):
    """Inspect one link, and optionally download it. Returns a JSON-ready result."""
    started = time.monotonic()
    result = {"site": entry["site"], "url": entry["url"]}
    with harness.NativeOperation() as operation:
        inspected = operation.run({"action": "inspect", "url": entry["url"], "cacheDirectory": None})
    result["inspect_seconds"] = round(time.monotonic() - started, 2)
    if not inspected["ok"]:
        return {**result, "ok": False, "stage": "inspect", "error": inspected.get("error")}
    value = inspected["value"]
    result.update(title=value["title"], formats=len(value["formats"]), duration=value.get("duration"))
    kind = entry.get("download")
    if not (download and kind):
        return {**result, "ok": True}
    target = directory / entry["site"].lower().replace(" ", "-")
    request = {"action": "download", "url": entry["url"], "cacheDirectory": None, "directory": str(target),
               "supportsAV1": True, "selection": {"kind": kind, "formatID": None, "quality": "Best available"}}
    started = time.monotonic()
    with harness.NativeOperation() as operation:
        downloaded = operation.run(request)
    result["download_seconds"] = round(time.monotonic() - started, 2)
    if not downloaded["ok"]:
        return {**result, "ok": False, "stage": "download", "error": downloaded.get("error")}
    output = target / downloaded["value"]["fileName"]
    streams = [stream["codec_type"] for stream in harness.probe(output)["streams"]]
    expected = {"video", "audio"} if kind == "video" else {"audio"}
    ok = expected.issubset(streams) or (kind == "video" and "video" in streams)
    return {**result, "ok": ok, "stage": "download", "file_bytes": output.stat().st_size, "streams": streams,
            **({} if ok else {"error": f"Expected {kind} streams, found {streams}"})}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--urls", type=Path, default=DEFAULT_URLS, help="JSON list of {site, url, download?}")
    parser.add_argument("--download", action="store_true", help="Also download links that set \"download\"")
    parser.add_argument("--site", action="append", help="Only check these sites (repeatable, case-insensitive)")
    parser.add_argument("--output", type=Path, help="Write the full JSON report here")
    args = parser.parse_args()
    try:
        entries = json.loads(args.urls.read_text())
    except (OSError, ValueError) as error:
        print(f"Couldn't read {args.urls}: {error}", file=sys.stderr)
        raise SystemExit(2)
    if args.site:
        wanted = {name.lower() for name in args.site}
        entries = [entry for entry in entries if entry["site"].lower() in wanted]
        if not entries:
            print(f"No links for {', '.join(args.site)}. Sites: {sorted({e['site'] for e in json.loads(args.urls.read_text())})}",
                  file=sys.stderr)
            raise SystemExit(2)

    harness = load_harness()
    yt_dlp = sys.modules.get("yt_dlp")
    with tempfile.TemporaryDirectory(prefix="yoinkd-canary-") as temporary:
        results = []
        for entry in entries:
            result = check(harness, entry, args.download, Path(temporary))
            known = entry.get("known_issue")
            if known:
                result["known_issue"] = known
            results.append(result)
            if result["ok"]:
                mark, detail = ("pass", f"{result.get('formats', 0)} formats")
                if known:
                    detail += f" (known issue may be fixed: {known})"
            else:
                mark = "known" if known else "FAIL"
                detail = f"{result['stage']}: {result.get('error')}" + (f" (known: {known})" if known else "")
            print(f"{mark:<5}  {entry['site']:<12} {detail}", flush=True)
    regressions = [result for result in results if not result["ok"] and "known_issue" not in result]
    report = {"yt_dlp": getattr(getattr(yt_dlp, "version", None), "__version__", None),
              "passed": sum(result["ok"] for result in results), "total": len(results),
              "regressions": [result["site"] for result in regressions], "results": results}
    if args.output:
        args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(f"{report['passed']}/{report['total']} passed with yt-dlp {report['yt_dlp']}; "
          f"{len(regressions)} regression{'s' if len(regressions) != 1 else ''}")
    raise SystemExit(1 if regressions else 0)


if __name__ == "__main__":
    main()
