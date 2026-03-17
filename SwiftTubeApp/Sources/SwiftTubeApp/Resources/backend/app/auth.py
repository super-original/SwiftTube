from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import time
from typing import Optional

import httpx
from innertube import InnerTube, api
from yt_dlp.cookies import YoutubeDLCookieJar, extract_cookies_from_browser


SUPPORTED_BROWSERS = {
    "chrome": "Chrome",
    "safari": "Safari",
}

YOUTUBE_ORIGIN = "https://www.youtube.com"


class _YTDLPLogger:
    def debug(self, message: str) -> None:
        pass

    def info(self, message: str) -> None:
        pass

    def warning(self, message: str) -> None:
        pass

    def error(self, message: str) -> None:
        pass


@dataclass
class AuthSessionConfig:
    browser: str
    browser_label: str


@dataclass
class AuthMaterial:
    config: AuthSessionConfig
    cookie_file: Path
    sapisid: str

    @property
    def browser(self) -> str:
        return self.config.browser

    @property
    def browser_label(self) -> str:
        return self.config.browser_label

    def build_httpx_client(self) -> httpx.Client:
        client = httpx.Client(base_url="https://www.youtube.com/youtubei/v1")
        jar = YoutubeDLCookieJar(str(self.cookie_file))
        jar.load(ignore_discard=True, ignore_expires=True)

        for cookie in jar:
            client.cookies.set(
                cookie.name,
                cookie.value,
                domain=cookie.domain,
                path=cookie.path,
            )

        timestamp = str(int(time.time()))
        auth_hash = hashlib.sha1(
            f"{timestamp} {self.sapisid} {YOUTUBE_ORIGIN}".encode("utf-8")
        ).hexdigest()

        client.headers.update(
            {
                "Authorization": f"SAPISIDHASH {timestamp}_{auth_hash}",
                "Origin": YOUTUBE_ORIGIN,
                "X-Origin": YOUTUBE_ORIGIN,
                "X-Youtube-Bootstrap-Logged-In": "true",
            }
        )

        return client


class BrowserAuthManager:
    def __init__(self) -> None:
        self._support_dir = self._resolve_support_dir()
        self._config_path = self._support_dir / "auth.json"
        self._cookie_path = self._support_dir / "youtube-cookies.txt"
        self._material: Optional[AuthMaterial] = None
        self._config = self._load_config()
        if self._config is not None:
            try:
                self._material = self._material_from_cookie_file(self._config)
            except Exception:
                self.clear()

    @property
    def is_authenticated(self) -> bool:
        return self._material is not None

    def status_payload(self, *, validate: bool = False) -> dict:
        if validate and self._config is not None:
            try:
                self._validate_or_raise()
            except Exception as exc:
                self.clear()
                return {
                    "authenticated": False,
                    "browser": None,
                    "browserLabel": None,
                    "message": str(exc),
                }

        if self._material is None:
            return {
                "authenticated": False,
                "browser": None,
                "browserLabel": None,
                "message": None,
            }

        return {
            "authenticated": True,
            "browser": self._material.browser,
            "browserLabel": self._material.browser_label,
            "message": "Personalized recommendations and authenticated playback are on.",
        }

    def connect_browser(self, browser: str) -> dict:
        browser_key = browser.lower()
        browser_label = SUPPORTED_BROWSERS.get(browser_key)
        if browser_label is None:
            raise ValueError("Unsupported browser. Choose Safari or Chrome.")

        jar = extract_cookies_from_browser(browser_key, logger=_YTDLPLogger())
        jar.filename = str(self._cookie_path)
        jar.save(ignore_discard=True, ignore_expires=True)
        os.chmod(self._cookie_path, 0o600)

        config = AuthSessionConfig(browser=browser_key, browser_label=browser_label)
        material = self._material_from_cookie_file(config)
        self._validate_or_raise(material)

        self._save_config(config)
        self._config = config
        self._material = material
        return self.status_payload()

    def clear(self) -> dict:
        self._material = None
        self._config = None
        if self._config_path.exists():
            self._config_path.unlink()
        if self._cookie_path.exists():
            self._cookie_path.unlink()
        return self.status_payload()

    def build_client(self, client_name: str) -> InnerTube:
        client = InnerTube(client_name)
        if self._material is not None:
            client.adaptor.session = self._material.build_httpx_client()
        return client

    def playback_options(self) -> Optional[dict]:
        if self._material is None:
            return None
        return {
            "cookiefile": str(self._cookie_path),
            "extractor_args": {"youtube": {"player_client": ["web_safari"]}},
        }

    def _validate_or_raise(self, material: Optional[AuthMaterial] = None) -> None:
        material = material or self._material
        if material is None:
            raise ValueError("No YouTube session is connected.")

        client = InnerTube("WEB")
        client.adaptor.session = material.build_httpx_client()
        data = client.adaptor.dispatch("/browse", body={"browseId": "FEwhat_to_watch"})
        response_context = api.get_response_context(data)
        if response_context is None or response_context.flags.logged_in is not True:
            raise ValueError(
                "SwiftTube could read the browser cookies, but YouTube did not accept them as a signed-in session."
            )

    def _material_from_cookie_file(self, config: AuthSessionConfig) -> AuthMaterial:
        if not self._cookie_path.exists():
            raise ValueError("The saved YouTube cookie file is missing.")

        jar = YoutubeDLCookieJar(str(self._cookie_path))
        jar.load(ignore_discard=True, ignore_expires=True)

        sapisid = None
        for cookie in jar:
            if cookie.name == "SAPISID" and "youtube" in cookie.domain:
                sapisid = cookie.value
                break
        if sapisid is None:
            for cookie in jar:
                if cookie.name == "SAPISID" and "google" in cookie.domain:
                    sapisid = cookie.value
                    break

        if not sapisid:
            raise ValueError(
                "Your browser session is missing the SAPISID cookie needed for authenticated YouTube requests."
            )

        return AuthMaterial(config=config, cookie_file=self._cookie_path, sapisid=sapisid)

    def _resolve_support_dir(self) -> Path:
        if env_path := os.environ.get("SWIFTTUBE_APP_SUPPORT_DIR"):
            support_dir = Path(env_path)
        else:
            support_dir = Path.home() / "Library" / "Application Support" / "SwiftTube"
        support_dir.mkdir(parents=True, exist_ok=True)
        return support_dir

    def _load_config(self) -> Optional[AuthSessionConfig]:
        if not self._config_path.exists():
            return None
        try:
            payload = json.loads(self._config_path.read_text())
        except Exception:
            return None

        browser = payload.get("browser")
        browser_label = payload.get("browserLabel")
        if not isinstance(browser, str) or not isinstance(browser_label, str):
            return None
        return AuthSessionConfig(browser=browser, browser_label=browser_label)

    def _save_config(self, config: AuthSessionConfig) -> None:
        self._config_path.write_text(
            json.dumps(
                {
                    "browser": config.browser,
                    "browserLabel": config.browser_label,
                },
                indent=2,
            )
        )
