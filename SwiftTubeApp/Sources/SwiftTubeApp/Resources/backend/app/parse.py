from __future__ import annotations

import math
import re
from typing import Any, Dict, Iterable, List, Optional

from .models import (
    CommentItem,
    InnerTubeCommand,
    PlaylistOption,
    RatingState,
    StoryboardSpec,
    StreamInfo,
    SubscriptionState,
    Thumbnail,
    VideoItem,
)


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


def get_content_text(obj: Any) -> Optional[str]:
    if not isinstance(obj, dict):
        return None
    if isinstance(obj.get("content"), str):
        return obj["content"]
    return get_text(obj)


def _first_dict(items: Any) -> Optional[dict]:
    if isinstance(items, list):
        for item in items:
            if isinstance(item, dict):
                return item
    return None


def _command_metadata_api_path(endpoint: Any) -> Optional[str]:
    if not isinstance(endpoint, dict):
        return None
    metadata = endpoint.get("commandMetadata", {}).get("webCommandMetadata", {})
    api_path = metadata.get("apiUrl")
    if isinstance(api_path, str) and api_path:
        return api_path
    return None


def _normalize_api_path(api_path: Optional[str]) -> Optional[str]:
    if not isinstance(api_path, str) or not api_path:
        return None
    return api_path.removeprefix("/youtubei/v1/")


def _build_command(api_path: Optional[str], payload: dict) -> Optional[InnerTubeCommand]:
    normalized_path = _normalize_api_path(api_path)
    if normalized_path is None:
        return None
    return InnerTubeCommand(apiPath=normalized_path, payload=payload)


def _normalize_subscribe_endpoint(endpoint: Any, *, unsubscribe: bool) -> Optional[InnerTubeCommand]:
    if not isinstance(endpoint, dict):
        return None
    key = "unsubscribeEndpoint" if unsubscribe else "subscribeEndpoint"
    raw = endpoint.get(key)
    if not isinstance(raw, dict):
        return None

    payload: dict[str, Any] = {}
    for field in ("channelIds", "siloName", "params", "botguardResponse"):
        value = raw.get(field)
        if value is not None:
            payload[field] = value

    if raw.get("feature") is not None:
        payload["clientFeature"] = raw["feature"]

    return _build_command(
        _command_metadata_api_path(endpoint)
        or ("subscription/unsubscribe" if unsubscribe else "subscription/subscribe"),
        payload,
    )


def _normalize_like_endpoint(endpoint: Any) -> Optional[InnerTubeCommand]:
    if not isinstance(endpoint, dict):
        return None
    raw = endpoint.get("likeEndpoint")
    if not isinstance(raw, dict):
        return None

    payload: dict[str, Any] = {}
    if raw.get("target") is not None:
        payload["target"] = raw["target"]

    status = raw.get("status")
    params_field = {
        "LIKE": "likeParams",
        "DISLIKE": "dislikeParams",
        "INDIFFERENT": "removeLikeParams",
    }.get(status)
    if params_field and raw.get(params_field) is not None:
        payload["params"] = raw[params_field]

    return _build_command(
        _command_metadata_api_path(endpoint)
        or {
            "LIKE": "like/like",
            "DISLIKE": "like/dislike",
            "INDIFFERENT": "like/removelike",
        }.get(status),
        payload,
    )


def _normalize_add_to_playlist_endpoint(endpoint: Any) -> Optional[InnerTubeCommand]:
    if not isinstance(endpoint, dict):
        return None
    raw = endpoint.get("addToPlaylistServiceEndpoint")
    if not isinstance(raw, dict):
        return None

    video_ids = raw.get("videoIds")
    if not isinstance(video_ids, list):
        video_id = raw.get("videoId")
        video_ids = [video_id] if isinstance(video_id, str) and video_id else []

    payload: dict[str, Any] = {"videoIds": video_ids}
    for field in ("playlistId", "params"):
        value = raw.get(field)
        if value is not None:
            payload[field] = value
    payload["excludeWatchLater"] = bool(raw.get("excludeWatchLater", False))

    return _build_command(
        _command_metadata_api_path(endpoint) or "playlist/get_add_to_playlist",
        payload,
    )


