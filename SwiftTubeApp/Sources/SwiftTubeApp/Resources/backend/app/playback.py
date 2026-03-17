from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Iterable, List, Optional

from yt_dlp import YoutubeDL

from .models import StreamInfo


@dataclass
class PlaybackBundle:
    title: Optional[str]
    duration_text: Optional[str]
    streams: List[StreamInfo]
    preferred_muxed_stream: Optional[StreamInfo]
    preferred_video_stream: Optional[StreamInfo]
    preferred_audio_stream: Optional[StreamInfo]

    @property
    def playback_strategy(self) -> str:
        if (
            self.preferred_video_stream is not None
            and self.preferred_audio_stream is not None
            and (
                self.preferred_muxed_stream is None
                or (self.preferred_video_stream.height or 0)
                > (self.preferred_muxed_stream.height or 0)
            )
        ):
            return "adaptivePair"
        return "direct"

    @property
    def best_stream(self) -> Optional[StreamInfo]:
        return self.preferred_muxed_stream or self.preferred_video_stream

    @property
    def best_stream_url(self) -> Optional[str]:
        stream = self.best_stream
        return stream.url if stream else None


def _format_duration(seconds: Any) -> Optional[str]:
    if not isinstance(seconds, (int, float)) or seconds <= 0:
        return None

    total = int(seconds)
    hours, remainder = divmod(total, 3600)
    minutes, secs = divmod(remainder, 60)
    if hours:
        return f"{hours}:{minutes:02d}:{secs:02d}"
    return f"{minutes}:{secs:02d}"


def _quality_label(format_data: dict[str, Any]) -> Optional[str]:
    label = format_data.get("format_note")
    if isinstance(label, str) and label:
        return label
    height = format_data.get("height")
    if isinstance(height, int) and height > 0:
        return f"{height}p"
    return None


def _mime_type(format_data: dict[str, Any]) -> Optional[str]:
    ext = format_data.get("ext")
    if not isinstance(ext, str):
        return None

    vcodec = format_data.get("vcodec")
    acodec = format_data.get("acodec")
    has_video = isinstance(vcodec, str) and vcodec != "none"
    has_audio = isinstance(acodec, str) and acodec != "none"

    if has_video and has_audio:
        return f"video/{ext}"
    if has_video:
        return f"video/{ext}"
    if has_audio:
        return f"audio/{ext}"
    return None


def _codec_score(codec: Optional[str]) -> int:
    if not isinstance(codec, str):
        return 0
    if codec.startswith("avc1"):
        return 5
    if codec.startswith(("hvc1", "hev1")):
        return 4
    if codec.startswith("av01"):
        return 3
    if codec.startswith("vp9"):
        return 2
    if codec.startswith("mp4a"):
        return 4
    if codec.startswith("opus"):
        return 3
    return 1


def _stream_score(stream: StreamInfo) -> tuple[int, int, int, int, int]:
    return (
        stream.height or 0,
        stream.fps or 0,
        stream.bitrate or 0,
        _codec_score(stream.videoCodec),
        _codec_score(stream.audioCodec),
    )


def _is_direct_protocol(protocol: Any) -> bool:
    if not isinstance(protocol, str):
        return False
    return protocol.startswith(("http", "https", "m3u8"))


def _build_streams(formats: Iterable[dict[str, Any]]) -> List[StreamInfo]:
    streams: List[StreamInfo] = []

    for format_data in formats:
        if not isinstance(format_data, dict):
            continue

        url = format_data.get("url")
        if not isinstance(url, str) or not url:
            continue

        protocol = format_data.get("protocol")
        if not _is_direct_protocol(protocol):
            continue

        vcodec = format_data.get("vcodec")
        acodec = format_data.get("acodec")
        has_video = isinstance(vcodec, str) and vcodec != "none"
        has_audio = isinstance(acodec, str) and acodec != "none"
        bitrate = format_data.get("tbr")
        if isinstance(bitrate, (int, float)):
            bitrate = int(bitrate * 1000)
        else:
            bitrate = None

        streams.append(
            StreamInfo(
                url=url,
                formatId=str(format_data.get("format_id"))
                if format_data.get("format_id") is not None
                else None,
                mimeType=_mime_type(format_data),
                qualityLabel=_quality_label(format_data),
                bitrate=bitrate,
                width=format_data.get("width"),
                height=format_data.get("height"),
                fps=format_data.get("fps"),
                audioCodec=acodec,
                videoCodec=vcodec,
                container=format_data.get("container") or format_data.get("ext"),
                hasAudio=has_audio,
                hasVideo=has_video,
                isAdaptive=has_audio != has_video,
            )
        )

    return streams


def _best_muxed_stream(streams: List[StreamInfo]) -> Optional[StreamInfo]:
    candidates = [
        stream
        for stream in streams
        if stream.hasAudio
        and stream.hasVideo
        and (stream.container or "").startswith(("mp4", "mov"))
    ]
    if not candidates:
        return None
    return max(candidates, key=_stream_score)


def _best_video_stream(streams: List[StreamInfo]) -> Optional[StreamInfo]:
    candidates = [
        stream
        for stream in streams
        if stream.hasVideo
        and not stream.hasAudio
        and (stream.container or "").startswith("mp4")
        and _codec_score(stream.videoCodec) >= 3
    ]
    if not candidates:
        return None
    return max(candidates, key=_stream_score)


def _best_audio_stream(streams: List[StreamInfo]) -> Optional[StreamInfo]:
    candidates = [
        stream
        for stream in streams
        if stream.hasAudio
        and not stream.hasVideo
        and (stream.container or "").startswith(("m4a", "mp4"))
    ]
    if not candidates:
        return None
    return max(candidates, key=_stream_score)


def extract_playback(video_id: str) -> PlaybackBundle:
    opts = {
        "quiet": True,
        "no_warnings": True,
        "noplaylist": True,
        "extract_flat": False,
        "skip_download": True,
        "js_runtimes": {"node": {}},
    }

    with YoutubeDL(opts) as ydl:
        info = ydl.extract_info(
            f"https://www.youtube.com/watch?v={video_id}", download=False
        )

    formats = info.get("formats", []) if isinstance(info, dict) else []
    streams = _build_streams(formats if isinstance(formats, list) else [])

    return PlaybackBundle(
        title=info.get("title") if isinstance(info, dict) else None,
        duration_text=_format_duration(info.get("duration") if isinstance(info, dict) else None),
        streams=streams,
        preferred_muxed_stream=_best_muxed_stream(streams),
        preferred_video_stream=_best_video_stream(streams),
        preferred_audio_stream=_best_audio_stream(streams),
    )
