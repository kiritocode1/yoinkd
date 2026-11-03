"""Resolve public media links and acquire selected source formats in-process."""

import contextvars
import copy
import hashlib
import json
import math
from pathlib import Path
import re
import shutil
import ssl
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request

import _iy_native as native
import certifi
import yt_dlp
from yt_dlp.extractor.youtube.jsc._builtin.quickjs import QuickJSJCP
from yt_dlp.utils._jsruntime import JsRuntimeInfo, QuickJsRuntime


_operation = contextvars.ContextVar("iyoinks_operation", default=None)
_output_support = None
_ARTWORK_LIMIT = 8 * 1024 * 1024
_JPEG_LIMIT = 1024 * 1024
_ARTWORK_PIXELS = 16_000_000


def _quickjs_info(runtime):
    return JsRuntimeInfo(name="quickjs-ng", path="embedded", version="0.16.2",
                         version_tuple=(0, 16, 2), supported=True)


def _quickjs_run(provider, source):
    return native.javascript(provider.ie.get_param("_iy_token"), source)


QuickJsRuntime._info = _quickjs_info
QuickJSJCP._run_js_runtime = _quickjs_run


def _no_subprocess(self, *args, **kwargs):
    raise RuntimeError("This source needs a downloader that is unavailable on iOS.")


if sys.platform == "ios":
    subprocess.Popen.__init__ = _no_subprocess


class Cancelled(BaseException):
    pass


def check_cancelled(token):
    if native.cancelled(token):
        raise Cancelled()


def emit(token, phase, **values):
    check_cancelled(token)
    native.emit(token, json.dumps({"phase": phase, **values}, allow_nan=False))


class Logger:
    def __init__(self, token):
        self.token = token

    def debug(self, message):
        check_cancelled(self.token)

    info = debug
    warning = debug
    error = debug


def options(request, token):
    result = {
        "noplaylist": True, "playlistend": 1, "quiet": True,
        "logger": Logger(token), "socket_timeout": 15,
        "retries": 1, "fragment_retries": 1, "extractor_retries": 1,
        "js_runtimes": {"quickjs": {}}, "remote_components": set(),
        "fixup": "never", "hls_prefer_native": True,
        "concurrent_fragment_downloads": 1, "overwrites": False,
        "cachedir": request.get("cacheDirectory") or False,
        "format": "b/bv/ba",
        "_iy_token": token,
    }
    return result


def positive(value):
    return value if isinstance(value, (int, float)) and math.isfinite(value) and value > 0 else None


def has_codec(value):
    return isinstance(value, str) and value not in ("", "none", "unknown")


def contains_video(value):
    return value.get("vcodec") != "none" and (
        has_codec(value.get("vcodec")) or positive(value.get("height"))
        or value.get("ext") in ("mp4", "webm", "mov", "mkv", "m4v"))


def contains_audio(value):
    return value.get("acodec") != "none" and (
        has_codec(value.get("acodec")) or value.get("ext") in (
            "mp4", "webm", "mov", "mkv", "m4v", "m4a", "mp3", "opus", "ogg", "flac", "wav", "aac"))


def public_format(value, index):
    size = positive(value.get("filesize")) or positive(value.get("filesize_approx"))
    if size and size >= 2 ** 63:
        size = None
    return {
        "id": str(value["format_id"]), "container": value.get("ext") or "",
        "videoCodec": value.get("vcodec") or ("unknown" if contains_video(value) else "none"),
        "audioCodec": value.get("acodec") or ("unknown" if contains_audio(value) else "none"),
        "width": positive(value.get("width")), "height": positive(value.get("height")),
        "fps": positive(value.get("fps")), "audioBitrate": positive(value.get("abr")),
        "bitrate": positive(value.get("tbr")), "byteCount": int(size) if size else None,
        "sizeIsEstimate": not bool(positive(value.get("filesize"))), "rank": index,
        "audioChannels": positive(value.get("audio_channels")),
        "language": value.get("language"),
        "audioSampleRate": positive(value.get("asr")), "videoBitrate": positive(value.get("vbr")),
        "dynamicRange": value.get("dynamic_range"), "formatNote": value.get("format_note"),
        "protocolName": value.get("protocol"),
    }


