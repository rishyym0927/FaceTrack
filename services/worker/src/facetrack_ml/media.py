from __future__ import annotations

import json
import math
import shutil
import subprocess
import threading
import time
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from .errors import SpikeError


@dataclass(frozen=True)
class MediaInfo:
    width: int
    height: int
    duration: float
    codec: str
    size: int


def executable(name: str) -> str:
    candidate = shutil.which(name)
    if candidate:
        return candidate
    # The imageio wheel supplies FFmpeg; its binary also supports the validate/decode path.
    if name == "ffmpeg":
        import imageio_ffmpeg
        return imageio_ffmpeg.get_ffmpeg_exe()
    raise SpikeError("TOOL_MISSING", f"Install {name} or add .tools/bin to PATH.")


def packet_frame_rate(path: Path, duration: float) -> float:
    """Chrome VFR WebM can advertise avg=0/0 and a meaningless 1000fps time base.

    Inspect bounded actual video packet timestamps instead of trusting r_frame_rate.
    Called only after container/size/duration checks, with the same 15s probe timeout.
    """
    result = subprocess.run([
        executable("ffprobe"), "-v", "error", "-protocol_whitelist", "file,pipe",
        "-select_streams", "v:0", "-read_intervals", "%+#1801", "-show_packets",
        "-show_entries", "packet=pts_time", "-of", "json", str(path.resolve())],
        capture_output=True, timeout=15, check=True)
    packets = json.loads(result.stdout)["packets"]
    if not 2 <= len(packets) <= 1800:
        raise ValueError("Invalid bounded packet count")
    stamps = sorted(float(packet["pts_time"]) for packet in packets)
    if (not all(math.isfinite(stamp) for stamp in stamps)
            or len(set(stamps)) != len(stamps) or stamps[0] < 0
            or stamps[-1] > duration + 0.1):
        raise ValueError("Invalid packet timestamp sequence")
    return (len(stamps) - 1) / (stamps[-1] - stamps[0])


def probe(path: Path, *, enrollment: bool = False) -> MediaInfo:
    if not path.is_file() or path.is_symlink():
        raise SpikeError("INVALID_MEDIA", "Provide a regular local video file, not a symlink.")
    limit = (25 if enrollment else 50) * 1024 * 1024
    if path.stat().st_size > limit:
        raise SpikeError("MEDIA_TOO_LARGE", "The video exceeds the permitted size.")
    try:
        result = subprocess.run([
            executable("ffprobe"), "-v", "error", "-protocol_whitelist", "file,pipe",
            "-show_streams", "-show_format", "-of", "json", str(path.resolve())],
            capture_output=True, timeout=15, check=True)
        data = json.loads(result.stdout)
        if any(s["codec_type"] == "audio" for s in data["streams"]):
            raise SpikeError("AUDIO_NOT_ALLOWED", "Re-record without audio before processing.")
        videos = [s for s in data["streams"] if s["codec_type"] == "video"]
        if len(videos) != 1:
            raise ValueError()
        stream = videos[0]
        duration = float(data["format"].get("duration", stream.get("duration", 0)))
        width, height = int(stream["width"]), int(stream["height"])
        codec = stream["codec_name"]
        if (not 0 < duration <= 30 or not 0 < min(width, height)
                or max(width, height) > 1920 or width * height > 1920 * 1080
                or codec not in {"h264", "vp8", "vp9"}):
            raise ValueError()
        rate_num, rate_den = stream.get("avg_frame_rate", "0/0").split("/")
        numerator, denominator = float(rate_num), float(rate_den)
        fps = numerator / denominator if denominator else 0
        if not math.isfinite(fps) or fps <= 0:
            fps = packet_frame_rate(path, duration)
        if not 0 < fps <= 60 or duration * fps > 1800:
            raise ValueError()
        if any(s.get("side_data_type") == "Display Matrix" and s.get("rotation", 0) != 0
               for s in stream.get("side_data_list", [])):
            raise SpikeError("ROTATED_MEDIA", "Re-encode the clip upright before processing.")
        return MediaInfo(width, height, duration, codec, path.stat().st_size)
    except SpikeError:
        raise
    except (OSError, ValueError, KeyError, ZeroDivisionError, subprocess.SubprocessError) as e:
        raise SpikeError("INVALID_MEDIA", "Video is corrupt or outside the supported media profile.") from e


def sampled_frames(path: Path, info: MediaInfo, count: int, timings: dict):
    """Bounded subprocess decoding, yielding pixels in memory without saving face crops."""
    count = min(max(count, 1), 100)
    rate = count / info.duration
    command = [executable("ffmpeg"), "-nostdin", "-v", "error", "-noautorotate",
               "-protocol_whitelist", "file,pipe", "-i", str(path.resolve()), "-an",
               "-vf", f"fps={rate:.8f},scale={info.width}:{info.height}",
               "-frames:v", str(count), "-f", "rawvideo", "-pix_fmt", "bgr24", "pipe:1"]
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    watchdog = threading.Timer(300, process.kill)
    watchdog.daemon = True
    watchdog.start()
    size = info.width * info.height * 3
    try:
        for index in range(count):
            start = time.perf_counter()
            raw = process.stdout.read(size)
            timings["decoding_ms"] = timings.get("decoding_ms", 0) + (
                time.perf_counter() - start) * 1000
            if not raw:
                break
            if len(raw) != size:
                raise SpikeError("DECODE_FAILED", "Decoder returned an incomplete frame.")
            yield round((index + 0.5) * 1000 / rate), np.frombuffer(
                raw, np.uint8).reshape(info.height, info.width, 3)
        if process.wait(timeout=5) != 0:
            raise SpikeError("DECODE_FAILED", "Decoder failed or exceeded its time limit.")
    finally:
        watchdog.cancel()
        if process.poll() is None:
            process.kill()
        process.wait()
        if process.stdout:
            process.stdout.close()
