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
    PlaylistFeed,
    PlaylistLibraryResponse,
    PlaylistMutationRequest,
    PlaylistMutationResponse,
    PlaylistOptionsResponse,
    RatingRequest,
    RatingResponse,
    RecommendationsResponse,
    SearchResponse,
    SubscriptionRequest,
    SubscriptionResponse,
    VideoPlayback,
    WatchLaterRequest,
    WatchLaterResponse,
)
from .parse import (
    extract_browse_ids_from_guide,
    extract_comments,
    extract_comments_token,
    extract_continuation_token,
    extract_playlist_feed,
    extract_playlist_options,
    extract_playlist_option_commands,
    extract_playlist_summaries,
    extract_rating_commands,
    extract_rating_state,
    extract_related_videos,
    extract_subscription_commands,
    extract_subscription_state,
    extract_storyboard,
    extract_video_items,
    extract_watch_metadata,
    extract_watch_page_save_command,
    parse_streams,
    pick_best_stream,
)
from .playback import extract_playback
from .playback import build_playback_bundle_from_streams

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
# Separate WEB client used exclusively for /player requests (storyboard data).
# Must be a distinct instance from public_client_web to allow concurrent calls.
public_client_web_player = InnerTube("WEB")
auth_manager = BrowserAuthManager()


def _build_clients(use_auth: bool) -> tuple[InnerTube, InnerTube, InnerTube]:
    """Return (web_client, player_client, web_player_client).
    web_player_client is a WEB client used solely for /player to get storyboard data.
    """
    if use_auth and auth_manager.is_authenticated:
        return (
            auth_manager.build_client("WEB"),
            auth_manager.build_client("WEB_PARENT_TOOLS"),
            auth_manager.build_client("WEB"),
        )
    return public_client_web, public_client_player, public_client_web_player


def _dispatch_inner_tube_command(client: InnerTube, command) -> dict:
    return client.adaptor.dispatch(f"/{command.apiPath}", body=command.payload)


def _load_playlist_options(client_web: InnerTube, watch_data: dict) -> list:
    save_command = extract_watch_page_save_command(watch_data)
    if save_command is None:
        return []
    response = _dispatch_inner_tube_command(client_web, save_command)
    return extract_playlist_options(response)


def _load_playlist_sheet(client_web: InnerTube, watch_data: dict) -> dict:
    save_command = extract_watch_page_save_command(watch_data)
    if save_command is None:
        raise HTTPException(status_code=404, detail="Playlist save options are unavailable for this video.")
    return _dispatch_inner_tube_command(client_web, save_command)


def _find_playlist_option(options: list, playlist_id: str):
    for option in options:
        if option.playlistId == playlist_id:
            return option
    return None


def _playlist_browse_id(playlist_id: str) -> str:
    return playlist_id if playlist_id.startswith("VL") else f"VL{playlist_id}"


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
    client_web, _, _wpc = _build_clients(use_auth=using_auth)

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


@app.get("/search", response_model=SearchResponse)
def search(
    q: str = Query(min_length=1),
    continuation: Optional[str] = Query(default=None, min_length=1),
) -> SearchResponse:
    using_auth = auth_manager.is_authenticated
    client_web, _, _wpc = _build_clients(use_auth=using_auth)

    try:
        if continuation:
            data = client_web.search(continuation=continuation)
        else:
            data = client_web.search(query=q)
    except RequestError as exc:
        if not using_auth:
            raise HTTPException(status_code=502, detail=str(exc)) from exc
        auth_manager.clear()
        try:
            if continuation:
                data = public_client_web.search(continuation=continuation)
            else:
                data = public_client_web.search(query=q)
        except RequestError as fallback_exc:
            raise HTTPException(status_code=502, detail=str(fallback_exc)) from fallback_exc

    items = extract_video_items(data)
    token = extract_continuation_token(data)
    return SearchResponse(items=items, continuation=token, query=q)


@app.get("/library/playlists", response_model=PlaylistLibraryResponse)
def library_playlists(
    continuation: Optional[str] = Query(default=None, min_length=1),
) -> PlaylistLibraryResponse:
    client_web = _require_authenticated_web_client()

    try:
        if continuation:
            data = client_web.browse(continuation=continuation)
        else:
            data = client_web.browse(browse_id="FEplaylist_aggregation")
    except RequestError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc

    return PlaylistLibraryResponse(
        items=extract_playlist_summaries(data),
        continuation=extract_continuation_token(data),
    )