def usable_formats(info):
    return [value for value in info.get("formats", [])
            if value.get("format_id") and not value.get("has_drm")
            and value.get("url") and (contains_video(value) or contains_audio(value))]


def metadata(info, url):
    formats = usable_formats(info)
    if not formats:
        raise ValueError("No downloadable video or audio formats were found.")
    return {
        "id": str(info.get("id") or "media"), "sourceURL": url,
        "title": info.get("title") or "Untitled media",
        "platform": info.get("extractor_key") or info.get("extractor") or urllib.parse.urlparse(url).hostname,
        "uploader": info.get("uploader") or info.get("channel"), "artist": media_artist(info),
        "duration": positive(info.get("duration")), "thumbnailURL": thumbnail_url(info),
        "formats": [public_format(value, index) for index, value in enumerate(formats)],
    }


def inspect(request, token):
    emit(token, "extracting")
    with yt_dlp.YoutubeDL(options(request, token)) as downloader:
        info = downloader.extract_info(request["url"], download=False)
    check_cancelled(token)
    if info.get("_type") in ("playlist", "multi_video"):
        raise ValueError("This link contains multiple videos. Add a link to one video.")
    if info.get("is_live") or info.get("live_status") in ("is_live", "is_upcoming"):
        raise ValueError("Wait for the livestream to finish, then check the link again.")
    return info


def choose_formats(info, selection):
    available = usable_formats(info)
    audio = [value for value in available if contains_audio(value) and not contains_video(value)]
    video = [value for value in available if contains_video(value)]
    candidates = video if selection["kind"] == "video" else [value for value in available if contains_audio(value)]
    chosen_id = selection.get("formatID")
    best = candidates if selection["kind"] == "video" else (audio or candidates)
    selected = next((value for value in reversed(candidates) if str(value["format_id"]) == chosen_id), None) if chosen_id else (best[-1] if best else None)
    if not selected:
        raise ValueError("That quality is no longer available. Check the link again.")
    if selection["kind"] == "video" and not contains_audio(selected):
        return [selected, audio[-1]] if audio else [selected]
    return [selected]


def run_media(token, arguments, tool="ffmpeg", duration=None):
    check_cancelled(token)
    result = json.loads(native.media(token, json.dumps({"tool": tool, "args": arguments, "duration": duration})))
    check_cancelled(token)
    if result.get("exitCode") != 0:
        raise ValueError("The media could not be prepared for offline playback. Try another quality.")
    return result


def clean_metadata(value, limit=512):
    return re.sub(r"[\x00-\x1f\x7f]", " ", value).strip()[:limit] if isinstance(value, str) else ""


def media_artist(info):
    artists = info.get("artists")
    joined = ", ".join(value for value in artists if isinstance(value, str)) if isinstance(artists, list) else ""
    return clean_metadata(info.get("artist") or joined or info.get("uploader") or info.get("channel")) or None


def output_support(token):
    global _output_support
    if _output_support is None:
        encoders = run_media(token, ["-hide_banner", "-encoders"])
        muxers = run_media(token, ["-hide_banner", "-muxers"])
        encoder_names = set()
        muxer_names = set()
        for line in (encoders["stdout"] + "\n" + encoders["stderr"]).splitlines():
            parts = line.split()
            if len(parts) > 1 and len(parts[0]) == 6 and parts[0][0] in "AVS" and parts[1] != "=":
                encoder_names.add(parts[1])
        for line in (muxers["stdout"] + "\n" + muxers["stderr"]).splitlines():
            parts = line.split()
            if len(parts) > 1 and len(parts[0]) <= 3 and "E" in parts[0] and parts[1] != "=":
                muxer_names.update(parts[1].split(","))
        _output_support = encoder_names, muxer_names
    return _output_support


