#!/usr/bin/env python3
"""Test the bundled extractor with its C/QuickJS bridge and host FFmpeg.

The host callback runs desktop FFmpeg. These checks do not establish iOS execution.
"""

import argparse
import copy
import ctypes
import hashlib
import http.server
import importlib
import json
from pathlib import Path
import re
import subprocess
import sys
import sysconfig
import tempfile
import threading
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True

PROJECT = Path(__file__).resolve().parent.parent
EXTRACTOR = PROJECT / "iYoinks/Resources/Extractor"


def load_native():
    sources = PROJECT / "Packages/YoinksExtractor/Sources"
    files = [sources / "ExtractorBridge/runtime.c"] + [sources / "QuickJS" / name for name in
             ("quickjs.c", "dtoa.c", "libregexp.c", "libunicode.c")]
    digest = hashlib.sha256(sys.version.encode() + b"".join(path.read_bytes() for path in files)).hexdigest()
    directory = PROJECT / ".build/host-extractor" / sys.implementation.cache_tag
    directory.mkdir(parents=True, exist_ok=True)
    output = directory / ("_iy_native" + sysconfig.get_config_var("EXT_SUFFIX"))
    stamp = directory / "source.sha256"
    if not output.exists() or not stamp.exists() or stamp.read_text() != digest:
        subprocess.run(["cc", "-shared", "-fPIC", "-O2", "-std=c11", "-D_GNU_SOURCE", "-DQUICKJS_NG_BUILD",
                        "-I" + sysconfig.get_path("include"), "-I" + str(sources / "QuickJS"),
                        "-I" + str(sources / "ExtractorBridge/include"), *map(str, files),
                        "-lm", "-lpthread", "-o", str(output)], check=True)
        stamp.write_text(digest)
    sys.path[:0] = [str(directory), str(EXTRACTOR)]
    return importlib.import_module("_iy_native")


native = load_native()
engine = importlib.import_module("iyoinks_extract")
bridge = ctypes.CDLL(native.__file__)
EventCallback = ctypes.CFUNCTYPE(None, ctypes.c_char_p, ctypes.c_void_p)
MediaCallback = ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_void_p, ctypes.c_char_p)
bridge.iy_operation_create.argtypes = [EventCallback, ctypes.c_void_p, MediaCallback]
bridge.iy_operation_create.restype = ctypes.c_void_p
bridge.iy_operation_cancel.argtypes = [ctypes.c_void_p]
bridge.iy_operation_free.argtypes = [ctypes.c_void_p]
libc = ctypes.CDLL(None)
libc.strdup.argtypes = [ctypes.c_char_p]
libc.strdup.restype = ctypes.c_void_p
ctypes.pythonapi.PyCapsule_New.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p]
ctypes.pythonapi.PyCapsule_New.restype = ctypes.py_object


class NativeOperation:
    def __init__(self, on_event=None):
        self.events = []
        self.tools = []
        self.on_event = on_event
        self.event_callback = EventCallback(self.receive)
        self.media_callback = MediaCallback(self.media)
        self.handle = bridge.iy_operation_create(self.event_callback, None, self.media_callback)
        if not self.handle: raise MemoryError("Could not allocate an extractor operation")
        self.token = ctypes.pythonapi.PyCapsule_New(self.handle, b"iYoinks.operation", None)

    def receive(self, raw, context):
        event = json.loads(raw)
        self.events.append(event)
        if self.on_event: self.on_event(self, event)

    def media(self, operation, raw):
        try:
            request = json.loads(raw)
            tool = request["tool"]
            if tool not in ("ffmpeg", "ffprobe"): raise ValueError("Unexpected media tool")
            self.tools.append(tool)
            completed = subprocess.run([tool, *request["args"]], capture_output=True, text=True, timeout=120)
            result = {"exitCode": completed.returncode, "stdout": completed.stdout, "stderr": completed.stderr}
        except Exception as error:
            result = {"exitCode": -1, "stdout": "", "stderr": str(error)}
        return libc.strdup(json.dumps(result).encode())

    def cancel(self): bridge.iy_operation_cancel(self.handle)
    def run(self, request): return json.loads(engine.run(json.dumps(request), self.token))
    def __enter__(self): return self
    def __exit__(self, *error):
        self.token = None
        bridge.iy_operation_free(self.handle)


