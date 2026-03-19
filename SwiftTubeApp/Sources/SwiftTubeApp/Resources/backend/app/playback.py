from __future__ import annotations

from dataclasses import dataclass, replace
from typing import Any, Iterable, List, Optional

import httpx
from yt_dlp import YoutubeDL
from yt_dlp.cookies import YoutubeDLCookieJar
from yt_dlp.extractor.youtube.jsc._builtin.ejs import EJSBaseJCP

from .models import StreamInfo, SubtitleTrack
from .provider import build_authenticated_ytdlp_options

_YTDLP_JS_CHALLENGE_PATCHED = False
_YTDLP_NODE_LOCATION_POLYFILL = """\
if (typeof globalThis.self === "undefined") { globalThis.self = globalThis; }
if (!globalThis.location) { globalThis.location = { origin: "https://www.youtube.com" }; }
if (!globalThis.self.location) { globalThis.self.location = globalThis.location; }
"""


@dataclass
class PlaybackBundle:
    title: Optional[str]
    duration_text: Optional[str]
    streams: List[StreamInfo]
    preferred_manifest_stream: Optional[StreamInfo]
    preferred_muxed_stream: Optional[StreamInfo]
    preferred_video_stream: Optional[StreamInfo]
    preferred_audio_stream: Optional[StreamInfo]
    subtitles: List[SubtitleTrack]

    @property
    def playback_strategy(self) -> str:
        if self.preferred_manifest_stream is not None:
            return "manifest"
        if (
            self.preferred_video_stream is not None
            and self.preferred_audio_stream is not None
            and (
                self.preferred_muxed_stream is None
                or (self.preferred_video_stream.height or 0)
                > (self.preferred_muxed_stream.height or 0)
            )
        ):
            return "mpv"
        return "direct"

    @property
    def best_stream(self) -> Optional[StreamInfo]:
        return (
            self.preferred_manifest_stream
            or self.preferred_muxed_stream
            or self.preferred_video_stream
        )

    @property
    def best_stream_url(self) -> Optional[str]:
        stream = self.best_stream
        return stream.url if stream else None


def _ensure_ytdlp_js_challenge_polyfill() -> None:
    global _YTDLP_JS_CHALLENGE_PATCHED
    if _YTDLP_JS_CHALLENGE_PATCHED:
        return

    original_construct_stdin = EJSBaseJCP._construct_stdin

    def patched_construct_stdin(self, player, preprocessed, requests, /):
        stdin = original_construct_stdin(self, player, preprocessed, requests)
        if _YTDLP_NODE_LOCATION_POLYFILL in stdin:
            return stdin
        return _YTDLP_NODE_LOCATION_POLYFILL + stdin

    EJSBaseJCP._construct_stdin = patched_construct_stdin
    _YTDLP_JS_CHALLENGE_PATCHED = True


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


def _manifest_stream_score(stream: StreamInfo) -> tuple[int, int, int, int, int, int]:
    return (
        1 if stream.hasAudio else 0,
        1 if stream.hasVideo else 0,
        stream.height or 0,
        stream.fps or 0,
        stream.bitrate or 0,
        _codec_score(stream.videoCodec),
    )


def _stream_score(stream: StreamInfo) -> tuple[int, int, int, int, int]:
    return (
        stream.height or 0,
        stream.fps or 0,
        stream.bitrate or 0,
        _codec_score(stream.videoCodec),
        _codec_score(stream.audioCodec),
    )


def _manual_quality_video_score(stream: StreamInfo) -> tuple[int, int, int]:
    return (
        stream.height or 0,
        stream.fps or 0,
        stream.bitrate or 0,
    )


def _audio_channel_preference(stream: StreamInfo) -> tuple[int, int]:
    channels = stream.audioChannels or 0
    if channels == 2:
        return (3, 0)
    if channels == 1:
        return (2, 0)
    if channels > 2:
        return (1, -channels)
    return (0, 0)


def _adaptive_audio_score(stream: StreamInfo) -> tuple[int, int, int, int]:
    channel_preference, channel_tiebreaker = _audio_channel_preference(stream)
    return (
        channel_preference,
        _codec_score(stream.audioCodec),
        channel_tiebreaker,
        stream.bitrate or 0,
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


def _uses_po_token_provider(auth_options: dict[str, Any]) -> bool:
    extractor_args = auth_options.get("extractor_args") or {}
    youtube_args = extractor_args.get("youtube") if isinstance(extractor_args, dict) else {}
    clients = youtube_args.get("player_client") if isinstance(youtube_args, dict) else []
    if not isinstance(clients, list):
        return False
    return any(client in {"mweb", "web_music"} for client in clients if isinstance(client, str))


def _should_attempt_authenticated_playback(auth_options: dict[str, Any]) -> bool:
    return True


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
        stream_kind = _stream_kind(url, has_audio, has_video)

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
                audioChannels=format_data.get("audio_channels"),
                audioCodec=acodec,
                videoCodec=vcodec,
                container=format_data.get("container") or format_data.get("ext"),
                hasAudio=has_audio,
                hasVideo=has_video,
                isAdaptive=has_audio != has_video,
                streamKind=stream_kind,
            )
        )

    return streams


