from __future__ import annotations

from typing import Any, Dict, Iterable, List, Optional

from .models import StreamInfo, Thumbnail, VideoItem


def iter_nodes(obj: Any) -> Iterable[Any]:
    if isinstance(obj, dict):
        yield obj
        for value in obj.values():
            yield from iter_nodes(value)
    elif isinstance(obj, list):
        for value in obj:
            yield from iter_nodes(value)


def get_text(obj: Any) -> Optional[str]:
    if not isinstance(obj, dict):
        return None
    if "simpleText" in obj and isinstance(obj["simpleText"], str):
        return obj["simpleText"]
    runs = obj.get("runs")
    if isinstance(runs, list):
        parts = []
        for run in runs:
            text = run.get("text") if isinstance(run, dict) else None
            if text:
                parts.append(text)
        if parts:
            return "".join(parts)
    return None


def build_thumbnails(thumbnail_obj: Any) -> List[Thumbnail]:
    if not isinstance(thumbnail_obj, dict):
        return []
    items = thumbnail_obj.get("thumbnails")
    if not isinstance(items, list):
        return []
    thumbnails: List[Thumbnail] = []
    for item in items:
        if not isinstance(item, dict):
            continue
        url = item.get("url")
        if not url:
            continue
        thumbnails.append(
            Thumbnail(url=url, width=item.get("width"), height=item.get("height"))
        )
    return thumbnails


def extract_video_items(data: Any, limit: int = 120) -> List[VideoItem]:
    items: List[VideoItem] = []
    seen: set[str] = set()
    for node in iter_nodes(data):
        if not isinstance(node, dict):
            continue
        renderer = None
        if "videoRenderer" in node:
            renderer = node.get("videoRenderer")
        elif "gridVideoRenderer" in node:
            renderer = node.get("gridVideoRenderer")
        if not isinstance(renderer, dict):
            continue
        video_id = renderer.get("videoId")
        if not video_id or video_id in seen:
            continue
        seen.add(video_id)

        title = get_text(renderer.get("title")) or "Untitled"
        channel = (
            get_text(renderer.get("longBylineText"))
            or get_text(renderer.get("shortBylineText"))
            or get_text(renderer.get("ownerText"))
            or get_text(renderer.get("bylineText"))
        )
        view_count = get_text(renderer.get("viewCountText")) or get_text(
            renderer.get("shortViewCountText")
        )
        published = get_text(renderer.get("publishedTimeText"))
        thumbnails = build_thumbnails(renderer.get("thumbnail"))

        items.append(
            VideoItem(
                id=video_id,
                title=title,
                channel=channel,
                viewCountText=view_count,
                publishedTimeText=published,
                thumbnails=thumbnails,
            )
        )
        if len(items) >= limit:
            break
    return items


def extract_browse_ids_from_guide(data: Any, limit: int = 6) -> List[str]:
    browse_ids: List[str] = []
    for node in iter_nodes(data):
        if not isinstance(node, dict):
            continue
        browse = node.get("browseEndpoint")
        if not isinstance(browse, dict):
            continue
        browse_id = browse.get("browseId")
        if not browse_id or browse_id in browse_ids:
            continue
        if browse_id.startswith("UC"):
            browse_ids.append(browse_id)
        if len(browse_ids) >= limit:
            break
    return browse_ids


def extract_continuation_token(data: Any) -> Optional[str]:
    for node in iter_nodes(data):
        if not isinstance(node, dict):
            continue
        if "continuationCommand" in node:
            command = node.get("continuationCommand")
            if isinstance(command, dict):
                token = command.get("token")
                if token:
                    return token
        if "continuationEndpoint" in node:
            endpoint = node.get("continuationEndpoint")
            if isinstance(endpoint, dict):
                command = endpoint.get("continuationCommand")
                if isinstance(command, dict):
                    token = command.get("token")
                    if token:
                        return token
        if "nextContinuationData" in node:
            data_obj = node.get("nextContinuationData")
            if isinstance(data_obj, dict):
                token = data_obj.get("continuation")
                if token:
                    return token
    return None


def parse_streams(player_response: Dict[str, Any]) -> List[StreamInfo]:
    streaming = player_response.get("streamingData")
    if not isinstance(streaming, dict):
        return []

    results: List[StreamInfo] = []
    for key in ("formats", "adaptiveFormats"):
        entries = streaming.get(key)
        if not isinstance(entries, list):
            continue
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            url = entry.get("url")
            if not url:
                # signatureCipher streams require additional deciphering, so skip for now
                continue
            mime_type = entry.get("mimeType")
            has_audio = bool(
                entry.get("audioQuality")
                or entry.get("audioChannels")
                or (isinstance(mime_type, str) and "audio/" in mime_type)
            )
            has_video = bool(
                entry.get("qualityLabel")
                or (isinstance(mime_type, str) and "video/" in mime_type)
            )
            results.append(
                StreamInfo(
                    url=url,
                    mimeType=mime_type,
                    qualityLabel=entry.get("qualityLabel"),
                    bitrate=entry.get("bitrate"),
                    width=entry.get("width"),
                    height=entry.get("height"),
                    fps=entry.get("fps"),
                    hasAudio=has_audio,
                    hasVideo=has_video,
                    isAdaptive=key == "adaptiveFormats",
                )
            )
    return results


def pick_best_stream(streams: List[StreamInfo]) -> Optional[StreamInfo]:
    if not streams:
        return None

    def score(stream: StreamInfo) -> tuple:
        height = stream.height or 0
        bitrate = stream.bitrate or 0
        has_audio = 1 if stream.hasAudio else 0
        has_video = 1 if stream.hasVideo else 0
        return (has_audio, has_video, height, bitrate)

    with_audio = [s for s in streams if s.hasAudio and s.hasVideo]
    candidates = with_audio or [s for s in streams if s.hasVideo] or streams
    return max(candidates, key=score)
