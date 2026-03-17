from __future__ import annotations

from dataclasses import dataclass, replace
import time
from typing import Any, Iterable, List, Optional

import httpx
from yt_dlp import YoutubeDL
from yt_dlp.cookies import YoutubeDLCookieJar

from .models import StreamInfo
from .provider import build_authenticated_ytdlp_options


_AUTH_PLAYBACK_FAILURE_TTL_SECONDS = 900
_auth_playback_failures: dict[str, float] = {}


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


def _video_playability_score(codec: Optional[str]) -> int:
    if not isinstance(codec, str):
        return 0
    if codec.startswith("avc1"):
        return 4
    if codec.startswith(("hvc1", "hev1")):
        return 3
    if codec.startswith("av01"):
        return 1
    if codec.startswith("vp9"):
        return 0
    return 0


def _stream_score(stream: StreamInfo) -> tuple[int, int, int, int, int]:
    return (
        stream.height or 0,
        stream.fps or 0,
        stream.bitrate or 0,
        _codec_score(stream.videoCodec),
        _codec_score(stream.audioCodec),
    )


def _adaptive_video_score(stream: StreamInfo) -> tuple[int, int, int, int, int]:
    return (
        _video_playability_score(stream.videoCodec),
        stream.height or 0,
        stream.fps or 0,
        stream.bitrate or 0,
        _codec_score(stream.videoCodec),
    )


def _is_direct_protocol(protocol: Any) -> bool:
    if not isinstance(protocol, str):
        return False
    return protocol.startswith(("http", "https", "m3u8"))


def _is_manifest_url(url: str) -> bool:
    lowered = url.lower()
    return (
        "manifest.googlevideo.com" in lowered
        or "/api/manifest/" in lowered
        or lowered.endswith(".m3u8")
        or "/playlist/index.m3u8" in lowered
    )


def _auth_cache_key(auth_options: dict[str, Any]) -> str:
    cookie_file = auth_options.get("cookiefile")
    extractor_args = auth_options.get("extractor_args") or {}
    youtube_args = extractor_args.get("youtube") if isinstance(extractor_args, dict) else {}
    clients = youtube_args.get("player_client") if isinstance(youtube_args, dict) else []
    if not isinstance(clients, list):
        clients = []
    client_key = ",".join(client for client in clients if isinstance(client, str))
    return f"{cookie_file or ''}|{client_key}"


def _uses_po_token_provider(auth_options: dict[str, Any]) -> bool:
    extractor_args = auth_options.get("extractor_args") or {}
    youtube_args = extractor_args.get("youtube") if isinstance(extractor_args, dict) else {}
    clients = youtube_args.get("player_client") if isinstance(youtube_args, dict) else []
    if not isinstance(clients, list):
        return False
    return any(client in {"mweb", "web_music"} for client in clients if isinstance(client, str))


def _should_attempt_authenticated_playback(auth_options: dict[str, Any]) -> bool:
    key = _auth_cache_key(auth_options)
    failure_deadline = _auth_playback_failures.get(key)
    if failure_deadline is not None and failure_deadline > time.time():
        return False

    return True


def _remember_authenticated_playback_failure(auth_options: dict[str, Any]) -> None:
    _auth_playback_failures[_auth_cache_key(auth_options)] = (
        time.time() + _AUTH_PLAYBACK_FAILURE_TTL_SECONDS
    )


def _clear_authenticated_playback_failure(auth_options: dict[str, Any]) -> None:
    _auth_playback_failures.pop(_auth_cache_key(auth_options), None)


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
                httpHeaders={
                    key: value
                    for key, value in (format_data.get("http_headers") or {}).items()
                    if isinstance(key, str) and isinstance(value, str)
                },
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
        and not _is_manifest_url(stream.url)
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
    # Prefer AVFoundation-friendly codecs over raw resolution so the native player
    # gets a stream it can actually render.
    return max(candidates, key=_adaptive_video_score)


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


def _extract_playback(video_id: str, opts: dict[str, Any]) -> PlaybackBundle:
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