@app.get("/library/playlist/{playlist_id}", response_model=PlaylistFeed)
def library_playlist_feed(
    playlist_id: str,
    continuation: Optional[str] = Query(default=None, min_length=1),
) -> PlaylistFeed:
    client_web = _require_authenticated_web_client()

    try:
        if continuation:
            data = client_web.browse(continuation=continuation)
        else:
            data = client_web.browse(browse_id=_playlist_browse_id(playlist_id))
    except RequestError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc

    return extract_playlist_feed(data, playlist_id=playlist_id.removeprefix("VL"))


def _video_info(
    video_id: str,
    client_web: InnerTube,
    client_player: InnerTube,
    client_web_player: Optional[InnerTube] = None,
    playback_auth: Optional[dict] = None,
    supplemental_player_clients: Optional[list[InnerTube]] = None,
) -> VideoPlayback:
    supplemental_player_clients = supplemental_player_clients or []

    # +1 slot for the WEB /player call that carries storyboard data.
    max_workers = 4 + len(supplemental_player_clients)
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        watch_future = executor.submit(client_web.next, video_id=video_id)
        playback_future = executor.submit(extract_playback, video_id, playback_auth)
        player_future = executor.submit(client_player.player, video_id)
        # WEB client /player response reliably contains playerStoryboardSpecRenderer.
        web_player_future = executor.submit(
            (client_web_player or client_web).player, video_id
        )
        supplemental_player_futures = [
            executor.submit(client.player, video_id) for client in supplemental_player_clients
        ]

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

        web_player_data: dict = {}
        try:
            web_player_data = web_player_future.result() or {}
        except Exception:
            pass

        supplemental_player_data = []
        for future in supplemental_player_futures:
            try:
                supplemental_player_data.append(future.result())
            except RequestError:
                continue

    watch_metadata = extract_watch_metadata(watch_data)
    subscription = extract_subscription_state(watch_data, watch_metadata)
    rating = extract_rating_state(watch_data)
    playlist_options = []
    if auth_manager.is_authenticated and extract_watch_page_save_command(watch_data) is not None:
        try:
            playlist_options = _load_playlist_options(client_web, watch_data)
        except RequestError:
            playlist_options = []
    watch_later = _find_playlist_option(playlist_options, "WL")
    playlist_save_enabled = extract_watch_page_save_command(watch_data) is not None
    related_videos = extract_related_videos(watch_data, current_video_id=video_id)
    # WEB client response is the authoritative source for storyboard spec.
    storyboard = extract_storyboard(web_player_data) or extract_storyboard(player_data)

    primary_streams = parse_streams(player_data)
    supplemental_streams = [parse_streams(data) for data in supplemental_player_data]
    player_streams = _merge_streams(primary_streams, *supplemental_streams)
    player_bundle = build_playback_bundle_from_streams(player_streams)
    best = pick_best_stream(player_streams)
    title = None
    details = player_data.get("videoDetails") if isinstance(player_data, dict) else None
    if isinstance(details, dict):
        title = details.get("title")

    if playback_bundle is None:
        if not player_streams:
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
            streams=player_streams,
            recommendations=related_videos,
            comments=[],
            playbackStrategy=player_bundle.playback_strategy,
            preferredManifestStream=player_bundle.preferred_manifest_stream,
            preferredMuxedStream=player_bundle.preferred_muxed_stream or best,
            preferredVideoStream=player_bundle.preferred_video_stream,
            preferredAudioStream=player_bundle.preferred_audio_stream,
            bestStreamUrl=(player_bundle.best_stream or best).url if (player_bundle.best_stream or best) else None,
            bestStream=player_bundle.best_stream or best,
            subtitles=player_bundle.subtitles,
            storyboard=storyboard,
            subscription=subscription,
            rating=rating,
            watchLater=watch_later,
            playlistSaveEnabled=playlist_save_enabled,
        )

    if not playback_bundle.streams and not player_streams:
        raise HTTPException(status_code=404, detail="No playable streams found")

    resolved_streams = playback_bundle.streams or player_streams
    resolved_bundle = playback_bundle if playback_bundle.streams else player_bundle
    resolved_manifest_stream = resolved_bundle.preferred_manifest_stream
    resolved_muxed_stream = resolved_bundle.preferred_muxed_stream or best
    resolved_video_stream = resolved_bundle.preferred_video_stream
    resolved_audio_stream = resolved_bundle.preferred_audio_stream
    resolved_strategy = resolved_bundle.playback_strategy if resolved_streams else "direct"
    resolved_best_stream = resolved_bundle.best_stream or best

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
        preferredManifestStream=resolved_manifest_stream,
        preferredMuxedStream=resolved_muxed_stream,
        preferredVideoStream=resolved_video_stream,
        preferredAudioStream=resolved_audio_stream,
        bestStreamUrl=resolved_best_stream.url if resolved_best_stream else None,
        bestStream=resolved_best_stream,
        subtitles=resolved_bundle.subtitles,
        storyboard=storyboard,
        subscription=subscription,
        rating=rating,
        watchLater=watch_later,
        playlistSaveEnabled=playlist_save_enabled,
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