def requested_output(request, token):
    chosen = request["selection"].get("outputFormat") or "automatic"
    requirements = {
        "mp4": (None, "mp4"), "mov": (None, "mov"), "m4a": ("aac", "ipod"),
        "aac": ("aac", "adts"), "mp3": ("libmp3lame", "mp3"), "flac": ("flac", "flac"),
        "alac": ("alac", "ipod"), "wav": ("pcm_s16le", "wav"),
        "aiff": ("pcm_s16be", "aiff"), "caf": ("pcm_s16le", "caf"),
    }
    if chosen == "automatic":
        return chosen
    if chosen not in requirements or (chosen in ("mp4", "mov")) != (request["selection"]["kind"] == "video"):
        raise ValueError("That file format isn't available for this media. Choose another format.")
    encoder, muxer = requirements[chosen]
    encoders, muxers = output_support(token)
    if muxer not in muxers or (encoder and encoder not in encoders):
        raise ValueError("That file format isn't supported by this build. Choose another format.")
    return chosen


def real_video_stream(probe):
    return next((value for value in probe.get("streams", [])
                 if value.get("codec_type") == "video" and not value.get("disposition", {}).get("attached_pic")), None)


def probe_file(path, token, max_pixels=None):
    arguments = ["-v", "error"]
    if max_pixels:
        arguments.extend(["-max_pixels", str(max_pixels)])
    arguments.extend(["-show_streams", "-of", "json", str(path)])
    return json.loads(run_media(token, arguments, "ffprobe")["stdout"])


def metadata_arguments(title, artist):
    result = ["-metadata", "title=" + title]
    if artist:
        result.extend(["-metadata", "artist=" + artist])
    return result


class ArtworkRedirect(urllib.request.HTTPRedirectHandler):
    max_redirections = 5
    max_repeats = 2

    def redirect_request(self, request, response, code, message, headers, url):
        validate_artwork_url(url)
        return super().redirect_request(request, response, code, message, headers, url)


def validate_artwork_url(url):
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
        raise ValueError("The artwork link isn't a public HTTPS image.")


def thumbnail_url(info):
    thumbnails = info.get("thumbnails") or []
    candidates = [info.get("thumbnail")] + [value.get("url") for value in reversed(thumbnails) if isinstance(value, dict)]
    for url in candidates:
        if isinstance(url, str) and url:
            try:
                validate_artwork_url(url)
                return url
            except ValueError:
                continue
    return None


def save_json(value, destination):
    temporary = destination.with_name(destination.name + ".pending")
    temporary.write_text(json.dumps(value, allow_nan=False), encoding="utf-8")
    temporary.replace(destination)


def artwork_client():
    context = ssl.create_default_context(cafile=certifi.where())
    return urllib.request.build_opener(ArtworkRedirect(), urllib.request.HTTPSHandler(context=context))


