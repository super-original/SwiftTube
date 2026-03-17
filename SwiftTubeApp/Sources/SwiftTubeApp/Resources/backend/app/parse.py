from __future__ import annotations

from typing import Any, Dict, Iterable, List, Optional

from .models import CommentItem, StreamInfo, Thumbnail, VideoItem


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
                    formatId=str(entry.get("itag")) if entry.get("itag") else None,
                    mimeType=mime_type,
                    qualityLabel=entry.get("qualityLabel"),
                    bitrate=entry.get("bitrate"),
                    width=entry.get("width"),
                    height=entry.get("height"),
                    fps=entry.get("fps"),
                    audioCodec=entry.get("audioQuality"),
                    videoCodec=entry.get("codecs"),
                    container=entry.get("container"),
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
