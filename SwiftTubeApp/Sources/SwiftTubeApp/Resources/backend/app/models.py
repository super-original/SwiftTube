from __future__ import annotations

from typing import List, Optional

from pydantic import BaseModel, Field


class Thumbnail(BaseModel):
    url: str
    width: Optional[int] = None
    height: Optional[int] = None


class VideoItem(BaseModel):
    id: str
    title: str
    channel: Optional[str] = None
    viewCountText: Optional[str] = None
    publishedTimeText: Optional[str] = None
    thumbnails: List[Thumbnail] = Field(default_factory=list)


class RecommendationsResponse(BaseModel):
    items: List[VideoItem] = Field(default_factory=list)
    continuation: Optional[str] = None
    note: Optional[str] = None


class StreamInfo(BaseModel):
    url: str
    mimeType: Optional[str] = None
    qualityLabel: Optional[str] = None
    bitrate: Optional[int] = None
    width: Optional[int] = None
    height: Optional[int] = None
    fps: Optional[int] = None
    hasAudio: bool = False
    hasVideo: bool = False
    isAdaptive: bool = False


class VideoPlayback(BaseModel):
    id: str
    title: Optional[str] = None
    streams: List[StreamInfo] = Field(default_factory=list)
    bestStreamUrl: Optional[str] = None
    bestStream: Optional[StreamInfo] = None
