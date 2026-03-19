from __future__ import annotations

from copy import deepcopy
import os
from pathlib import Path
import re
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
    # The "actual" JS variant avoids the broken TV-player challenge path that
    # was collapsing authenticated extraction down to image-only results.
    youtube_args["player_js_variant"] = ["actual"]

    server_home = ensure_bgutil_provider(opts.get("cookiefile"))
    node_path = _resolve_command_path("node")
    extractor_args["youtubepot-bgutilscript"] = {"server_home": [str(server_home)]}
    # Point the HTTP provider at a dead local port so yt-dlp immediately uses the script mode.
    extractor_args["youtubepot-bgutilhttp"] = {
        "base_url": [_DISABLED_HTTP_PROVIDER_URL]
    }

    opts["js_runtimes"] = {"node": {"path": node_path}}
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

        git_path = _resolve_command_path("git")
        npm_path = _resolve_command_path("npm")
        npx_path = _resolve_command_path("npx")
        _ = _resolve_command_path("node")

        try:
            _run(
                [
                    git_path,
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
                [npm_path, "ci", "--no-audit", "--no-fund"],
                cwd=temp_repo_dir / "server",
            )
            _run([npx_path, "tsc"], cwd=temp_repo_dir / "server")

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


def _resolve_command_path(name: str) -> str:
    env_overrides = {
        "git": "SWIFTTUBE_GIT_PATH",
        "node": "SWIFTTUBE_NODE_PATH",
        "npm": "SWIFTTUBE_NPM_PATH",
        "npx": "SWIFTTUBE_NPX_PATH",
    }
    if override_name := env_overrides.get(name):
        override = os.environ.get(override_name)
        if override and Path(override).expanduser().is_file():
            return str(Path(override).expanduser())

    if found := shutil.which(name):
        return found

    common_candidates = {
        "git": [
            "/usr/bin/git",
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
        ],
        "node": [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            *[str(path) for path in _nvm_binaries("node")],
        ],
        "npm": [
            "/opt/homebrew/bin/npm",
            "/usr/local/bin/npm",
            *[str(path) for path in _nvm_binaries("npm")],
        ],
        "npx": [
            "/opt/homebrew/bin/npx",
            "/usr/local/bin/npx",
            *[str(path) for path in _nvm_binaries("npx")],
        ],
    }
    for candidate in common_candidates.get(name, []):
        if Path(candidate).is_file():
            return candidate

    raise RuntimeError(f"Missing required command for HQ playback setup: {name}")


def _nvm_binaries(name: str) -> list[Path]:
    versions_root = Path.home() / ".nvm" / "versions" / "node"
    if not versions_root.exists():
        return []

    candidates: list[tuple[tuple[int, ...], Path]] = []
    for binary in versions_root.glob(f"*/bin/{name}"):
        version_name = binary.parent.parent.name
        version_tuple = _parse_semver(version_name)
        candidates.append((version_tuple, binary))

    return [path for _, path in sorted(candidates, reverse=True)]


def _parse_semver(value: str) -> tuple[int, ...]:
    match = re.findall(r"\d+", value)
    if not match:
        return (0,)
    return tuple(int(part) for part in match)


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
