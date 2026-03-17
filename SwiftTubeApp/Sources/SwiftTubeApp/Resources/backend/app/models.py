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
    durationText: Optional[str] = None
    thumbnails: List[Thumbnail] = Field(default_factory=list)


class RecommendationsResponse(BaseModel):
    items: List[VideoItem] = Field(default_factory=list)
    continuation: Optional[str] = None
    note: Optional[str] = None


class StreamInfo(BaseModel):
    url: str
    formatId: Optional[str] = None
    mimeType: Optional[str] = None
    qualityLabel: Optional[str] = None
    httpHeaders: dict[str, str] = Field(default_factory=dict)
    bitrate: Optional[int] = None
    width: Optional[int] = None
    height: Optional[int] = None
    fps: Optional[int] = None
    audioCodec: Optional[str] = None
    videoCodec: Optional[str] = None
    container: Optional[str] = None
    hasAudio: bool = False
    hasVideo: bool = False
    isAdaptive: bool = False


class CommentItem(BaseModel):
    id: str
    author: str
    avatarUrl: Optional[str] = None
    body: str
    likeCountText: Optional[str] = None
    publishedTimeText: Optional[str] = None
    replyCountText: Optional[str] = None
    pinnedText: Optional[str] = None


class VideoPlayback(BaseModel):
    id: str
    title: Optional[str] = None
    channel: Optional[str] = None
    channelId: Optional[str] = None
    channelAvatarUrl: Optional[str] = None
    subscriberCountText: Optional[str] = None
    viewCountText: Optional[str] = None
    publishedTimeText: Optional[str] = None
    publishedDateText: Optional[str] = None
    likeCountText: Optional[str] = None
    durationText: Optional[str] = None
    description: Optional[str] = None
    commentCountText: Optional[str] = None
    streams: List[StreamInfo] = Field(default_factory=list)
    recommendations: List[VideoItem] = Field(default_factory=list)
    comments: List[CommentItem] = Field(default_factory=list)
    playbackStrategy: str = "direct"
    preferredMuxedStream: Optional[StreamInfo] = None
    preferredVideoStream: Optional[StreamInfo] = None
    preferredAudioStream: Optional[StreamInfo] = None
    bestStreamUrl: Optional[str] = None
    bestStream: Optional[StreamInfo] = None


class AuthStatusResponse(BaseModel):
    authenticated: bool = False
    browser: Optional[str] = None
    browserLabel: Optional[str] = None
    message: Optional[str] = None


class BrowserAuthRequest(BaseModel):
    browser: str