def _require_authenticated_web_client() -> InnerTube:
    if not auth_manager.is_authenticated:
        raise HTTPException(status_code=401, detail="Sign in to YouTube to use this action.")
    return auth_manager.build_client("WEB")


def _load_watch_data_for_actions(video_id: str) -> tuple[InnerTube, dict, dict]:
    client_web = _require_authenticated_web_client()
    try:
        watch_data = client_web.next(video_id=video_id)
    except RequestError as exc:
        auth_manager.clear()
        raise HTTPException(
            status_code=401,
            detail="Your saved YouTube session expired. Reconnect your browser session and try again.",
        ) from exc
    return client_web, watch_data, extract_watch_metadata(watch_data)


@app.get("/video/{video_id}", response_model=VideoPlayback)
def video_info(video_id: str) -> VideoPlayback:
    using_auth = auth_manager.is_authenticated
    if using_auth:
        client_web, client_player, client_web_player = _build_clients(use_auth=True)
        try:
            return _video_info(
                video_id,
                client_web,
                client_player,
                client_web_player=client_web_player,
                playback_auth=auth_manager.playback_options(),
                supplemental_player_clients=[auth_manager.build_client("MWEB")],
            )
        except RequestError:
            auth_manager.clear()

    return _video_info(
        video_id,
        public_client_web,
        public_client_player,
        client_web_player=public_client_web_player,
    )


@app.get("/video/{video_id}/playlists", response_model=PlaylistOptionsResponse)
def video_playlists(video_id: str) -> PlaylistOptionsResponse:
    client_web, watch_data, _metadata = _load_watch_data_for_actions(video_id)
    try:
        options = extract_playlist_options(_load_playlist_sheet(client_web, watch_data))
    except RequestError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc

    return PlaylistOptionsResponse(options=options)


@app.post("/video/{video_id}/subscription", response_model=SubscriptionResponse)
def update_video_subscription(
    video_id: str, request: SubscriptionRequest
) -> SubscriptionResponse:
    client_web, watch_data, metadata = _load_watch_data_for_actions(video_id)
    subscription = extract_subscription_state(watch_data, metadata)
    if subscription is None or not subscription.enabled:
        raise HTTPException(status_code=404, detail="Subscribe controls are unavailable for this video.")

    commands = extract_subscription_commands(watch_data)
    command = commands["subscribe"] if request.subscribed else commands["unsubscribe"]
    if command is None:
        raise HTTPException(status_code=404, detail="This subscription action is unavailable right now.")

    if subscription.subscribed != request.subscribed:
        try:
            _dispatch_inner_tube_command(client_web, command)
        except RequestError as exc:
            raise HTTPException(status_code=502, detail=str(exc)) from exc
        watch_data = client_web.next(video_id=video_id)
        metadata = extract_watch_metadata(watch_data)

    return SubscriptionResponse(
        subscription=extract_subscription_state(watch_data, metadata)
    )