def download_artwork(info, directory, token):
    check_cancelled(token)
    url = thumbnail_url(info)
    if not url:
        return None
    source = directory / "artwork-source"
    pending = directory / "artwork-pending.jpg"
    output = directory / "artwork.jpg"
    marker = directory / "artwork.json"
    try:
        validate_artwork_url(url)
        identity = hashlib.sha256(url.encode()).hexdigest()
        if output.is_file() and 0 < output.stat().st_size <= _JPEG_LIMIT and marker.is_file():
            if json.loads(marker.read_text(encoding="utf-8")).get("identity") == identity:
                return output
        started = time.monotonic()
        check_cancelled(token)
        opener = artwork_client()
        headers = {name: value for name, value in (info.get("http_headers") or {}).items()
                   if name.lower() in ("user-agent", "referer", "origin") and isinstance(value, str)}
        with opener.open(urllib.request.Request(url, headers=headers), timeout=10) as response:
            validate_artwork_url(response.geturl())
            if not 200 <= response.status < 300:
                return None
            mime = response.headers.get("Content-Type", "").split(";")[0].lower()
            length = response.headers.get("Content-Length")
            if mime not in ("image/jpeg", "image/png", "image/webp") or (length and int(length) > _ARTWORK_LIMIT):
                return None
            received = 0
            with source.open("wb") as destination:
                while True:
                    check_cancelled(token)
                    if time.monotonic() - started > 25:
                        raise ValueError("The artwork took too long to download.")
                    data = response.read(min(65_536, _ARTWORK_LIMIT + 1 - received))
                    if not data:
                        break
                    received += len(data)
                    if received > _ARTWORK_LIMIT:
                        raise ValueError("The artwork is too large.")
                    destination.write(data)
        check_cancelled(token)
        image = next((value for value in probe_file(source, token, max_pixels=_ARTWORK_PIXELS).get("streams", []) if value.get("codec_type") == "video"), None)
        width = positive(image.get("width")) if image else None
        height = positive(image.get("height")) if image else None
        if not width or not height or width * height > _ARTWORK_PIXELS:
            return None
        run_media(token, ["-nostdin", "-y", "-max_pixels", str(_ARTWORK_PIXELS), "-threads", "1", "-i", str(source),
                          "-frames:v", "1", "-threads", "1",
                          "-vf", "scale=w='min(720,iw)':h='min(720,ih)':force_original_aspect_ratio=decrease",
                          "-q:v", "3", str(pending)])
        if not pending.is_file() or not 0 < pending.stat().st_size <= _JPEG_LIMIT:
            return None
        pending.replace(output)
        save_json({"identity": identity}, marker)
        return output
    except Exception:
        return None
    finally:
        source.unlink(missing_ok=True)
        pending.unlink(missing_ok=True)


def prepare_audio(paths, probes, chosen, title, artist, directory, token, duration, metadata_title=None):
    stream = next((value for value in probes[0].get("streams", []) if value.get("codec_type") == "audio"), None)
    if not stream:
        raise ValueError("This media has no audio stream. Choose video instead.")
    codec = stream.get("codec_name") or ""
    extension = paths[0].suffix.lower()
    if chosen == "automatic" and not real_video_stream(probes[0]) and not artist and codec in (
            "aac", "mp3", "flac", "alac", "ac3", "eac3", "pcm_s16le", "pcm_s24le") and extension in (
            ".m4a", ".mp3", ".flac", ".wav", ".aac"):
        output = directory / (title + extension)
        shutil.copyfile(paths[0], output)
        return output
    if chosen == "automatic":
        chosen = {"aac": "m4a", "alac": "alac", "mp3": "mp3", "flac": "flac"}.get(codec, "flac")
    extension = ".m4a" if chosen == "alac" else "." + chosen
    output = directory / (title + extension)
    matching = {"m4a": "aac", "aac": "aac", "mp3": "mp3", "flac": "flac", "alac": "alac"}
    encoder = {"m4a": "aac", "aac": "aac", "mp3": "libmp3lame", "flac": "flac", "alac": "alac",
               "wav": "pcm_s16le", "aiff": "pcm_s16be", "caf": "pcm_s16le"}[chosen]
    if chosen in ("wav", "aiff", "caf"):
        bits = positive(stream.get("bits_per_raw_sample")) or positive(stream.get("bits_per_sample")) or 0
        if bits > 16 or stream.get("sample_fmt") in ("flt", "fltp", "dbl", "dblp", "s32", "s32p"):
            encoder = "pcm_s24be" if chosen == "aiff" else "pcm_s24le"
    arguments = ["-nostdin", "-y", "-i", str(paths[0]), "-vn", "-map", "0:a:0", "-c:a",
                 "copy" if matching.get(chosen) == codec else encoder]
    if matching.get(chosen) != codec:
        if chosen in ("aac", "m4a"):
            arguments.extend(["-b:a", "320k"])
        elif chosen == "mp3":
            arguments.extend(["-b:a", "320k"])
    arguments.extend(metadata_arguments(metadata_title or title, artist))
    if extension == ".m4a":
        arguments.extend(["-movflags", "+faststart"])
    arguments.append(str(output))
    run_media(token, arguments, duration=duration)
    return output