def _probe_client(
    stream: StreamInfo,
    auth_options: Optional[dict[str, Any]],
) -> httpx.Client:
    client = httpx.Client(
        follow_redirects=True,
        headers=stream.httpHeaders or {},
        timeout=8.0,
    )

    cookie_file = auth_options.get("cookiefile") if auth_options else None
    if isinstance(cookie_file, str) and cookie_file:
        jar = YoutubeDLCookieJar(cookie_file)
        jar.load(ignore_discard=True, ignore_expires=True)
        for cookie in jar:
            client.cookies.set(
                cookie.name,
                cookie.value,
                domain=cookie.domain,
                path=cookie.path,
            )

    return client


def _stream_is_reachable(
    stream: StreamInfo,
    auth_options: Optional[dict[str, Any]],
) -> bool:
    if _is_manifest_url(stream.url):
        return False

    try:
        with _probe_client(stream, auth_options) as client:
            response = client.head(stream.url)
            if 200 <= response.status_code < 300:
                return True

            # Some hosts don't answer HEAD cleanly, so fall back to a 1-byte range GET.
            with client.stream(
                "GET",
                stream.url,
                headers={"Range": "bytes=0-0"},
            ) as fallback:
                return 200 <= fallback.status_code < 300
    except Exception:
        return False


def _validated_authenticated_bundle(
    bundle: PlaybackBundle,
    auth_options: dict[str, Any],
) -> Optional[PlaybackBundle]:
    muxed_candidates = sorted(
        [
            stream
            for stream in bundle.streams
            if stream.hasAudio
            and stream.hasVideo
            and not _is_manifest_url(stream.url)
        ],
        key=_stream_score,
        reverse=True,
    )

    reachable_muxed_stream = None
    for candidate in muxed_candidates[:2]:
        if _stream_is_reachable(candidate, auth_options):
            reachable_muxed_stream = candidate
            break

    video_candidates = sorted(
        [
            stream
            for stream in bundle.streams
            if stream.hasVideo
            and not stream.hasAudio
            and (stream.container or "").startswith("mp4")
        ],
        key=_adaptive_video_score,
        reverse=True,
    )
    audio_candidates = sorted(
        [
            stream
            for stream in bundle.streams
            if stream.hasAudio
            and not stream.hasVideo
            and (stream.container or "").startswith(("m4a", "mp4"))
        ],
        key=_stream_score,
        reverse=True,
    )

    reachable_video_stream = next(
        (
            candidate
            for candidate in video_candidates[:2]
            if _stream_is_reachable(candidate, auth_options)
        ),
        None,
    )
    reachable_audio_stream = next(
        (
            candidate
            for candidate in audio_candidates[:2]
            if _stream_is_reachable(candidate, auth_options)
        ),
        None,
    )

    if (
        reachable_video_stream is not None
        and reachable_audio_stream is not None
        and (
            reachable_muxed_stream is None
            or (reachable_video_stream.height or 0)
            > (reachable_muxed_stream.height or 0)
        )
    ):
        return replace(
            bundle,
            preferred_muxed_stream=reachable_muxed_stream,
            preferred_video_stream=reachable_video_stream,
            preferred_audio_stream=reachable_audio_stream,
        )

    if reachable_muxed_stream is not None:
        return replace(
            bundle,
            preferred_muxed_stream=reachable_muxed_stream,
            preferred_video_stream=None,
            preferred_audio_stream=None,
        )

    return None


def extract_playback(video_id: str, auth_options: Optional[dict[str, Any]] = None) -> PlaybackBundle:
    public_opts = {
        "quiet": True,
        "no_warnings": True,
        "noplaylist": True,
        "extract_flat": False,
        "skip_download": True,
        "js_runtimes": {"node": {}},
        "extractor_args": {"youtube": {"player_client": ["android"]}},
    }

    if auth_options and _should_attempt_authenticated_playback(auth_options):
        try:
            authenticated_opts = dict(public_opts)
            if _uses_po_token_provider(auth_options):
                authenticated_opts.update(build_authenticated_ytdlp_options(auth_options))
            else:
                authenticated_opts.update(auth_options)
            authenticated_bundle = _extract_playback(video_id, authenticated_opts)
            validated_bundle = _validated_authenticated_bundle(
                authenticated_bundle,
                auth_options,
            )
            if validated_bundle is not None:
                _clear_authenticated_playback_failure(auth_options)
                return validated_bundle
        except Exception:
            pass
        _remember_authenticated_playback_failure(auth_options)

    return _extract_playback(video_id, public_opts)
