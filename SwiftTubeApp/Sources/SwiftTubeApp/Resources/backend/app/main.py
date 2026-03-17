from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from typing import Optional

from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from innertube import InnerTube
from innertube.errors import RequestError

from .models import RecommendationsResponse, VideoPlayback
from .parse import (
    extract_browse_ids_from_guide,
    extract_comments,
    extract_comments_token,
    extract_continuation_token,
    extract_related_videos,
    extract_video_items,
    extract_watch_metadata,
    parse_streams,
    pick_best_stream,
)
from .playback import extract_playback

app = FastAPI(title="SwiftTube Backend", version="0.1.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["GET"],
    allow_headers=["*"],
)

client_web = InnerTube("WEB")
# WEB_PARENT_TOOLS currently returns a playable muxed stream without login.
client_player = InnerTube("WEB_PARENT_TOOLS")


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}


@app.get("/recommendations", response_model=RecommendationsResponse)
def recommendations(
    continuation: Optional[str] = Query(default=None, min_length=1)
) -> RecommendationsResponse:
    note: Optional[str] = None
    if continuation:
        data = client_web.browse(continuation=continuation)
    else:
        data = client_web.browse(browse_id="FEwhat_to_watch")

    items = extract_video_items(data)
    token = extract_continuation_token(data)

    if not items and not continuation:
        guide = client_web.guide()
        browse_ids = extract_browse_ids_from_guide(guide, limit=4)
        fallback_items = []
        seen = set()
        for browse_id in browse_ids:
            try:
                fallback_data = client_web.browse(browse_id=browse_id)
                for item in extract_video_items(fallback_data):
                    if item.id in seen:
                        continue
                    seen.add(item.id)
                    fallback_items.append(item)
            except Exception:
                continue
        if fallback_items:
            note = "History is off on YouTube. Showing Explore picks instead."
            items = fallback_items
            token = None

    return RecommendationsResponse(items=items, continuation=token, note=note)


@app.get("/video/{video_id}", response_model=VideoPlayback)
def video_info(video_id: str) -> VideoPlayback:
    with ThreadPoolExecutor(max_workers=3) as executor:
        watch_future = executor.submit(client_web.next, video_id=video_id)
        playback_future = executor.submit(extract_playback, video_id)
        player_future = executor.submit(client_player.player, video_id)

        try:
            watch_data = watch_future.result()
        except RequestError as exc:
            raise HTTPException(status_code=502, detail=str(exc)) from exc

        playback_bundle = None
        playback_error: Optional[Exception] = None
        try:
            playback_bundle = playback_future.result()
        except Exception as exc:  # pragma: no cover - fallback path
            playback_error = exc

        try:
            player_data = player_future.result()
        except RequestError as exc:
            raise HTTPException(status_code=502, detail=str(exc)) from exc

    watch_metadata = extract_watch_metadata(watch_data)
    related_videos = extract_related_videos(watch_data, current_video_id=video_id)

    comments = []
    comments_token = extract_comments_token(watch_data)
    if comments_token:
        try:
            comments_response = client_web.next(continuation=comments_token)
            comments = extract_comments(comments_response)
        except Exception:
            comments = []

    streams = parse_streams(player_data)
    best = pick_best_stream(streams)
    title = None
    details = player_data.get("videoDetails") if isinstance(player_data, dict) else None
    if isinstance(details, dict):
        title = details.get("title")

    if playback_bundle is None:
        if not streams:
            detail = str(playback_error) if playback_error else "No playable streams found"
            raise HTTPException(status_code=404, detail=detail)

        fallback_duration = None
        if isinstance(details, dict):
            fallback_duration = details.get("lengthSeconds")
            if isinstance(fallback_duration, str) and fallback_duration.isdigit():
                seconds = int(fallback_duration)
                minutes, secs = divmod(seconds, 60)
                hours, minutes = divmod(minutes, 60)
                fallback_duration = (
                    f"{hours}:{minutes:02d}:{secs:02d}"
                    if hours
                    else f"{minutes}:{secs:02d}"
                )
            else:
                fallback_duration = None

        return VideoPlayback(
            id=video_id,
            title=watch_metadata.get("title") or title,
            channel=watch_metadata.get("channel"),
            channelId=watch_metadata.get("channelId"),
            channelAvatarUrl=watch_metadata.get("channelAvatarUrl"),
            subscriberCountText=watch_metadata.get("subscriberCountText"),
            viewCountText=watch_metadata.get("viewCountText"),
            publishedTimeText=watch_metadata.get("publishedTimeText"),
            publishedDateText=watch_metadata.get("publishedDateText"),
            likeCountText=watch_metadata.get("likeCountText"),
            durationText=fallback_duration,
            description=watch_metadata.get("description"),
            commentCountText=watch_metadata.get("commentCountText"),
            streams=streams,
            recommendations=related_videos,
            comments=comments,
            playbackStrategy="direct",
            preferredMuxedStream=best,
            bestStreamUrl=best.url if best else None,
            bestStream=best,
        )

    if not playback_bundle.streams and not streams:
        raise HTTPException(status_code=404, detail="No playable streams found")

    resolved_streams = playback_bundle.streams or streams
    resolved_muxed_stream = playback_bundle.preferred_muxed_stream or best
    resolved_strategy = (
        playback_bundle.playback_strategy if playback_bundle.streams else "direct"
    )

    return VideoPlayback(
        id=video_id,
        title=watch_metadata.get("title") or playback_bundle.title or title,
        channel=watch_metadata.get("channel"),
        channelId=watch_metadata.get("channelId"),
        channelAvatarUrl=watch_metadata.get("channelAvatarUrl"),
        subscriberCountText=watch_metadata.get("subscriberCountText"),
        viewCountText=watch_metadata.get("viewCountText"),
        publishedTimeText=watch_metadata.get("publishedTimeText"),
        publishedDateText=watch_metadata.get("publishedDateText"),
        likeCountText=watch_metadata.get("likeCountText"),
        durationText=playback_bundle.duration_text,
        description=watch_metadata.get("description"),
        commentCountText=watch_metadata.get("commentCountText"),
        streams=resolved_streams,
        recommendations=related_videos,
        comments=comments,
        playbackStrategy=resolved_strategy,
        preferredMuxedStream=resolved_muxed_stream,
        preferredVideoStream=playback_bundle.preferred_video_stream,
        preferredAudioStream=playback_bundle.preferred_audio_stream,
        bestStreamUrl=playback_bundle.best_stream_url,
        bestStream=playback_bundle.best_stream or best,
    )