@app.post("/video/{video_id}/rating", response_model=RatingResponse)
def update_video_rating(video_id: str, request: RatingRequest) -> RatingResponse:
    action = request.action.lower()
    if action not in {"like", "dislike", "none"}:
        raise HTTPException(status_code=400, detail="Rating action must be one of: like, dislike, none.")

    client_web, watch_data, _metadata = _load_watch_data_for_actions(video_id)
    rating = extract_rating_state(watch_data)
    if rating is None:
        raise HTTPException(status_code=404, detail="Like and dislike controls are unavailable for this video.")

    commands = extract_rating_commands(watch_data)
    command_key = {
        "like": "removeLike" if rating.status == "LIKE" else "like",
        "dislike": "removeDislike" if rating.status == "DISLIKE" else "dislike",
        "none": "removeLike" if rating.status == "LIKE" else "removeDislike",
    }[action]
    command = commands.get(command_key)
    if command is None:
        raise HTTPException(status_code=404, detail="This rating action is unavailable right now.")

    if not (
        (action == "like" and rating.status == "LIKE")
        or (action == "dislike" and rating.status == "DISLIKE")
        or (action == "none" and rating.status == "INDIFFERENT")
    ):
        try:
            _dispatch_inner_tube_command(client_web, command)
        except RequestError as exc:
            raise HTTPException(status_code=502, detail=str(exc)) from exc
        watch_data = client_web.next(video_id=video_id)

    return RatingResponse(rating=extract_rating_state(watch_data))


@app.post("/video/{video_id}/watch-later", response_model=WatchLaterResponse)
def update_watch_later(video_id: str, request: WatchLaterRequest) -> WatchLaterResponse:
    client_web, watch_data, _metadata = _load_watch_data_for_actions(video_id)
    try:
        sheet = _load_playlist_sheet(client_web, watch_data)
    except RequestError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    options = extract_playlist_options(sheet)
    commands = extract_playlist_option_commands(sheet)
    option = _find_playlist_option(options, "WL")
    if option is None:
        raise HTTPException(status_code=404, detail="Watch Later is unavailable for this account.")

    if option.saved != request.saved:
        command = commands.get("WL", {}).get("add" if request.saved else "remove")
        if command is None:
            raise HTTPException(status_code=404, detail="Watch Later mutation is unavailable right now.")
        try:
            _dispatch_inner_tube_command(client_web, command)
        except RequestError as exc:
            raise HTTPException(status_code=502, detail=str(exc)) from exc
        watch_data = client_web.next(video_id=video_id)
        try:
            options = extract_playlist_options(_load_playlist_sheet(client_web, watch_data))
        except RequestError as exc:
            raise HTTPException(status_code=502, detail=str(exc)) from exc
        option = _find_playlist_option(options, "WL")

    return WatchLaterResponse(watchLater=option)


@app.post("/video/{video_id}/playlist", response_model=PlaylistMutationResponse)
def update_video_playlist(
    video_id: str, request: PlaylistMutationRequest
) -> PlaylistMutationResponse:
    client_web, watch_data, _metadata = _load_watch_data_for_actions(video_id)
    try:
        sheet = _load_playlist_sheet(client_web, watch_data)
    except RequestError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    options = extract_playlist_options(sheet)
    commands = extract_playlist_option_commands(sheet)
    option = _find_playlist_option(options, request.playlistId)
    if option is None:
        raise HTTPException(status_code=404, detail="That playlist was not found in your YouTube library.")

    if option.saved != request.saved:
        command = commands.get(request.playlistId, {}).get("add" if request.saved else "remove")
        if command is None:
            raise HTTPException(status_code=404, detail="That playlist mutation is unavailable right now.")
        try:
            _dispatch_inner_tube_command(client_web, command)
        except RequestError as exc:
            raise HTTPException(status_code=502, detail=str(exc)) from exc
        watch_data = client_web.next(video_id=video_id)
        try:
            options = extract_playlist_options(_load_playlist_sheet(client_web, watch_data))
        except RequestError as exc:
            raise HTTPException(status_code=502, detail=str(exc)) from exc
        option = _find_playlist_option(options, request.playlistId)

    return PlaylistMutationResponse(playlist=option)


@app.get("/video/{video_id}/comments", response_model=CommentsResponse)
def video_comments(video_id: str) -> CommentsResponse:
    using_auth = auth_manager.is_authenticated
    if using_auth:
        client_web, _, _wpc = _build_clients(use_auth=True)
        try:
            return _comments_info(video_id, client_web)
        except RequestError:
            auth_manager.clear()

    try:
        return _comments_info(video_id, public_client_web)
    except RequestError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
