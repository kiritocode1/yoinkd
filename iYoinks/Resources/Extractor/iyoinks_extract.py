"""Resolve public media links and acquire selected source formats in-process."""

import contextvars
import copy
import hashlib
import json
import math
from pathlib import Path
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.parse

import _iy_native as native
import yt_dlp
from yt_dlp.extractor.youtube.jsc._builtin.quickjs import QuickJSJCP
from yt_dlp.utils._jsruntime import JsRuntimeInfo, QuickJsRuntime


_operation = contextvars.ContextVar("iyoinks_operation", default=None)


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
    return {
        "id": str(value["format_id"]), "container": value.get("ext") or "",
        "videoCodec": value.get("vcodec") or ("unknown" if contains_video(value) else "none"),
        "audioCodec": value.get("acodec") or ("unknown" if contains_audio(value) else "none"),
        "width": positive(value.get("width")), "height": positive(value.get("height")),
        "fps": positive(value.get("fps")), "audioBitrate": positive(value.get("abr")),
        "bitrate": positive(value.get("tbr")), "byteCount": int(size) if size else None,
        "sizeIsEstimate": not bool(value.get("filesize")), "rank": index,
        "audioChannels": positive(value.get("audio_channels")),
        "language": value.get("language"),
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
        "uploader": info.get("uploader") or info.get("channel"),
        "duration": positive(info.get("duration")), "thumbnailURL": info.get("thumbnail"),
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
    candidates = video if selection["kind"] == "video" else (audio or [value for value in available if contains_audio(value)])
    chosen_id = selection.get("formatID")
    selected = next((value for value in reversed(candidates) if value["format_id"] == chosen_id), None) if chosen_id else (candidates[-1] if candidates else None)
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


def download(request, token):
    info = inspect(request, token)
    selected = choose_formats(info, request["selection"])
    directory = Path(request["directory"])
    directory.mkdir(parents=True, exist_ok=True)
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
        configured.update({"format": value["format_id"], "outtmpl": str(directory / f"stream-{index}-{checkpoint}.%(ext)s"), "progress_hooks": [progress]})
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
    is_audio = request["selection"]["kind"] == "audio"
    probes = [json.loads(run_media(token, ["-v", "error", "-show_streams", "-of", "json", str(path)], "ffprobe")["stdout"]) for path in paths]
    video_stream = next((value for value in probes[0]["streams"] if value["codec_type"] == "video"), None)
    audio_stream = next((value for value in probes[-1]["streams"] if value["codec_type"] == "audio"), None)
    audio_codec = audio_stream.get("codec_name") or "" if audio_stream else ""
    if is_audio:
        if not audio_stream:
            raise ValueError("This media has no audio stream. Choose video instead.")
        if not video_stream and audio_codec in ("aac", "mp3", "flac", "alac", "ac3", "eac3", "pcm_s16le", "pcm_s24le") and paths[0].suffix.lower() in (".m4a", ".mp3", ".flac", ".wav", ".aac"):
            output = directory / (title + paths[0].suffix)
            shutil.copyfile(paths[0], output)
        elif audio_codec in ("aac", "alac", "mp3", "flac"):
            extension = {"aac": ".m4a", "alac": ".m4a", "mp3": ".mp3", "flac": ".flac"}[audio_codec]
            output = directory / (title + extension)
            run_media(token, ["-nostdin", "-y", "-i", str(paths[0]), "-vn", "-map", "0:a:0", "-c:a", "copy", "-metadata", "title=" + title, str(output)], duration=duration)
        else:
            # FLAC preserves the decoded source quality when its container cannot play natively.
            output = directory / (title + ".flac")
            run_media(token, ["-nostdin", "-y", "-i", str(paths[0]), "-vn", "-c:a", "flac", "-metadata", "title=" + title, str(output)], duration=duration)
    else:
        output = directory / (title + ".mp4")
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
        args.extend(["-movflags", "+faststart", "-metadata", "title=" + title, str(output)])
        run_media(token, args, duration=duration)
    check_cancelled(token)
    if not output.is_file() or output.stat().st_size == 0:
        raise ValueError("The prepared media file is missing. Retry the download.")
    return {"fileName": output.name, "title": info.get("title") or title}


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
