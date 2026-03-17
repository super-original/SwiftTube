from __future__ import annotations

from copy import deepcopy
import os
from pathlib import Path
import shutil
import subprocess
import threading
from typing import Any, Optional


_BGUTIL_PROVIDER_VERSION = "1.3.1"
_BGUTIL_PROVIDER_REPO_URL = "https://github.com/Brainicism/bgutil-ytdlp-pot-provider.git"
_BGUTIL_PROVIDER_DIR_NAME = f"bgutil-ytdlp-pot-provider-{_BGUTIL_PROVIDER_VERSION}"
_DISABLED_HTTP_PROVIDER_URL = "http://127.0.0.1:65535"
_provider_install_lock = threading.Lock()


def prefetch_provider_install(cookie_file: Optional[str]) -> None:
    threading.Thread(
        target=_prefetch_provider_install,
        args=(cookie_file,),
        daemon=True,
        name="swifttube-bgutil-prefetch",
    ).start()


def build_authenticated_ytdlp_options(auth_options: dict[str, Any]) -> dict[str, Any]:
    opts = deepcopy(auth_options)
    extractor_args = opts.setdefault("extractor_args", {})
    youtube_args = extractor_args.setdefault("youtube", {})
    youtube_args["player_client"] = ["mweb"]

    server_home = ensure_bgutil_provider(opts.get("cookiefile"))
    extractor_args["youtubepot-bgutilscript"] = {"server_home": [str(server_home)]}
    # Point the HTTP provider at a dead local port so yt-dlp immediately uses the script mode.
    extractor_args["youtubepot-bgutilhttp"] = {
        "base_url": [_DISABLED_HTTP_PROVIDER_URL]
    }

    opts["js_runtimes"] = {"node": {}}
    opts["remote_components"] = ["ejs:github"]
    return opts


def ensure_bgutil_provider(cookie_file: Optional[str]) -> Path:
    override = os.environ.get("SWIFTTUBE_BGUTIL_SERVER_HOME")
    if override:
        server_dir = Path(override).expanduser()
        if (server_dir / "build" / "main.js").exists():
            return server_dir
        raise RuntimeError(
            "SWIFTTUBE_BGUTIL_SERVER_HOME is set, but build/main.js was not found there."
        )

    install_root = _support_dir(cookie_file) / "providers"
    repo_dir = install_root / _BGUTIL_PROVIDER_DIR_NAME
    server_dir = repo_dir / "server"
    build_entry = server_dir / "build" / "main.js"

    if build_entry.exists():
        return server_dir

    with _provider_install_lock:
        if build_entry.exists():
            return server_dir

        install_root.mkdir(parents=True, exist_ok=True)
        temp_repo_dir = install_root / f".{_BGUTIL_PROVIDER_DIR_NAME}.tmp"
        shutil.rmtree(temp_repo_dir, ignore_errors=True)

        _require_command("git")
        _require_command("npm")
        _require_command("npx")
        _require_command("node")

        try:
            _run(
                [
                    "git",
                    "clone",
                    "--depth",
                    "1",
                    "--branch",
                    _BGUTIL_PROVIDER_VERSION,
                    _BGUTIL_PROVIDER_REPO_URL,
                    str(temp_repo_dir),
                ]
            )
            _run(
                ["npm", "ci", "--no-audit", "--no-fund"],
                cwd=temp_repo_dir / "server",
            )
            _run(["npx", "tsc"], cwd=temp_repo_dir / "server")

            shutil.rmtree(repo_dir, ignore_errors=True)
            temp_repo_dir.rename(repo_dir)
            _cleanup_old_provider_versions(install_root, keep_name=repo_dir.name)
        except Exception:
            shutil.rmtree(temp_repo_dir, ignore_errors=True)
            raise

    return server_dir


def _prefetch_provider_install(cookie_file: Optional[str]) -> None:
    try:
        ensure_bgutil_provider(cookie_file)
    except Exception:
        pass


def _support_dir(cookie_file: Optional[str]) -> Path:
    if isinstance(cookie_file, str) and cookie_file:
        return Path(cookie_file).expanduser().parent

    env_path = os.environ.get("SWIFTTUBE_APP_SUPPORT_DIR")
    if env_path:
        return Path(env_path).expanduser()

    return Path.home() / "Library" / "Application Support" / "SwiftTube"


def _require_command(name: str) -> None:
    if shutil.which(name) is None:
        raise RuntimeError(f"Missing required command for HQ playback setup: {name}")


def _cleanup_old_provider_versions(install_root: Path, keep_name: str) -> None:
    for entry in install_root.iterdir():
        if (
            entry.is_dir()
            and entry.name.startswith("bgutil-ytdlp-pot-provider-")
            and entry.name != keep_name
        ):
            shutil.rmtree(entry, ignore_errors=True)


def _run(command: list[str], cwd: Optional[Path] = None) -> None:
    result = subprocess.run(
        command,
        cwd=str(cwd) if cwd else None,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    if result.returncode == 0:
        return

    output = (result.stdout or "").strip()
    raise RuntimeError(output or f"Command failed: {' '.join(command)}")