def embed_artwork(output, artwork, title, artist, token, duration):
    if not artwork or output.suffix.lower() not in (".mp3", ".m4a", ".flac"):
        return False
    pending = output.with_name("covered-" + output.name)
    try:
        arguments = ["-nostdin", "-y", "-i", str(output), "-i", str(artwork), "-map", "0:a:0", "-map", "1:v:0",
                     "-c:a", "copy", "-c:v", "copy", "-disposition:v:0", "attached_pic",
                     "-metadata:s:v:0", "title=Album cover", "-metadata:s:v:0", "comment=Cover (front)"]
        arguments.extend(metadata_arguments(title, artist))
        if output.suffix.lower() == ".mp3":
            arguments.extend(["-id3v2_version", "3"])
        elif output.suffix.lower() == ".m4a":
            arguments.extend(["-movflags", "+faststart"])
        arguments.append(str(pending))
        run_media(token, arguments, duration=duration)
        probe = probe_file(pending, token)
        has_audio = any(value.get("codec_type") == "audio" for value in probe.get("streams", []))
        has_cover = any(value.get("disposition", {}).get("attached_pic") for value in probe.get("streams", []))
        if not pending.is_file() or pending.stat().st_size == 0 or not has_audio or not has_cover:
            return False
        pending.replace(output)
        return True
    except Exception:
        return False
    finally:
        pending.unlink(missing_ok=True)