def probe(path):
    result = subprocess.run(["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)],
                            check=True, capture_output=True, text=True)
    return json.loads(result.stdout)


class FixtureHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self): self.send_file(True)
    def do_HEAD(self): self.send_file(False)
    def log_message(self, *args): pass

    def send_file(self, body):
        path = self.server.root / Path(self.path).name
        if not path.is_file(): self.send_error(404); return
        size = path.stat().st_size
        match = re.fullmatch(r"bytes=(\d+)-(\d*)", self.headers.get("Range", ""))
        start = int(match[1]) if match else 0
        self.server.requests.append((path.name, start))
        if start >= size:
            self.send_response(416)
            self.send_header("Content-Range", f"bytes */{size}")
            self.end_headers()
            return
        self.send_response(206 if match else 200)
        self.send_header("Content-Length", str(size - start))
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Accept-Ranges", "bytes")
        if match: self.send_header("Content-Range", f"bytes {start}-{size - 1}/{size}")
        self.end_headers()
        if body:
            try:
                with path.open("rb") as source:
                    source.seek(start)
                    while data := source.read(4096): self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError): pass


class ExtractorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="iyoinks-source-tests-")
        cls.root = Path(cls.temporary.name)
        fixtures = [
            ("video.mp4", ["-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30", "-t", "1", "-an", "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p"]),
            ("audio.m4a", ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "1", "-vn", "-c:a", "aac", "-b:a", "128k"]),
            ("audio.webm", ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "1", "-vn", "-c:a", "libopus", "-b:a", "160k"]),
        ]
        for name, arguments in fixtures:
            subprocess.run(["ffmpeg", "-v", "error", "-y", *arguments, str(cls.root / name)], check=True)
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(cls.root / "video.mp4"), "-i", str(cls.root / "audio.m4a"),
                        "-map", "0:v:0", "-map", "1:a:0", "-c", "copy", str(cls.root / "combined.mp4")], check=True)
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FixtureHandler)
        cls.server.root = cls.root
        cls.server.requests = []
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()
        cls.temporary.cleanup()

    def setUp(self):
        self.directory = self.root / self._testMethodName
        self.info = {"id": "fixture", "title": "Fixture / Y", "duration": 1,
                     "extractor": "Fixture", "webpage_url": "https://example.com/media", "formats": []}

    def add_format(self, identifier, name, video=False):
        value = {"format_id": identifier, "url": f"http://127.0.0.1:{self.server.server_port}/{name}",
                 "ext": Path(name).suffix[1:], "protocol": "http", "filesize": (self.root / name).stat().st_size,
                 "vcodec": "h264" if video else "none", "acodec": "none" if video else ("opus" if name.endswith("webm") else "aac")}
        if video: value.update(width=640, height=360, fps=30)
        self.info["formats"].append(value)

    def request(self, kind, format_id=None):
        return {"action": "download", "url": "https://example.com/media", "directory": str(self.directory),
                "cacheDirectory": None, "supportsAV1": True, "selection": {"kind": kind, "formatID": format_id, "quality": "Best available"}}

    def download(self, kind, format_id=None, on_event=None):
        with patch.object(engine, "inspect", side_effect=lambda request, token: copy.deepcopy(self.info)), NativeOperation(on_event) as operation:
            result = operation.run(self.request(kind, format_id))
            return result, operation.events, operation.tools

    def test_real_video_and_audio_streams_are_merged(self):
        self.add_format("video", "video.mp4", video=True)
        self.add_format("audio", "audio.m4a")
        result, events, tools = self.download("video", "video")
        self.assertTrue(result["ok"], result)
        output = self.directory / result["value"]["fileName"]
        self.assertEqual(output.suffix, ".mp4")
        self.assertEqual({stream["codec_type"] for stream in probe(output)["streams"]}, {"video", "audio"})
        self.assertTrue(any(event["phase"] == "downloading" for event in events))
        self.assertIn("ffmpeg", tools)
        self.assertEqual(len(list(self.directory.glob("stream-*.*"))), 2)

    def test_playable_audio_keeps_its_exact_source_bytes_and_checkpoint(self):
        self.add_format("audio", "audio.m4a")
        result, _, tools = self.download("audio")
        self.assertTrue(result["ok"], result)
        output = self.directory / result["value"]["fileName"]
        self.assertEqual(output.read_bytes(), (self.root / "audio.m4a").read_bytes())
        self.assertEqual(len(list(self.directory.glob("stream-*.m4a"))), 1)
        self.assertNotIn("ffmpeg", tools)

    def test_opus_audio_converts_to_flac_without_changing_sample_rate(self):
        self.add_format("audio", "audio.webm")
        result, _, _ = self.download("audio")
        self.assertTrue(result["ok"], result)
        output = self.directory / result["value"]["fileName"]
        stream = probe(output)["streams"][0]
        self.assertEqual(stream["codec_name"], "flac")
        self.assertEqual(stream["sample_rate"], probe(self.root / "audio.webm")["streams"][0]["sample_rate"])

    def test_silent_video_saves_without_a_fabricated_audio_track(self):
        self.add_format("video", "video.mp4", video=True)
        result, _, _ = self.download("video")
        self.assertTrue(result["ok"], result)
        self.assertEqual([value["codec_type"] for value in probe(self.directory / result["value"]["fileName"])["streams"]], ["video"])

    def test_audio_from_a_combined_video_remuxes_aac_into_m4a(self):
        self.add_format("combined", "combined.mp4", video=True)
        self.info["formats"][0]["acodec"] = "aac"
        result, _, _ = self.download("audio")
        self.assertTrue(result["ok"], result)
        output = self.directory / result["value"]["fileName"]
        self.assertEqual(output.suffix, ".m4a")
        streams = probe(output)["streams"]
        self.assertEqual([value["codec_type"] for value in streams], ["audio"])
        self.assertEqual(streams[0]["codec_name"], "aac")

    def test_cancelled_transfer_preserves_partial_data_and_resumes_with_range(self):
        self.add_format("video", "video.mp4", video=True)
        result, _, _ = self.download("video", on_event=lambda op, event: op.cancel() if event.get("receivedBytes", 0) > 0 else None)
        self.assertTrue(result.get("cancelled"), result)
        self.assertTrue(any(path.stat().st_size > 0 for path in self.directory.glob("*.part")))
        result, _, _ = self.download("video")
        self.assertTrue(result["ok"], result)
        self.assertTrue(any(name == "video.mp4" and start > 0 for name, start in self.server.requests))

    def test_cancel_before_processing_keeps_completed_streams_for_retry(self):
        self.add_format("audio", "audio.webm")
        result, _, _ = self.download("audio", on_event=lambda op, event: op.cancel() if event["phase"] == "processing" else None)
        self.assertTrue(result.get("cancelled"), result)
        before = len(self.server.requests)
        result, _, _ = self.download("audio")
        self.assertTrue(result["ok"], result)
        self.assertEqual(len(self.server.requests), before)

    def test_best_selection_refreshes_checkpoint_identity_when_formats_change(self):
        self.add_format("audio-low", "audio.m4a")
        result, _, _ = self.download("audio")
        self.assertTrue(result["ok"], result)
        self.add_format("audio-high", "audio.webm")
        result, _, _ = self.download("audio")
        self.assertTrue(result["ok"], result)
        self.assertEqual(Path(result["value"]["fileName"]).suffix, ".flac")
        self.assertEqual(len(list(self.directory.glob("stream-*.*"))), 2)

    def test_changed_explicit_quality_is_reported(self):
        self.add_format("audio", "audio.m4a")
        result, _, _ = self.download("audio", "removed-format")
        self.assertFalse(result["ok"])
        self.assertIn("no longer available", result["error"])

    def test_embedded_javascript_can_evaluate_and_interrupt(self):
        with NativeOperation() as operation:
            self.assertEqual(native.javascript(operation.token, "console.log(JSON.stringify({answer: 6 * 7}))"), '{"answer":42}\n')
            operation.cancel()
            with self.assertRaises(RuntimeError): native.javascript(operation.token, "while (true) {}")

    def test_source_errors_do_not_expose_signed_urls(self):
        message = engine.user_error(ValueError("ERROR: request failed at https://example.com/media?token=dummy"))
        self.assertNotIn("https://", message)
        self.assertNotIn("token=", message)
        self.assertIn("sign-in", engine.user_error(ValueError("Sign in to confirm")))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", help="Inspect a real public HTTPS media link")
    parser.add_argument("--download", choices=("video", "audio"))
    parser.add_argument("--format", dest="format_id", help="Exact source format ID; otherwise source maximum")
    parser.add_argument("--directory", type=Path)
    parser.add_argument("--output", type=Path, help="Save sanitized result and observed phase summary")
    args = parser.parse_args()
    if not args.live:
        unittest.main(argv=[sys.argv[0]], verbosity=2)
        return
    if args.download and not args.directory: parser.error("--download requires --directory")
    request = {"action": "download" if args.download else "inspect", "url": args.live, "cacheDirectory": None}
    if args.download:
        request.update(directory=str(args.directory.resolve()), supportsAV1=True,
                       selection={"kind": args.download, "formatID": args.format_id, "quality": "Selected source quality"})
    with NativeOperation() as operation:
        result = operation.run(request)
        report = {"execution": "host C/QuickJS bridge with desktop FFmpeg callback", "result": result,
                  "phases": list(dict.fromkeys(event["phase"] for event in operation.events)), "media_tools": operation.tools}
    if result["ok"] and args.download:
        output = args.directory.resolve() / result["value"]["fileName"]
        report.update(file_bytes=output.stat().st_size, file_sha256=hashlib.sha256(output.read_bytes()).hexdigest(), media_probe=probe(output))
    text = json.dumps(report, indent=2) + "\n"
    if args.output: args.output.write_text(text)
    if not args.download and result["ok"]:
        value = result["value"]
        print(json.dumps({"ok": True, "title": value["title"], "duration": value.get("duration"), "formats": len(value["formats"])}, indent=2))
    else: print(text, end="")
    if not result["ok"]: raise SystemExit(1)


if __name__ == "__main__": main()
