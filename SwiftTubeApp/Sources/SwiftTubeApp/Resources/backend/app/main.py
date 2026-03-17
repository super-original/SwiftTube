from __future__ import annotations

from typing import Optional

from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from innertube import InnerTube
from innertube.errors import RequestError

from .models import RecommendationsResponse, VideoPlayback
from .parse import (
    extract_browse_ids_from_guide,
    extract_continuation_token,
    extract_video_items,
    parse_streams,
    pick_best_stream,
)

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
    try:
        data = client_player.player(video_id)
    except RequestError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc

    streams = parse_streams(data)
    best = pick_best_stream(streams)
    title = None
    details = data.get("videoDetails") if isinstance(data, dict) else None
    if isinstance(details, dict):
        title = details.get("title")

    if not streams:
        raise HTTPException(status_code=404, detail="No playable streams found")

    return VideoPlayback(
        id=video_id,
        title=title,
        streams=streams,
        bestStreamUrl=best.url if best else None,
        bestStream=best,
    )