def _stream_kind(url: str, has_audio: bool, has_video: bool) -> str:
    if _is_manifest_url(url):
        return "manifest"
    if has_video and has_audio:
        return "muxed"
    if has_video:
        return "video"
    if has_audio:
        return "audio"
    return "muxed"


def _best_manifest_stream(streams: List[StreamInfo]) -> Optional[StreamInfo]:
    candidates = [
        stream
        for stream in streams
        if stream.streamKind == "manifest" and stream.hasVideo
    ]
    if not candidates:
        return None
    return max(candidates, key=_manifest_stream_score)


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
        and isinstance(stream.videoCodec, str)
        and stream.videoCodec.startswith("av01")
    ]
    if not candidates:
        return None
    return max(candidates, key=_manual_quality_video_score)


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
    return max(candidates, key=_adaptive_audio_score)


_LANGUAGE_LABELS: dict[str, str] = {
    "en": "English", "es": "Spanish", "fr": "French", "de": "German",
    "pt": "Portuguese", "it": "Italian", "ja": "Japanese", "ko": "Korean",
    "zh": "Chinese", "zh-Hans": "Chinese (Simplified)", "zh-Hant": "Chinese (Traditional)",
    "ru": "Russian", "ar": "Arabic", "hi": "Hindi", "nl": "Dutch",
    "sv": "Swedish", "pl": "Polish", "tr": "Turkish", "vi": "Vietnamese",
    "th": "Thai", "id": "Indonesian", "uk": "Ukrainian", "cs": "Czech",
    "ro": "Romanian", "el": "Greek", "hu": "Hungarian", "da": "Danish",
    "fi": "Finnish", "no": "Norwegian", "he": "Hebrew", "ms": "Malay",
    "fil": "Filipino", "bn": "Bengali", "ta": "Tamil", "te": "Telugu",
}


def _language_label(code: str) -> str:
    if code in _LANGUAGE_LABELS:
        return _LANGUAGE_LABELS[code]
    base = code.split("-")[0]
    if base in _LANGUAGE_LABELS:
        return f"{_LANGUAGE_LABELS[base]} ({code})"
    return code.upper()


def _extract_subtitles(info: dict[str, Any]) -> List[SubtitleTrack]:
    manual_subs: dict[str, Any] = info.get("subtitles") or {}
    auto_subs: dict[str, Any] = info.get("automatic_captions") or {}

    seen_languages: set[str] = set()
    tracks: List[SubtitleTrack] = []

    for lang, entries in manual_subs.items():
        if not isinstance(entries, list) or not entries:
            continue
        url = None
        for entry in entries:
            if isinstance(entry, dict) and entry.get("ext") == "vtt" and entry.get("url"):
                url = entry["url"]
                break
        if url is None:
            for entry in entries:
                if isinstance(entry, dict) and entry.get("url"):
                    url = entry["url"]
                    break
        if url:
            seen_languages.add(lang)
            tracks.append(SubtitleTrack(
                language=lang,
                label=_language_label(lang),
                url=url,
                isAutoGenerated=False,
            ))

    for lang, entries in auto_subs.items():
        if lang in seen_languages:
            continue
        if not isinstance(entries, list) or not entries:
            continue
        url = None
        for entry in entries:
            if isinstance(entry, dict) and entry.get("ext") == "vtt" and entry.get("url"):
                url = entry["url"]
                break
        if url is None:
            for entry in entries:
                if isinstance(entry, dict) and entry.get("url"):
                    url = entry["url"]
                    break
        if url:
            tracks.append(SubtitleTrack(
                language=lang,
                label=_language_label(lang),
                url=url,
                isAutoGenerated=True,
            ))

    return tracks


def build_playback_bundle_from_streams(
    streams: List[StreamInfo],
    title: Optional[str] = None,
    duration_text: Optional[str] = None,
    subtitles: Optional[List[SubtitleTrack]] = None,
) -> PlaybackBundle:
    return PlaybackBundle(
        title=title,
        duration_text=duration_text,
        streams=streams,
        preferred_manifest_stream=_best_manifest_stream(streams),
        preferred_muxed_stream=_best_muxed_stream(streams),
        preferred_video_stream=_best_video_stream(streams),
        preferred_audio_stream=_best_audio_stream(streams),
        subtitles=subtitles or [],
    )