def _normalize_playlist_edit_endpoint(endpoint: Any) -> Optional[InnerTubeCommand]:
    if not isinstance(endpoint, dict):
        return None
    raw = endpoint.get("playlistEditEndpoint")
    if not isinstance(raw, dict):
        return None

    payload: dict[str, Any] = {}
    for field in ("playlistId", "actions", "params"):
        value = raw.get(field)
        if value is not None:
            payload[field] = value

    return _build_command(
        _command_metadata_api_path(endpoint) or "browse/edit_playlist",
        payload,
    )


def _find_innertube_command(commands: Any, endpoint_key: str) -> Optional[dict]:
    if not isinstance(commands, list):
        return None
    for command in commands:
        innertube_command = (
            command.get("innertubeCommand") if isinstance(command, dict) else None
        )
        if isinstance(innertube_command, dict) and endpoint_key in innertube_command:
            return innertube_command
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


def build_source_thumbnails(source_obj: Any) -> List[Thumbnail]:
    if not isinstance(source_obj, dict):
        return []

    sources = source_obj.get("sources")
    if not isinstance(sources, list):
        return []

    thumbnails: List[Thumbnail] = []
    for source in sources:
        if not isinstance(source, dict):
            continue
        url = source.get("url")
        if not url:
            continue
        thumbnails.append(
            Thumbnail(url=url, width=source.get("width"), height=source.get("height"))
        )
    return thumbnails


def first_thumbnail_url(thumbnails: List[Thumbnail]) -> Optional[str]:
    if not thumbnails:
        return None
    return thumbnails[0].url


def row_text_parts(row: Any) -> List[str]:
    if not isinstance(row, dict):
        return []
    parts = row.get("metadataParts")
    if not isinstance(parts, list):
        return []

    results: List[str] = []
    for part in parts:
        if not isinstance(part, dict):
            continue
        text = get_content_text(part.get("text")) or get_text(part.get("text"))
        if text:
            results.append(text)
    return results


def extract_lockup_duration(lockup: Any) -> Optional[str]:
    overlays = (
        lockup.get("contentImage", {})
        .get("thumbnailViewModel", {})
        .get("overlays", [])
    )
    if not isinstance(overlays, list):
        return None

    for overlay in overlays:
        if not isinstance(overlay, dict):
            continue
        badges = (
            overlay.get("thumbnailBottomOverlayViewModel", {})
            .get("badges", [])
        )
        if not isinstance(badges, list):
            continue
        for badge in badges:
            if not isinstance(badge, dict):
                continue
            text = (
                badge.get("thumbnailBadgeViewModel", {}).get("text")
            )
            if isinstance(text, str) and text:
                return text
    return None


def parse_lockup_video_item(lockup: Any) -> Optional[VideoItem]:
    if not isinstance(lockup, dict):
        return None
    if lockup.get("contentType") != "LOCKUP_CONTENT_TYPE_VIDEO":
        return None

    video_id = (
        lockup.get("contentId")
        or lockup.get("rendererContext", {})
        .get("commandContext", {})
        .get("onTap", {})
        .get("innertubeCommand", {})
        .get("watchEndpoint", {})
        .get("videoId")
    )
    if not isinstance(video_id, str) or not video_id:
        return None

    metadata = lockup.get("metadata", {}).get("lockupMetadataViewModel", {})
    title = (
        metadata.get("title", {}).get("content")
        or "Untitled"
    )

    rows = (
        metadata.get("metadata", {})
        .get("contentMetadataViewModel", {})
        .get("metadataRows", [])
    )
    if not isinstance(rows, list):
        rows = []

    channel = None
    view_count = None
    published = None

    if rows:
        channel_parts = row_text_parts(rows[0])
        if channel_parts:
            channel = channel_parts[0]

    if len(rows) > 1:
        stats_parts = row_text_parts(rows[1])
        if stats_parts:
            view_count = stats_parts[0]
        if len(stats_parts) > 1:
            published = stats_parts[1]

    thumbnails = build_source_thumbnails(
        lockup.get("contentImage", {})
        .get("thumbnailViewModel", {})
        .get("image", {})
    )

    return VideoItem(
        id=video_id,
        title=title,
        channel=channel,
        viewCountText=view_count,
        publishedTimeText=published,
        durationText=extract_lockup_duration(lockup),
        thumbnails=thumbnails,
    )


