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
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import sysconfig
import tempfile
import threading
import unittest
from unittest.mock import Mock, patch

sys.dont_write_bytecode = True

PROJECT = Path(__file__).resolve().parent.parent
EXTRACTOR = PROJECT / "iYoinks/Resources/Extractor"
CONTRACT = PROJECT / "Packages/YoinksCore/Tests/YoinksCoreTests/Fixtures/source-media.json"
# macOS extension modules resolve Python symbols when the interpreter loads them.
HOST_LINK_FLAGS = ["-undefined", "dynamic_lookup"] if sys.platform == "darwin" else []


def ffmpeg_flags():
    """Compiler and linker flags for the host FFmpeg libraries, from pkg-config or Homebrew."""
    libraries = ["libavformat", "libavcodec", "libavutil"]
    if shutil.which("pkg-config"):
        return subprocess.run(["pkg-config", "--cflags", "--libs", *libraries],
                              check=True, capture_output=True, text=True).stdout.split()
    if shutil.which("brew"):
        prefix = subprocess.run(["brew", "--prefix", "ffmpeg"], check=True, capture_output=True, text=True).stdout.strip()
        return [f"-I{prefix}/include", f"-L{prefix}/lib", *(f"-l{name[3:]}" for name in libraries)]
    raise RuntimeError("Install pkg-config or Homebrew FFmpeg to build the host native probe.")
HOST_PACKAGES = Path(os.environ.get("YOINKD_HOST_PACKAGES", PROJECT / ".cache/native-dependencies/host-packages"))


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
                        "-lm", "-lpthread", *HOST_LINK_FLAGS, "-o", str(output)], check=True)
        stamp.write_text(digest)
    sys.path[:0] = [str(directory), str(EXTRACTOR), str(HOST_PACKAGES)]
    return importlib.import_module("_iy_native")


def load_native_probe():
    wrapper = PROJECT / "Vendor/SwiftFFmpeg-iOS/Sources/CFFmpegCLI/ffmpeg_wrapper.c"
    text = wrapper.read_text()
    probe_source = text[text.index("static int probe_interrupt("):text.index("\nint ffprobe_execute(")]
    headers = "\n".join(line for line in text.splitlines() if line.startswith("#include <") and "swiftffmpeg" not in line)
    source = headers + "\nint ffmpeg_library_cancel_requested(void) { return 0; }\n" + probe_source + """
int main(int argc, char *argv[]) {
    char output[65536];
    int result = probe_media(argc, argv, output, sizeof(output));
    if (result < 0) return 1;
    fputs(output, stdout);
    return 0;
}
"""
    directory = PROJECT / ".build/host-extractor/native-probe"
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / "probe.c"
    path.write_text(source)
    executable = directory / "probe"
    flags = ffmpeg_flags()
    subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wno-unused-parameter",
                    str(path), *flags, "-o", str(executable)], check=True)
    return executable


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
    def __init__(self, on_event=None, probe_executable=None):
        self.events = []
        self.tools = []
        self.on_event = on_event
        self.probe_executable = probe_executable
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
            executable = str(self.probe_executable) if tool == "ffprobe" and self.probe_executable else tool
            completed = subprocess.run([executable, *request["args"]], capture_output=True, text=True, timeout=120)
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