def _extract_playback(video_id: str, opts: dict[str, Any]) -> PlaybackBundle:
    _ensure_ytdlp_js_challenge_polyfill()
    extract_opts = dict(opts)
    extract_opts["writesubtitles"] = True
    extract_opts["writeautomaticsub"] = True
    extract_opts["subtitlesformat"] = "vtt"
    with YoutubeDL(extract_opts) as ydl:
        info = ydl.extract_info(
            f"https://www.youtube.com/watch?v={video_id}", download=False
        )

    formats = info.get("formats", []) if isinstance(info, dict) else []
    streams = _build_streams(formats if isinstance(formats, list) else [])
    subtitles = _extract_subtitles(info) if isinstance(info, dict) else []
    return build_playback_bundle_from_streams(
        streams,
        title=info.get("title") if isinstance(info, dict) else None,
        duration_text=_format_duration(info.get("duration") if isinstance(info, dict) else None),
        subtitles=subtitles,
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
    try:
        with _probe_client(stream, auth_options) as client:
            if _is_manifest_url(stream.url):
                response = client.get(stream.url)
                return 200 <= response.status_code < 300 and "#EXTM3U" in response.text

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


def _bundle_has_video_streams(bundle: PlaybackBundle) -> bool:
    return any(stream.hasVideo for stream in bundle.streams)


def _validated_authenticated_bundle(
    bundle: PlaybackBundle,
    auth_options: dict[str, Any],
) -> Optional[PlaybackBundle]:
    manifest_candidates = sorted(
        [
            stream
            for stream in bundle.streams
            if stream.streamKind == "manifest" and stream.hasVideo
        ],
        key=_manifest_stream_score,
        reverse=True,
    )

    reachable_manifest_stream = None
    for candidate in manifest_candidates[:3]:
        if _stream_is_reachable(candidate, auth_options):
            reachable_manifest_stream = candidate
            break

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

    preferred_video_stream = _best_video_stream(bundle.streams)
    preferred_audio_stream = _best_audio_stream(bundle.streams)

    if reachable_manifest_stream is not None:
        return replace(
            bundle,
            preferred_manifest_stream=reachable_manifest_stream,
            preferred_muxed_stream=reachable_muxed_stream,
            preferred_video_stream=preferred_video_stream,
            preferred_audio_stream=preferred_audio_stream,
        )

    if (
        preferred_video_stream is not None
        and preferred_audio_stream is not None
        and (
            reachable_muxed_stream is None
            or (preferred_video_stream.height or 0)
            > (reachable_muxed_stream.height or 0)
        )
    ):
        return replace(
            bundle,
            preferred_manifest_stream=None,
            preferred_muxed_stream=reachable_muxed_stream,
            preferred_video_stream=preferred_video_stream,
            preferred_audio_stream=preferred_audio_stream,
        )

    if reachable_muxed_stream is not None:
        return replace(
            bundle,
            preferred_manifest_stream=None,
            preferred_muxed_stream=reachable_muxed_stream,
            preferred_video_stream=None,
            preferred_audio_stream=None,
        )

    return None


def extract_playback(video_id: str, auth_options: Optional[dict[str, Any]] = None) -> PlaybackBundle:
    public_client_options = [
        {
            "quiet": True,
            "no_warnings": True,
            "noplaylist": True,
            "extract_flat": False,
            "skip_download": True,
            "js_runtimes": {"node": {}},
            "extractor_args": {"youtube": {"player_client": ["tv_embedded"]}},
        },
        {
            "quiet": True,
            "no_warnings": True,
            "noplaylist": True,
            "extract_flat": False,
            "skip_download": True,
            "js_runtimes": {"node": {}},
            "extractor_args": {"youtube": {"player_client": ["android"]}},
        },
    ]

    public_bundle: Optional[PlaybackBundle] = None
    public_error: Optional[Exception] = None
    for public_opts in public_client_options:
        try:
            candidate_bundle = _extract_playback(video_id, public_opts)
            if public_bundle is None:
                public_bundle = candidate_bundle
            if _bundle_has_video_streams(candidate_bundle):
                public_bundle = candidate_bundle
                break
        except Exception as exc:
            public_error = exc

    if public_bundle is not None and _bundle_has_video_streams(public_bundle):
        return public_bundle

    public_opts = {
        "quiet": True,
        "no_warnings": True,
        "noplaylist": True,
        "extract_flat": False,
        "skip_download": True,
        "js_runtimes": {"node": {}},
        "extractor_args": {"youtube": {"player_client": ["tv_embedded"]}},
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
                return validated_bundle
        except Exception:
            pass

    if public_bundle is not None:
        return public_bundle

    if public_error is not None:
        raise public_error

    return _extract_playback(video_id, public_opts)