def download(request, token):
    info = inspect(request, token)
    selected = choose_formats(info, request["selection"])
    directory = Path(request["directory"])
    directory.mkdir(parents=True, exist_ok=True)
    chosen = requested_output(request, token)
    totals = [positive(value.get("filesize")) for value in selected]
    completed_bytes = 0
    paths = []
    progress_lock = threading.Lock()
    for index, value in enumerate(selected):
        check_cancelled(token)
        last_progress = 0.0

        def progress(status):
            nonlocal completed_bytes, last_progress
            check_cancelled(token)
            with progress_lock:
                total = positive(status.get("total_bytes"))
                if total: totals[index] = total
                now = time.monotonic()
                if status.get("status") != "finished" and now - last_progress < 0.1: return
                last_progress = now
                expected = int(sum(totals)) if all(totals) else None
                received = completed_bytes + max(0, int(status.get("downloaded_bytes") or 0))
                emit(token, "downloading", receivedBytes=received, expectedBytes=expected)

        configured = options(request, token)
        checkpoint = hashlib.sha256(str(value["format_id"]).encode()).hexdigest()[:16]
        configured.update({"format": str(value["format_id"]), "outtmpl": str(directory / f"stream-{index}-{checkpoint}.%(ext)s"), "progress_hooks": [progress]})
        with yt_dlp.YoutubeDL(configured) as downloader:
            result = downloader.process_ie_result(copy.deepcopy(info), download=True)
            path = Path(downloader.prepare_filename(result))
        if not path.is_file() or path.stat().st_size == 0:
            raise ValueError("The source did not return a complete media file.")
        completed_bytes += path.stat().st_size
        paths.append(path)
    duration = positive(info.get("duration"))
    emit(token, "processing", expectedSeconds=duration)
    title = re.sub(r"[\\/\x00-\x1f]", " ", info.get("title") or "Media").strip()
    title = title.encode("utf-8")[:160].decode("utf-8", errors="ignore").strip() or "Media"
    metadata_title = clean_metadata(info.get("title")) or title
    is_audio = request["selection"]["kind"] == "audio"
    artist = media_artist(info)
    probes = [probe_file(path, token) for path in paths]
    video_stream = real_video_stream(probes[0])
    audio_stream = next((value for value in probes[-1]["streams"] if value["codec_type"] == "audio"), None)
    audio_codec = audio_stream.get("codec_name") or "" if audio_stream else ""
    artwork = download_artwork(info, directory, token) if is_audio else None
    artwork_embedded = False
    if is_audio:
        output = prepare_audio(paths, probes, chosen, title, artist, directory, token, duration, metadata_title)
        artwork_embedded = embed_artwork(output, artwork, metadata_title, artist, token, duration)
    else:
        output = directory / (title + (".mov" if chosen == "mov" else ".mp4"))
        args = ["-nostdin", "-y", "-i", str(paths[0])]
        if len(paths) > 1: args.extend(["-i", str(paths[1])])
        args.extend(["-map", "0:v:0"])
        if audio_stream: args.extend(["-map", "1:a:0" if len(paths) > 1 else "0:a:0"])
        if not video_stream:
            raise ValueError("This media has no video stream. Choose audio instead.")
        video_codec = video_stream.get("codec_name") or ""
        if video_codec in ("h264", "hevc") or (video_codec == "av1" and request.get("supportsAV1")):
            args.extend(["-c:v", "copy"])
            if video_codec == "hevc": args.extend(["-tag:v", "hvc1"])
        else:
            args.extend(["-c:v", "hevc_videotoolbox", "-q:v", "75", "-tag:v", "hvc1"])
        if not audio_stream: args.append("-an")
        elif audio_codec in ("aac", "mp3", "ac3", "eac3"):
            args.extend(["-c:a", "copy"])
        else:
            args.extend(["-c:a", "aac", "-b:a", "320k"])
        args.extend(["-movflags", "+faststart"] + metadata_arguments(metadata_title, artist) + [str(output)])
        run_media(token, args, duration=duration)
    check_cancelled(token)
    if not output.is_file() or output.stat().st_size == 0:
        raise ValueError("The prepared media file is missing. Retry the download.")
    result = {"fileName": output.name, "title": metadata_title,
              "artist": artist, "uploader": clean_metadata(info.get("uploader") or info.get("channel")) or None,
              "thumbnailFileName": artwork.name if artwork else None, "artworkEmbedded": artwork_embedded}
    save_json(result, directory / "source-result.json")
    check_cancelled(token)
    return result


def user_error(error):
    text = str(error)
    lowered = text.lower()
    if any(value in lowered for value in ("sign in", "login", "log in", "cookies", "not a bot", "private video")):
        return "This source requires a sign-in or verification. Try another public link."
    if "403" in lowered or "forbidden" in lowered:
        return "The source refused this download. Check the link again or try later."
    if "unsupported url" in lowered:
        return "This link isn't supported. Use a video or audio link from a supported site."
    if "timed out" in lowered or "timeout" in lowered:
        return "The source took too long to respond. Check your connection and try again."
    text = re.sub(r"https?://\S+", "the source", text)
    text = re.sub(r"\x1b\[[0-9;]*m", "", text)
    return text.removeprefix("ERROR: ")[:450] or "Couldn't download this link. Try again."


def run(raw_request, token=None):
    reset = _operation.set(token)
    try:
        request = json.loads(raw_request)
        url = urllib.parse.urlsplit(request["url"])
        if url.scheme != "https" or not url.hostname or url.username or url.password:
            raise ValueError("Use an HTTPS link without a username or password.")
        if request["action"] == "inspect":
            value = metadata(inspect(request, token), request["url"])
        elif request["action"] == "download":
            value = download(request, token)
        else:
            raise ValueError("Unknown media action.")
        return json.dumps({"ok": True, "value": value}, allow_nan=False)
    except Cancelled:
        return json.dumps({"ok": False, "cancelled": True, "error": "Cancelled"})
    except Exception as error:
        return json.dumps({"ok": False, "error": user_error(error)})
    finally:
        _operation.reset(reset)