def extract_video_items(data: Any, limit: int = 120) -> List[VideoItem]:
    items: List[VideoItem] = []
    seen: set[str] = set()
    for node in iter_nodes(data):
        if not isinstance(node, dict):
            continue
        if "lockupViewModel" in node:
            item = parse_lockup_video_item(node.get("lockupViewModel"))
            if item is None or item.id in seen:
                continue
            seen.add(item.id)
            items.append(item)
            if len(items) >= limit:
                break
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
        duration = get_text(renderer.get("lengthText"))
        thumbnails = build_thumbnails(renderer.get("thumbnail"))

        items.append(
            VideoItem(
                id=video_id,
                title=title,
                channel=channel,
                viewCountText=view_count,
                publishedTimeText=published,
                durationText=duration,
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


def _parse_mime_type(mime_type: Optional[str]) -> tuple[Optional[str], Optional[str], Optional[str]]:
    if not isinstance(mime_type, str) or not mime_type:
        return None, None, None

    base, _, remainder = mime_type.partition(";")
    container = base.split("/", 1)[1].strip().lower() if "/" in base else None
    codecs_match = re.search(r'codecs="([^"]+)"', remainder)
    codecs = [
        codec.strip()
        for codec in (codecs_match.group(1).split(",") if codecs_match else [])
        if codec.strip()
    ]

    video_codec = next((codec for codec in codecs if not codec.startswith(("mp4a", "opus", "vorbis", "aac"))), None)
    audio_codec = next((codec for codec in codecs if codec.startswith(("mp4a", "opus", "vorbis", "aac"))), None)
    return container, video_codec, audio_codec


def _is_manifest_url(url: str) -> bool:
    lowered = url.lower()
    return (
        "manifest.googlevideo.com" in lowered
        or "/api/manifest/" in lowered
        or lowered.endswith(".m3u8")
        or "/playlist/index.m3u8" in lowered
    )


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
            container, video_codec, audio_codec = _parse_mime_type(mime_type)
            has_audio = bool(
                audio_codec
                or entry.get("audioQuality")
                or entry.get("audioChannels")
                or (isinstance(mime_type, str) and "audio/" in mime_type)
            )
            has_video = bool(
                video_codec
                or entry.get("qualityLabel")
                or (isinstance(mime_type, str) and "video/" in mime_type)
            )
            results.append(
                StreamInfo(
                    url=url,
                    formatId=str(entry.get("itag")) if entry.get("itag") else None,
                    mimeType=mime_type,
                    qualityLabel=entry.get("qualityLabel"),
                    bitrate=entry.get("bitrate"),
                    width=entry.get("width"),
                    height=entry.get("height"),
                    fps=entry.get("fps"),
                    audioChannels=entry.get("audioChannels"),
                    audioCodec=audio_codec or entry.get("audioQuality"),
                    videoCodec=video_codec,
                    container=container or entry.get("container"),
                    hasAudio=has_audio,
                    hasVideo=has_video,
                    isAdaptive=key == "adaptiveFormats",
                    streamKind=_stream_kind(url, has_audio, has_video),
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


def extract_related_videos(
    data: Any, current_video_id: Optional[str] = None, limit: int = 24
) -> List[VideoItem]:
    items: List[VideoItem] = []
    seen: set[str] = set()

    for node in iter_nodes(data):
        if not isinstance(node, dict) or "lockupViewModel" not in node:
            continue

        lockup = node.get("lockupViewModel")
        if not isinstance(lockup, dict):
            continue
        if lockup.get("contentType") != "LOCKUP_CONTENT_TYPE_VIDEO":
            continue

        video_id = lockup.get("contentId")
        if not video_id or video_id == current_video_id or video_id in seen:
            continue

        title = (
            get_content_text(lockup.get("title"))
            or get_content_text(
                lockup.get("metadata", {})
                .get("lockupMetadataViewModel", {})
                .get("title")
            )
            or "Untitled"
        )
        thumbnails = build_source_thumbnails(
            lockup.get("contentImage", {})
            .get("thumbnailViewModel", {})
            .get("image", {})
        )

        metadata_rows = (
            lockup.get("metadata", {})
            .get("lockupMetadataViewModel", {})
            .get("metadata", {})
            .get("contentMetadataViewModel", {})
            .get("metadataRows", [])
        )

        channel = None
        view_count = None
        published = None

        if isinstance(metadata_rows, list):
            if metadata_rows:
                first_row = row_text_parts(metadata_rows[0])
                if first_row:
                    channel = first_row[0]
            if len(metadata_rows) > 1:
                second_row = row_text_parts(metadata_rows[1])
                if second_row:
                    view_count = second_row[0]
                if len(second_row) > 1:
                    published = second_row[1]

        duration = None
        overlays = (
            lockup.get("contentImage", {})
            .get("thumbnailViewModel", {})
            .get("overlays", [])
        )
        if isinstance(overlays, list):
            for overlay in overlays:
                badges = (
                    overlay.get("thumbnailBottomOverlayViewModel", {}).get("badges", [])
                    if isinstance(overlay, dict)
                    else []
                )
                if not isinstance(badges, list):
                    continue
                for badge in badges:
                    text = (
                        badge.get("thumbnailBadgeViewModel", {}).get("text")
                        if isinstance(badge, dict)
                        else None
                    )
                    if isinstance(text, str) and ":" in text:
                        duration = text
                        break
                if duration:
                    break

        seen.add(video_id)
        items.append(
            VideoItem(
                id=video_id,
                title=title,
                channel=channel,
                viewCountText=view_count,
                publishedTimeText=published,
                durationText=duration,
                thumbnails=thumbnails,
            )
        )

        if len(items) >= limit:
            return items

    fallback_items = extract_video_items(data, limit=limit + 8)
    for item in fallback_items:
        if item.id == current_video_id or item.id in seen:
            continue
        seen.add(item.id)
        items.append(item)
        if len(items) >= limit:
            break

    return items


def extract_watch_metadata(data: Any) -> Dict[str, Optional[str]]:
    metadata: Dict[str, Optional[str]] = {
        "title": None,
        "channel": None,
        "channelId": None,
        "channelAvatarUrl": None,
        "subscriberCountText": None,
        "viewCountText": None,
        "publishedTimeText": None,
        "publishedDateText": None,
        "likeCountText": None,
        "description": None,
        "commentCountText": None,
    }

    for node in iter_nodes(data):
        if not isinstance(node, dict):
            continue

        primary = node.get("videoPrimaryInfoRenderer")
        if isinstance(primary, dict):
            metadata["title"] = metadata["title"] or get_text(primary.get("title"))
            metadata["publishedTimeText"] = metadata["publishedTimeText"] or get_text(
                primary.get("relativeDateText")
            )
            metadata["publishedDateText"] = metadata["publishedDateText"] or get_text(
                primary.get("dateText")
            )

            view_count = (
                primary.get("viewCount", {})
                .get("videoViewCountRenderer", {})
                .get("viewCount")
            )
            metadata["viewCountText"] = metadata["viewCountText"] or get_text(
                view_count
            )

        secondary = node.get("videoSecondaryInfoRenderer")
        if isinstance(secondary, dict):
            owner = secondary.get("owner", {}).get("videoOwnerRenderer", {})
            if isinstance(owner, dict):
                metadata["channel"] = metadata["channel"] or get_text(owner.get("title"))
                metadata["subscriberCountText"] = metadata[
                    "subscriberCountText"
                ] or get_text(owner.get("subscriberCountText"))
                metadata["channelId"] = metadata["channelId"] or (
                    owner.get("navigationEndpoint", {})
                    .get("browseEndpoint", {})
                    .get("browseId")
                )
                if metadata["channelAvatarUrl"] is None:
                    avatar_thumbnails = build_thumbnails(owner.get("thumbnail"))
                    metadata["channelAvatarUrl"] = first_thumbnail_url(
                        avatar_thumbnails
                    )

        description_header = node.get("videoDescriptionHeaderRenderer")
        if isinstance(description_header, dict):
            metadata["channel"] = metadata["channel"] or get_text(
                description_header.get("channel")
            )
            metadata["publishedDateText"] = metadata["publishedDateText"] or get_text(
                description_header.get("publishDate")
            )
            metadata["viewCountText"] = metadata["viewCountText"] or get_text(
                description_header.get("views")
            )

            channel_endpoint = description_header.get(
                "channelNavigationEndpoint", {}
            ).get("browseEndpoint", {})
            metadata["channelId"] = metadata["channelId"] or channel_endpoint.get(
                "browseId"
            )

            header_thumbnails = build_thumbnails(
                description_header.get("channelThumbnail")
            )
            metadata["channelAvatarUrl"] = metadata["channelAvatarUrl"] or (
                first_thumbnail_url(header_thumbnails)
            )

            factoids = description_header.get("factoid")
            if isinstance(factoids, list):
                for fact in factoids:
                    if not isinstance(fact, dict):
                        continue
                    factoid = fact.get("factoidRenderer")
                    if not isinstance(factoid, dict):
                        factoid = fact.get("viewCountFactoidRenderer", {}).get(
                            "factoid", {}
                        ).get("factoidRenderer")
                    if not isinstance(factoid, dict):
                        continue
                    label = get_text(factoid.get("label")) or ""
                    value = get_text(factoid.get("value"))
                    if not value:
                        continue
                    if label == "Likes":
                        metadata["likeCountText"] = metadata["likeCountText"] or value
                    elif label == "Views":
                        metadata["viewCountText"] = metadata["viewCountText"] or value

        description_body = node.get("expandableVideoDescriptionBodyRenderer")
        if isinstance(description_body, dict):
            attributed = description_body.get("attributedDescriptionBodyText", {})
            metadata["description"] = metadata["description"] or get_content_text(
                attributed
            )

        panel = node.get("engagementPanelSectionListRenderer")
        if isinstance(panel, dict) and panel.get("targetId") == "engagement-panel-comments-section":
            contextual = (
                panel.get("header", {})
                .get("engagementPanelTitleHeaderRenderer", {})
                .get("contextualInfo")
            )
            metadata["commentCountText"] = metadata["commentCountText"] or get_text(
                contextual
            )

    return metadata


def extract_subscription_state(
    data: Any, metadata: Optional[Dict[str, Optional[str]]] = None
) -> Optional[SubscriptionState]:
    metadata = metadata or {}

    for node in iter_nodes(data):
        if not isinstance(node, dict):
            continue

        subscribe_button = node.get("subscribeButton")
        if not isinstance(subscribe_button, dict):
            continue

        renderer = subscribe_button.get("subscribeButtonRenderer")
        if not isinstance(renderer, dict):
            continue

        channel_id = renderer.get("channelId")
        if not isinstance(channel_id, str) or not channel_id:
            continue

        button_text = get_text(renderer.get("buttonText"))
        return SubscriptionState(
            channelId=channel_id,
            buttonText=button_text,
            subscribed=bool(renderer.get("subscribed")),
            enabled=bool(renderer.get("enabled")),
            subscriberCountText=metadata.get("subscriberCountText"),
        )

    return None


def extract_rating_state(data: Any) -> Optional[RatingState]:
    for node in iter_nodes(data):
        if not isinstance(node, dict):
            continue

        view_model = node.get("segmentedLikeDislikeButtonViewModel")
        if not isinstance(view_model, dict):
            continue

        like_vm = (
            view_model.get("likeButtonViewModel", {})
            .get("likeButtonViewModel", {})
        )
        dislike_vm = (
            view_model.get("dislikeButtonViewModel", {})
            .get("dislikeButtonViewModel", {})
        )
        if not isinstance(like_vm, dict) or not isinstance(dislike_vm, dict):
            continue

        like_toggle = (
            like_vm.get("toggleButtonViewModel", {})
            .get("toggleButtonViewModel", {})
        )
        dislike_toggle = (
            dislike_vm.get("toggleButtonViewModel", {})
            .get("toggleButtonViewModel", {})
        )

        status = (
            like_vm.get("likeStatusEntity", {}).get("likeStatus")
            or "INDIFFERENT"
        )
        like_count = (
            like_toggle.get("defaultButtonViewModel", {})
            .get("buttonViewModel", {})
            .get("title")
        )
        if not isinstance(like_count, str):
            like_count = None

        if status not in {"LIKE", "DISLIKE", "INDIFFERENT"}:
            status = "INDIFFERENT"

        if isinstance(dislike_toggle, dict):
            return RatingState(status=status, likeCountText=like_count)

    return None


def extract_watch_page_save_command(data: Any) -> Optional[InnerTubeCommand]:
    for node in iter_nodes(data):
        if not isinstance(node, dict):
            continue

        flexible_items = (
            node.get("videoActions", {})
            .get("menuRenderer", {})
            .get("flexibleItems", [])
        )
        if not isinstance(flexible_items, list):
            continue

        for item in flexible_items:
            renderer = item.get("menuFlexibleItemRenderer", {}) if isinstance(item, dict) else {}
            service_endpoint = (
                renderer.get("menuItem", {})
                .get("menuServiceItemRenderer", {})
                .get("serviceEndpoint")
            )
            normalized = _normalize_add_to_playlist_endpoint(service_endpoint)
            if normalized is not None:
                return normalized

            on_tap = (
                renderer.get("topLevelButton", {})
                .get("buttonViewModel", {})
                .get("onTap", {})
                .get("serialCommand", {})
                .get("commands", [])
            )
            normalized = _normalize_add_to_playlist_endpoint(
                _find_innertube_command(on_tap, "addToPlaylistServiceEndpoint")
            )
            if normalized is not None:
                return normalized

    return None


def extract_playlist_options(data: Any) -> List[PlaylistOption]:
    options: List[PlaylistOption] = []
    seen: set[str] = set()

    for node in iter_nodes(data):
        if not isinstance(node, dict):
            continue
        renderer = node.get("playlistAddToOptionRenderer")
        if not isinstance(renderer, dict):
            continue

        playlist_id = renderer.get("playlistId")
        if not isinstance(playlist_id, str) or not playlist_id or playlist_id in seen:
            continue

        title = get_text(renderer.get("title"))
        if not title:
            continue

        contains_selected_videos = renderer.get("containsSelectedVideos")
        if not isinstance(contains_selected_videos, str) or not contains_selected_videos:
            contains_selected_videos = "NONE"

        seen.add(playlist_id)
        options.append(
            PlaylistOption(
                playlistId=playlist_id,
                title=title,
                privacy=renderer.get("privacy"),
                containsSelectedVideos=contains_selected_videos,
                saved=contains_selected_videos == "ALL",
            )
        )

    return options


def extract_playlist_option_commands(data: Any) -> Dict[str, Dict[str, Optional[InnerTubeCommand]]]:
    commands: Dict[str, Dict[str, Optional[InnerTubeCommand]]] = {}

    for node in iter_nodes(data):
        if not isinstance(node, dict):
            continue
        renderer = node.get("playlistAddToOptionRenderer")
        if not isinstance(renderer, dict):
            continue

        playlist_id = renderer.get("playlistId")
        if not isinstance(playlist_id, str) or not playlist_id:
            continue

        commands[playlist_id] = {
            "add": _normalize_playlist_edit_endpoint(
                renderer.get("addToPlaylistServiceEndpoint")
            ),
            "remove": _normalize_playlist_edit_endpoint(
                renderer.get("removeFromPlaylistServiceEndpoint")
            ),
        }

    return commands


def extract_subscription_commands(data: Any) -> Dict[str, Optional[InnerTubeCommand]]:
    result: Dict[str, Optional[InnerTubeCommand]] = {
        "subscribe": None,
        "unsubscribe": None,
    }

    for node in iter_nodes(data):
        if not isinstance(node, dict):
            continue

        subscribe_button = node.get("subscribeButton")
        if not isinstance(subscribe_button, dict):
            continue

        renderer = subscribe_button.get("subscribeButtonRenderer")
        if not isinstance(renderer, dict):
            continue

        result["subscribe"] = _normalize_subscribe_endpoint(
            _first_dict(renderer.get("onSubscribeEndpoints")),
            unsubscribe=False,
        )

        unsubscribe_endpoint = _first_dict(renderer.get("onUnsubscribeEndpoints"))
        unsubscribe_command = _normalize_subscribe_endpoint(
            unsubscribe_endpoint,
            unsubscribe=True,
        )
        if unsubscribe_command is None and isinstance(unsubscribe_endpoint, dict):
            signal_action = _first_dict(
                unsubscribe_endpoint.get("signalServiceEndpoint", {}).get("actions", [])
            )
            confirm_button_endpoint = (
                signal_action.get("openPopupAction", {})
                .get("popup", {})
                .get("confirmDialogRenderer", {})
                .get("confirmButton", {})
                .get("buttonRenderer", {})
                .get("serviceEndpoint")
            ) if isinstance(signal_action, dict) else None
            unsubscribe_command = _normalize_subscribe_endpoint(
                confirm_button_endpoint,
                unsubscribe=True,
            )

        if unsubscribe_command is None:
            notification_button = renderer.get("notificationPreferenceButton", {})
            command_executor = (
                notification_button.get("subscriptionNotificationToggleButtonRenderer", {})
                .get("command", {})
                .get("commandExecutorCommand", {})
                .get("commands", [])
            )
            signal_action = _first_dict(
                (
                    _find_innertube_command(command_executor, "signalServiceEndpoint")
                    or {}
                ).get("signalServiceEndpoint", {}).get("actions", [])
            )
            confirm_button_endpoint = (
                signal_action.get("openPopupAction", {})
                .get("popup", {})
                .get("confirmDialogRenderer", {})
                .get("confirmButton", {})
                .get("buttonRenderer", {})
                .get("serviceEndpoint")
            ) if isinstance(signal_action, dict) else None
            unsubscribe_command = _normalize_subscribe_endpoint(
                confirm_button_endpoint,
                unsubscribe=True,
            )

        result["unsubscribe"] = unsubscribe_command
        return result

    return result


def extract_rating_commands(data: Any) -> Dict[str, Optional[InnerTubeCommand]]:
    result: Dict[str, Optional[InnerTubeCommand]] = {
        "like": None,
        "dislike": None,
        "removeLike": None,
        "removeDislike": None,
    }

    for node in iter_nodes(data):
        if not isinstance(node, dict):
            continue

        view_model = node.get("segmentedLikeDislikeButtonViewModel")
        if not isinstance(view_model, dict):
            continue

        like_toggle = (
            view_model.get("likeButtonViewModel", {})
            .get("likeButtonViewModel", {})
            .get("toggleButtonViewModel", {})
            .get("toggleButtonViewModel", {})
        )
        dislike_toggle = (
            view_model.get("dislikeButtonViewModel", {})
            .get("dislikeButtonViewModel", {})
            .get("toggleButtonViewModel", {})
            .get("toggleButtonViewModel", {})
        )

        like_default_commands = (
            like_toggle.get("defaultButtonViewModel", {})
            .get("buttonViewModel", {})
            .get("onTap", {})
            .get("serialCommand", {})
            .get("commands", [])
        )
        like_toggled_commands = (
            like_toggle.get("toggledButtonViewModel", {})
            .get("buttonViewModel", {})
            .get("onTap", {})
            .get("serialCommand", {})
            .get("commands", [])
        )
        dislike_default_commands = (
            dislike_toggle.get("defaultButtonViewModel", {})
            .get("buttonViewModel", {})
            .get("onTap", {})
            .get("serialCommand", {})
            .get("commands", [])
        )
        dislike_toggled_commands = (
            dislike_toggle.get("toggledButtonViewModel", {})
            .get("buttonViewModel", {})
            .get("onTap", {})
            .get("serialCommand", {})
            .get("commands", [])
        )

        result["like"] = _normalize_like_endpoint(
            _find_innertube_command(like_default_commands, "likeEndpoint")
        )
        result["removeLike"] = _normalize_like_endpoint(
            _find_innertube_command(like_toggled_commands, "likeEndpoint")
        )
        result["dislike"] = _normalize_like_endpoint(
            _find_innertube_command(dislike_default_commands, "likeEndpoint")
        )
        result["removeDislike"] = _normalize_like_endpoint(
            _find_innertube_command(dislike_toggled_commands, "likeEndpoint")
        )
        return result

    return result


def extract_comments_token(data: Any) -> Optional[str]:
    for node in iter_nodes(data):
        if not isinstance(node, dict):
            continue
        panel = node.get("engagementPanelSectionListRenderer")
        if not isinstance(panel, dict):
            continue
        if panel.get("targetId") != "engagement-panel-comments-section":
            continue
        contents = (
            panel.get("content", {})
            .get("sectionListRenderer", {})
            .get("contents", [])
        )
        if not isinstance(contents, list):
            continue
        for item in contents:
            item_contents = item.get("itemSectionRenderer", {}).get("contents", [])
            if not isinstance(item_contents, list):
                continue
            for section_item in item_contents:
                continuation = (
                    section_item.get("continuationItemRenderer", {})
                    .get("continuationEndpoint", {})
                    .get("continuationCommand", {})
                    .get("token")
                )
                if continuation:
                    return continuation
    return None


def extract_comments(data: Any, limit: int = 8) -> List[CommentItem]:
    updates = data.get("frameworkUpdates", {}).get("entityBatchUpdate", {})
    mutations = updates.get("mutations", []) if isinstance(updates, dict) else []

    entities: Dict[str, Dict[str, Any]] = {}
    if isinstance(mutations, list):
        for mutation in mutations:
            if not isinstance(mutation, dict):
                continue
            key = mutation.get("entityKey")
            payload = mutation.get("payload")
            if key and isinstance(payload, dict):
                entities[key] = payload

    comments: List[CommentItem] = []
    seen: set[str] = set()

    for node in iter_nodes(data):
        if not isinstance(node, dict) or "commentThreadRenderer" not in node:
            continue

        thread = node.get("commentThreadRenderer", {})
        view_model = thread.get("commentViewModel", {}).get("commentViewModel", {})
        comment_key = view_model.get("commentKey")
        entity = entities.get(comment_key, {}).get("commentEntityPayload", {})

        if not isinstance(entity, dict):
            continue

        properties = entity.get("properties", {})
        comment_id = properties.get("commentId")
        body = get_content_text(properties.get("content")) or ""
        author = entity.get("author", {}).get("displayName") or "Unknown"

        if not comment_id or not body or comment_id in seen:
            continue

        toolbar = entity.get("toolbar", {})
        comments.append(
            CommentItem(
                id=comment_id,
                author=author,
                avatarUrl=entity.get("author", {}).get("avatarThumbnailUrl"),
                body=body,
                likeCountText=toolbar.get("likeCountNotliked")
                or toolbar.get("likeCountLiked"),
                publishedTimeText=properties.get("publishedTime"),
                replyCountText=toolbar.get("replyCount"),
                pinnedText=view_model.get("pinnedText"),
            )
        )
        seen.add(comment_id)

        if len(comments) >= limit:
            break

    return comments


def extract_storyboard(player_data: Any) -> Optional[StoryboardSpec]:
    """Parse storyboard spec from InnerTube playerStoryboardSpecRenderer.

    The spec string format (confirmed from yt-dlp source + real player responses):
        BASE_URL|L0_PARAMS|L1_PARAMS|L2_PARAMS

    BASE_URL contains '$L' (level index) and '$N' (replaced by the level's name
    template, which itself may contain '$M' for the sprite-sheet file index).

    Each level's PARAMS is '#'-separated with exactly 8 fields:
        width # height # frame_count # cols # rows # interval_ms # name_template # sigh

    - width/height: pixel dimensions of a single thumbnail tile
    - frame_count:  total thumbnail frames across all sprite-sheet files
    - cols/rows:    grid layout of thumbnails within each sprite sheet
    - interval_ms:  milliseconds between consecutive frames (0 for L0 = static strip)
    - name_template: replaces $N in BASE_URL; may itself contain $M for file index
                     (e.g. "M$M" → M0, M1, …)  or be a fixed string (e.g. "default")
    - sigh:         URL signature appended as &sigh=…

    We select the highest-quality level that has interval_ms > 0.
    """
    if not isinstance(player_data, dict):
        return None

    spec_str = (
        player_data
        .get("storyboards", {})
        .get("playerStoryboardSpecRenderer", {})
        .get("spec")
    )
    if not isinstance(spec_str, str) or not spec_str:
        return None

    parts = spec_str.split("|")
    if len(parts) < 2:
        return None

    base_url = parts[0]
    level_specs = parts[1:]  # index 0 = L0 (lowest quality), last = highest

    # Walk levels; keep the last valid one (highest quality).
    best = None
    for level_idx, level_str in enumerate(level_specs):
        fields = level_str.split("#")
        if len(fields) < 8:
            continue
        try:
            tile_w = int(fields[0])
            tile_h = int(fields[1])
            frame_count = int(fields[2])
            cols = int(fields[3])
            rows = int(fields[4])
            interval_ms = int(fields[5])
        except (ValueError, IndexError):
            continue
        if tile_w <= 0 or tile_h <= 0 or frame_count <= 0 or cols <= 0 or rows <= 0:
            continue
        if interval_ms <= 0:
            continue  # L0 often has interval=0 (static overview strip, not time-correlated)
        name_template = fields[6]
        sigh = fields[7]
        best = (level_idx, tile_w, tile_h, frame_count, cols, rows, interval_ms, name_template, sigh)

    if best is None:
        return None

    level_idx, tile_w, tile_h, frame_count, cols, rows, interval_ms, name_template, sigh = best

    # Number of sprite-sheet files for this level.
    frames_per_file = cols * rows
    file_count = math.ceil(frame_count / frames_per_file)

    # Build per-file URLs:
    #   1. $L  → numeric level index
    #   2. $N  → name_template (e.g. "M$M")
    #   3. $M  → file index (0, 1, 2, …)
    #   4. append &sigh=… signature
    url_base = base_url.replace("$L", str(level_idx)).replace("$N", name_template)
    sigh_suffix = f"&sigh={sigh}" if sigh else ""
    urls = [url_base.replace("$M", str(j)) + sigh_suffix for j in range(file_count)]

    return StoryboardSpec(
        urls=urls,
        tileWidth=tile_w,
        tileHeight=tile_h,
        cols=cols,
        rows=rows,
        intervalSeconds=interval_ms / 1000.0,
    )