class ArtworkResponse(io.BytesIO):
    def __init__(self, data, *, url="https://example.com/cover.jpg", mime="image/jpeg", length=None, on_read=None):
        super().__init__(data)
        self.status = 200
        self.headers = {"Content-Type": mime, "Content-Length": str(len(data) if length is None else length)}
        self.url = url
        self.on_read = on_read

    def geturl(self):
        return self.url

    def read(self, size=-1):
        result = super().read(size)
        if self.on_read:
            self.on_read()
        return result


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
        cls.native_probe = load_native_probe()
        fixtures = [
            ("video.mp4", ["-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30", "-t", "1", "-an", "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p"]),
            ("audio.m4a", ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "1", "-vn", "-c:a", "aac", "-b:a", "128k"]),
            ("audio.webm", ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "1", "-vn", "-c:a", "libopus", "-b:a", "160k"]),
        ]
        for name, arguments in fixtures:
            subprocess.run(["ffmpeg", "-v", "error", "-y", *arguments, str(cls.root / name)], check=True)
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "color=c=green:size=128x96",
                        "-frames:v", "1", "-threads", "1", str(cls.root / "cover.jpg")], check=True)
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

    def request(self, kind, format_id=None, output_format=None):
        return {"action": "download", "url": "https://example.com/media", "directory": str(self.directory),
                "cacheDirectory": None, "supportsAV1": True,
                "selection": {"kind": kind, "formatID": format_id, "quality": "Best available", "outputFormat": output_format}}

    def download(self, kind, format_id=None, on_event=None, output_format=None, native_probe=False):
        with patch.object(engine, "inspect", side_effect=lambda request, token: copy.deepcopy(self.info)), \
                NativeOperation(on_event, probe_executable=self.native_probe if native_probe else None) as operation:
            result = operation.run(self.request(kind, format_id, output_format))
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

    def test_all_source_variants_are_reported_without_resolution_or_codec_limits(self):
        self.add_format("240", "video.mp4", video=True)
        self.info["formats"][0].update(width=426, height=240)
        self.add_format("720-h264", "video.mp4", video=True)
        self.info["formats"][1].update(width=1280, height=720)
        self.add_format("720-vp9", "video.mp4", video=True)
        self.info["formats"][2].update(width=1280, height=720, vcodec="vp9", fps=60)
        self.add_format("audio", "audio.webm")
        value = engine.metadata(self.info, "https://example.com/media")
        self.assertEqual([item["id"] for item in value["formats"]], ["240", "720-h264", "720-vp9", "audio"])

    def test_inspect_output_matches_the_swift_decoding_fixture(self):
        # SourceMediaTests decodes the same file, so renaming a key on either side fails a test.
        # After an intended change, write `value` to CONTRACT and update the Swift model with it.
        info = {"id": "contract", "title": "Contract fixture", "extractor_key": "Fixture", "uploader": "Fixture channel",
                "artist": "Fixture artist", "duration": 61.5, "thumbnail": "https://example.com/cover.jpg",
                "formats": [{"format_id": "137", "url": "https://example.com/v", "ext": "mp4", "protocol": "https",
                             "vcodec": "avc1.640028", "acodec": "mp4a.40.2", "width": 1920, "height": 1080, "fps": 30,
                             "abr": 128, "tbr": 4500, "vbr": 4372, "asr": 44100, "audio_channels": 2,
                             "filesize": 34_000_000, "language": "en", "dynamic_range": "SDR", "format_note": "1080p"}]}
        value = engine.metadata(info, "https://example.com/media")
        self.assertEqual(value, json.loads(CONTRACT.read_text()))

    def test_combined_audio_remains_selectable_when_audio_only_exists(self):
        self.add_format("combined", "combined.mp4", video=True)
        self.info["formats"][0]["acodec"] = "aac"
        self.add_format("audio", "audio.webm")
        result, _, _ = self.download("audio", "combined")
        self.assertTrue(result["ok"], result)
        self.assertEqual(probe(self.directory / result["value"]["fileName"])["streams"][0]["codec_name"], "aac")
        self.assertEqual(engine.choose_formats(self.info, {"kind": "audio"})[0]["format_id"], "audio")

    def test_explicit_audio_outputs_use_supported_codecs_and_source_sample_rate(self):
        self.add_format("audio", "audio.webm")
        expected = {"m4a": "aac", "aac": "aac", "mp3": "mp3", "flac": "flac", "alac": "alac",
                    "wav": "pcm_s24le", "aiff": "pcm_s24be", "caf": "pcm_s24le"}
        for output_format, codec in expected.items():
            with self.subTest(output=output_format):
                result, _, _ = self.download("audio", output_format=output_format)
                self.assertTrue(result["ok"], result)
                streams = probe(self.directory / result["value"]["fileName"])["streams"]
                self.assertEqual(streams[0]["codec_name"], codec)
                self.assertEqual(streams[0]["sample_rate"], "48000")

    def test_native_probe_contract_supports_artwork_and_pcm_depth(self):
        self.add_format("audio", "audio.webm")
        self.info.update(thumbnail="https://example.com/cover.jpg", artist="Fixture artist")
        with NativeOperation(probe_executable=self.native_probe) as operation:
            image = engine.probe_file(self.root / "cover.jpg", operation.token, max_pixels=engine._ARTWORK_PIXELS)["streams"][0]
            self.assertEqual((image["width"], image["height"]), (128, 96))
            audio = engine.probe_file(self.root / "audio.webm", operation.token)["streams"][0]
            self.assertEqual(audio["sample_fmt"], "fltp")
            self.assertEqual(audio["sample_rate"], 48000)
            self.assertEqual(audio["channels"], 1)
        for output_format, expected_codec in (("m4a", "aac"), ("mp3", "mp3"), ("flac", "flac"),
                                               ("wav", "pcm_s24le"), ("aiff", "pcm_s24be"), ("caf", "pcm_s24le")):
            with self.subTest(output=output_format):
                client = Mock(open=Mock(return_value=ArtworkResponse((self.root / "cover.jpg").read_bytes())))
                with patch.object(engine, "artwork_client", return_value=client):
                    result, _, _ = self.download("audio", output_format=output_format, native_probe=True)
                self.assertTrue(result["ok"], result)
                value = result["value"]
                self.assertIsNotNone(value["thumbnailFileName"])
                self.assertEqual(value["artworkEmbedded"], output_format in ("m4a", "mp3", "flac"))
                with NativeOperation(probe_executable=self.native_probe) as operation:
                    streams = engine.probe_file(self.directory / value["fileName"], operation.token)["streams"]
                self.assertEqual(streams[0]["codec_name"], expected_codec)
                self.assertEqual(streams[0]["sample_rate"], 48000)
                if output_format in ("wav", "aiff", "caf"):
                    self.assertEqual(streams[0]["bits_per_raw_sample"], 24)
                else:
                    self.assertTrue(any(stream["disposition"]["attached_pic"] for stream in streams))
                    self.assertIsNone(engine.real_video_stream({"streams": streams}))

    def test_native_probe_rejects_oversized_artwork_without_losing_audio(self):
        image = bytearray((self.root / "cover.jpg").read_bytes())
        marker = image.index(b"\xff\xc0")
        image[marker + 5:marker + 9] = (65000).to_bytes(2, "big") * 2
        self.directory.mkdir(parents=True)
        source = self.directory / "oversized.jpg"
        source.write_bytes(image)
        with NativeOperation(probe_executable=self.native_probe) as operation:
            with self.assertRaises(ValueError):
                engine.probe_file(source, operation.token, max_pixels=engine._ARTWORK_PIXELS)
        self.add_format("audio", "audio.m4a")
        self.info["thumbnail"] = "https://example.com/cover.jpg"
        with patch.object(engine, "artwork_client", return_value=Mock(open=Mock(return_value=ArtworkResponse(bytes(image))))):
            result, _, _ = self.download("audio", native_probe=True)
        self.assertTrue(result["ok"], result)
        self.assertIsNone(result["value"]["thumbnailFileName"])
        self.assertEqual(probe(self.directory / result["value"]["fileName"])["streams"][0]["codec_name"], "aac")

    def test_mov_output_keeps_both_selected_streams(self):
        self.add_format("video", "video.mp4", video=True)
        self.add_format("audio", "audio.m4a")
        result, _, _ = self.download("video", "video", output_format="mov")
        self.assertTrue(result["ok"], result)
        output = self.directory / result["value"]["fileName"]
        self.assertEqual(output.suffix, ".mov")
        self.assertEqual({value["codec_type"] for value in probe(output)["streams"]}, {"video", "audio"})

    def test_unavailable_and_wrong_kind_outputs_fail_before_transfer(self):
        self.add_format("audio", "audio.m4a")
        before = len(self.server.requests)
        for output_format in ("mp4", "webm"):
            result, _, _ = self.download("audio", output_format=output_format)
            self.assertFalse(result["ok"], result)
            self.assertIn("file format", result["error"])
        self.assertEqual(len(self.server.requests), before)

    def test_native_capability_failure_does_not_start_a_transfer(self):
        self.add_format("audio", "audio.m4a")
        before = len(self.server.requests)
        with patch.object(engine, "_output_support", (set(), set())):
            result, _, _ = self.download("audio", output_format="flac")
        self.assertFalse(result["ok"], result)
        self.assertIn("supported by this build", result["error"])
        self.assertEqual(len(self.server.requests), before)

    def test_audio_artwork_embeds_in_supported_outputs_and_saves_a_sidecar(self):
        self.add_format("audio", "audio.webm")
        self.info.update(thumbnail="https://example.com/cover.jpg", artist="Fixture artist", uploader="Fixture channel")
        for output_format in ("m4a", "mp3", "flac"):
            with self.subTest(output=output_format):
                client = Mock(open=Mock(return_value=ArtworkResponse((self.root / "cover.jpg").read_bytes())))
                with patch.object(engine, "artwork_client", return_value=client):
                    result, _, _ = self.download("audio", output_format=output_format)
                self.assertTrue(result["ok"], result)
                value = result["value"]
                self.assertTrue(value["artworkEmbedded"], value)
                self.assertTrue((self.directory / value["thumbnailFileName"]).is_file())
                media_probe = probe(self.directory / value["fileName"])
                self.assertTrue(any(stream.get("disposition", {}).get("attached_pic") for stream in media_probe["streams"]))
                self.assertIsNone(engine.real_video_stream(media_probe))
                tags = {name.lower(): content for name, content in media_probe["format"].get("tags", {}).items()}
                self.assertEqual(tags.get("artist"), "Fixture artist")
                self.assertEqual(tags.get("title"), self.info["title"])
                saved = json.loads((self.directory / "source-result.json").read_text())
                self.assertEqual(saved, value)
                self.assertEqual(saved["uploader"], "Fixture channel")

    def test_wav_artwork_falls_back_to_the_saved_sidecar(self):
        self.add_format("audio", "audio.webm")
        self.info["thumbnail"] = "https://example.com/cover.jpg"
        client = Mock(open=Mock(return_value=ArtworkResponse((self.root / "cover.jpg").read_bytes())))
        with patch.object(engine, "artwork_client", return_value=client):
            result, _, _ = self.download("audio", output_format="wav")
        self.assertTrue(result["ok"], result)
        self.assertFalse(result["value"]["artworkEmbedded"])
        self.assertTrue((self.directory / result["value"]["thumbnailFileName"]).is_file())

    def test_malformed_oversized_and_insecure_artwork_do_not_fail_audio(self):
        self.add_format("audio", "audio.m4a")
        self.info["thumbnail"] = "https://example.com/cover.jpg"
        responses = [ArtworkResponse(b"not an image"),
                     ArtworkResponse(b"x" * (engine._ARTWORK_LIMIT + 1), length=1),
                     ArtworkResponse(b"small", length=engine._ARTWORK_LIMIT + 1),
                     ArtworkResponse((self.root / "cover.jpg").read_bytes(), url="http://example.com/cover.jpg")]
        for response in responses:
            with self.subTest(length=response.headers["Content-Length"], url=response.url):
                with patch.object(engine, "artwork_client", return_value=Mock(open=Mock(return_value=response))):
                    result, _, _ = self.download("audio")
                self.assertTrue(result["ok"], result)
                self.assertIsNone(result["value"]["thumbnailFileName"])
                self.assertFalse(result["value"]["artworkEmbedded"])

    def test_artwork_pixel_limit_and_embedding_failure_keep_the_media(self):
        self.add_format("audio", "audio.m4a")
        self.info["thumbnail"] = "https://example.com/cover.jpg"
        original_probe = engine.probe_file

        def oversized_probe(path, token, **kwargs):
            if path.name == "artwork-source":
                return {"streams": [{"codec_type": "video", "width": 10_000, "height": 10_000}]}
            return original_probe(path, token, **kwargs)

        with patch.object(engine, "artwork_client", return_value=Mock(open=Mock(return_value=ArtworkResponse((self.root / "cover.jpg").read_bytes())))), \
                patch.object(engine, "probe_file", side_effect=oversized_probe):
            result, _, _ = self.download("audio")
        self.assertTrue(result["ok"], result)
        self.assertIsNone(result["value"]["thumbnailFileName"])
        original_run = engine.run_media

        def unsupported_cover(token, arguments, *args, **kwargs):
            if "-disposition:v:0" in arguments:
                raise ValueError("Unsupported cover muxing")
            return original_run(token, arguments, *args, **kwargs)

        with patch.object(engine, "artwork_client", return_value=Mock(open=Mock(return_value=ArtworkResponse((self.root / "cover.jpg").read_bytes())))), \
                patch.object(engine, "run_media", side_effect=unsupported_cover):
            result, _, _ = self.download("audio")
        self.assertTrue(result["ok"], result)
        self.assertFalse(result["value"]["artworkEmbedded"])
        self.assertTrue((self.directory / result["value"]["thumbnailFileName"]).is_file())
        self.assertEqual(probe(self.directory / result["value"]["fileName"])["streams"][0]["codec_name"], "aac")

    def test_cancel_during_artwork_read_is_not_swallowed(self):
        self.add_format("audio", "audio.m4a")
        self.info["thumbnail"] = "https://example.com/cover.jpg"
        with NativeOperation() as operation:
            response = ArtworkResponse((self.root / "cover.jpg").read_bytes(), on_read=operation.cancel)
            with patch.object(engine, "inspect", return_value=copy.deepcopy(self.info)), \
                    patch.object(engine, "artwork_client", return_value=Mock(open=Mock(return_value=response))):
                result = operation.run(self.request("audio"))
        self.assertTrue(result.get("cancelled"), result)
        self.assertFalse((self.directory / "artwork.jpg").exists())

    def test_artwork_redirects_reject_http_and_credentials(self):
        handler = engine.ArtworkRedirect()
        request = engine.urllib.request.Request("https://example.com/cover.jpg")
        for url in ("http://example.com/cover.jpg", "https://user:pass@example.com/cover.jpg"):
            with self.assertRaises(ValueError):
                handler.redirect_request(request, None, 302, "Found", {}, url)
        self.assertEqual(handler.max_redirections, 5)

    def test_thumbnail_list_can_supply_a_safe_primary_image(self):
        self.info.update(thumbnail="http://example.com/unsafe.jpg", thumbnails=[
            {"url": "https://example.com/safe.jpg"}, {"url": "https://user:pass@example.com/private.jpg"}])
        self.assertEqual(engine.thumbnail_url(self.info), "https://example.com/safe.jpg")
        self.assertFalse(engine.public_format({"format_id": "huge", "filesize": 2 ** 80}, 0)["byteCount"])

    def test_result_manifest_retains_artwork_when_the_media_is_staged_elsewhere(self):
        self.add_format("audio", "audio.m4a")
        self.info.update(thumbnail="https://example.com/cover.jpg?token=dummy", uploader="Fixture uploader")
        response = ArtworkResponse((self.root / "cover.jpg").read_bytes(), url=self.info["thumbnail"])
        with patch.object(engine, "artwork_client", return_value=Mock(open=Mock(return_value=response))):
            result, _, _ = self.download("audio")
        self.assertTrue(result["ok"], result)
        output = self.directory / result["value"]["fileName"]
        output.rename(self.directory / "staged.m4a")
        manifest_text = (self.directory / "source-result.json").read_text()
        manifest = json.loads(manifest_text)
        self.assertTrue((self.directory / manifest["thumbnailFileName"]).exists())
        self.assertEqual(manifest["artist"], "Fixture uploader")
        self.assertNotIn("token=", manifest_text)
        self.assertNotIn("https://", manifest_text)

    def test_cover_attachment_keeps_decoded_audio_samples_unchanged(self):
        self.add_format("audio", "audio.webm")
        result, _, _ = self.download("audio", output_format="flac")
        self.assertTrue(result["ok"], result)
        output = self.directory / result["value"]["fileName"]

        def samples():
            return subprocess.run(["ffmpeg", "-v", "error", "-i", str(output), "-map", "0:a:0", "-f", "s32le", "-"],
                                  check=True, capture_output=True).stdout

        original = samples()
        with NativeOperation() as operation:
            self.assertTrue(engine.embed_artwork(output, self.root / "cover.jpg", "Title", "Artist", operation.token, 1))
        self.assertEqual(samples(), original)

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
    parser.add_argument("--output-format", choices=("automatic", "mp4", "mov", "m4a", "aac", "mp3", "flac", "alac", "wav", "aiff", "caf"))
    parser.add_argument("--directory", type=Path)
    parser.add_argument("--output", type=Path, help="Save sanitized result and observed phase summary")
    args = parser.parse_args()
    if not args.live:
        unittest.main(argv=[sys.argv[0]], verbosity=2)
        return
    if args.download and not args.directory: parser.error("--download requires --directory")
    if args.output_format and not args.download: parser.error("--output-format requires --download")
    request = {"action": "download" if args.download else "inspect", "url": args.live, "cacheDirectory": None}
    if args.download:
        request.update(directory=str(args.directory.resolve()), supportsAV1=True,
                       selection={"kind": args.download, "formatID": args.format_id, "quality": "Selected source quality", "outputFormat": args.output_format})
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
