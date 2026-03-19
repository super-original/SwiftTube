from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
import os
from typing import Optional

from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from innertube import InnerTube
from innertube.errors import RequestError

from .auth import BrowserAuthManager
from .models import (
    AuthStatusResponse,
    BrowserAuthRequest,
    CommentsResponse,
    RecommendationsResponse,
    VideoPlayback,
)
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

APP_VERSION = os.environ.get("SWIFTTUBE_APP_VERSION", "0.0.0")

app = FastAPI(title="SwiftTube Backend", version=APP_VERSION)
INSTANCE_ID = os.environ.get("SWIFTTUBE_INSTANCE_ID")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["GET"],
    allow_headers=["*"],
)

public_client_web = InnerTube("WEB")
public_client_player = InnerTube("WEB_PARENT_TOOLS")
auth_manager = BrowserAuthManager()


def _build_clients(use_auth: bool) -> tuple[InnerTube, InnerTube]:
    if use_auth and auth_manager.is_authenticated:
        return auth_manager.build_client("WEB"), auth_manager.build_client("WEB_PARENT_TOOLS")
    return public_client_web, public_client_player


def _load_recommendations(
    client_web: InnerTube,
    continuation: Optional[str],
) -> tuple[list, Optional[str]]:
    if continuation:
        data = client_web.browse(continuation=continuation)
    else:
        data = client_web.browse(browse_id="FEwhat_to_watch")
    return extract_video_items(data), extract_continuation_token(data)


def _merge_streams(*stream_groups: list) -> list:
    merged = []
    seen = set()

    for group in stream_groups:
        for stream in group or []:
            key = (stream.url, stream.formatId, stream.streamKind)
            if key in seen:
                continue
            seen.add(key)
            merged.append(stream)

    return merged


@app.get("/health")
def health() -> dict:
    return {"status": "ok", "instanceId": INSTANCE_ID, "version": APP_VERSION}


@app.get("/auth/status", response_model=AuthStatusResponse)
def auth_status() -> AuthStatusResponse:
    return AuthStatusResponse(**auth_manager.status_payload(validate=True))


@app.post("/auth/browser", response_model=AuthStatusResponse)
def connect_browser_auth(request: BrowserAuthRequest) -> AuthStatusResponse:
    try:
        payload = auth_manager.connect_browser(request.browser)
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return AuthStatusResponse(**payload)


@app.delete("/auth/session", response_model=AuthStatusResponse)
def clear_auth_session() -> AuthStatusResponse:
    return AuthStatusResponse(**auth_manager.clear())


@app.get("/recommendations", response_model=RecommendationsResponse)
def recommendations(
    continuation: Optional[str] = Query(default=None, min_length=1)
) -> RecommendationsResponse:
    note: Optional[str] = None
    using_auth = auth_manager.is_authenticated
    client_web, _ = _build_clients(use_auth=using_auth)

    try:
        items, token = _load_recommendations(client_web, continuation)
    except RequestError as exc:
        if not using_auth:
            raise HTTPException(status_code=502, detail=str(exc)) from exc
        auth_manager.clear()
        note = "Your saved YouTube session expired. Showing public picks instead."
        try:
            items, token = _load_recommendations(public_client_web, continuation)
        except RequestError as fallback_exc:
            raise HTTPException(status_code=502, detail=str(fallback_exc)) from fallback_exc

    if not items and not continuation:
        fallback_client = public_client_web if note else client_web
        guide = fallback_client.guide()
        browse_ids = extract_browse_ids_from_guide(guide, limit=4)
        fallback_items = []
        seen = set()
        for browse_id in browse_ids:
            try:
                fallback_data = fallback_client.browse(browse_id=browse_id)
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


def _video_info(
    video_id: str,
    client_web: InnerTube,
    client_player: InnerTube,
    playback_auth: Optional[dict] = None,
) -> VideoPlayback:
    with ThreadPoolExecutor(max_workers=4) as executor:
        watch_future = executor.submit(client_web.next, video_id=video_id)
        playback_future = executor.submit(extract_playback, video_id, playback_auth)
        player_future = executor.submit(client_player.player, video_id)
        auth_ladder_future = None
        if playback_auth is not None and auth_manager.is_authenticated:
            auth_ladder_future = executor.submit(
                auth_manager.build_client("MWEB").player,
                video_id,
            )

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

        auth_ladder_data = None
        if auth_ladder_future is not None:
            try:
                auth_ladder_data = auth_ladder_future.result()
            except RequestError:
                auth_ladder_data = None

    watch_metadata = extract_watch_metadata(watch_data)
    related_videos = extract_related_videos(watch_data, current_video_id=video_id)

    startup_streams = parse_streams(player_data)
    auth_ladder_streams = parse_streams(auth_ladder_data) if auth_ladder_data else []
    streams = _merge_streams(startup_streams, auth_ladder_streams)
    best = pick_best_stream(startup_streams) or pick_best_stream(streams)
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
            comments=[],
            playbackStrategy="direct",
            preferredManifestStream=None,
            preferredMuxedStream=best,
            bestStreamUrl=best.url if best else None,
            bestStream=best,
        )

    if not playback_bundle.streams and not streams:
        raise HTTPException(status_code=404, detail="No playable streams found")

    resolved_streams = _merge_streams(playback_bundle.streams, streams)
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
        comments=[],
        playbackStrategy=resolved_strategy,
        preferredManifestStream=playback_bundle.preferred_manifest_stream,
        preferredMuxedStream=resolved_muxed_stream,
        preferredVideoStream=playback_bundle.preferred_video_stream,
        preferredAudioStream=playback_bundle.preferred_audio_stream,
        bestStreamUrl=playback_bundle.best_stream_url,
        bestStream=playback_bundle.best_stream or best,
    )


def _comments_info(video_id: str, client_web: InnerTube) -> CommentsResponse:
    watch_data = client_web.next(video_id=video_id)
    watch_metadata = extract_watch_metadata(watch_data)
    comments_token = extract_comments_token(watch_data)
    comments = []
    if comments_token:
        try:
            comments_response = client_web.next(continuation=comments_token)
            comments = extract_comments(comments_response)
        except Exception:
            comments = []

    return CommentsResponse(
        comments=comments,
        commentCountText=watch_metadata.get("commentCountText"),
    )


@app.get("/video/{video_id}", response_model=VideoPlayback)
def video_info(video_id: str) -> VideoPlayback:
    using_auth = auth_manager.is_authenticated
    if using_auth:
        client_web, client_player = _build_clients(use_auth=True)
        try:
            return _video_info(
                video_id,
                client_web,
                client_player,
                auth_manager.playback_options(),
            )
        except RequestError:
            auth_manager.clear()

    return _video_info(video_id, public_client_web, public_client_player)


@app.get("/video/{video_id}/comments", response_model=CommentsResponse)
def video_comments(video_id: str) -> CommentsResponse:
    using_auth = auth_manager.is_authenticated
    if using_auth:
        client_web, _ = _build_clients(use_auth=True)
        try:
            return _comments_info(video_id, client_web)
        except RequestError:
            auth_manager.clear()

    try:
        return _comments_info(video_id, public_client_web)
    except RequestError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
