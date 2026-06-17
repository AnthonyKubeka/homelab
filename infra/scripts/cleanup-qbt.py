#!/usr/bin/env python3
from __future__ import annotations

import json
import logging
import os
import sys
import time
from typing import Any

import requests

LOG_LEVEL = os.getenv("QBT_CLEANUP_LOG_LEVEL", "INFO").upper()
logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("qbt-cleanup")


def env_bool(name: str, default: bool = False) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "y", "on"}


def get_env(name: str, default: str | None = None, required: bool = False) -> str:
    value = os.getenv(name, default)
    if required and not value:
        raise RuntimeError(f"Missing required environment variable: {name}")
    return value or ""


def load_config() -> dict[str, Any]:
    categories_raw = get_env("QBT_CLEANUP_CATEGORIES", "radarr,tv-sonarr")
    categories = {c.strip() for c in categories_raw.split(",") if c.strip()}

    return {
        "base_url": get_env("QBT_BASE_URL", "http://127.0.0.1:8080").rstrip("/"),
        "username": get_env("QBT_USERNAME", required=True),
        "password": get_env("QBT_PASSWORD", required=True),
        "categories": categories,
        "age_minutes": int(get_env("QBT_CLEANUP_AGE_MINUTES", "60")),
        "dry_run": env_bool("QBT_CLEANUP_DRY_RUN", False),
        "verify_tls": env_bool("QBT_VERIFY_TLS", True),
        "request_timeout_seconds": int(get_env("QBT_REQUEST_TIMEOUT_SECONDS", "15")),
    }


class QBittorrentClient:
    def __init__(self, base_url: str, username: str, password: str, verify_tls: bool, timeout: int) -> None:
        self.base_url = base_url
        self.api = f"{base_url}/api/v2"
        self.session = requests.Session()
        self.session.verify = verify_tls
        self.timeout = timeout
        self._login(username, password)

    def _login(self, username: str, password: str) -> None:
        response = self.session.post(
            f"{self.api}/auth/login",
            data={"username": username, "password": password},
            timeout=self.timeout,
        )
        response.raise_for_status()
        if response.text.strip() != "Ok.":
            raise RuntimeError(f"qBittorrent login failed: {response.text.strip()}")

    def torrents(self) -> list[dict[str, Any]]:
        response = self.session.get(
            f"{self.api}/torrents/info",
            timeout=self.timeout,
        )
        response.raise_for_status()
        return response.json()

    def delete_torrents(self, hashes: list[str], delete_files: bool = True) -> None:
        if not hashes:
            return
        response = self.session.post(
            f"{self.api}/torrents/delete",
            data={
                "hashes": "|".join(hashes),
                "deleteFiles": "true" if delete_files else "false",
            },
            timeout=self.timeout,
        )
        response.raise_for_status()


def torrent_completed_epoch(torrent: dict[str, Any]) -> int | None:
    """
    qBittorrent usually exposes completion_on as a unix timestamp.
    If unavailable or 0/-1, fall back to added_on.
    """
    for key in ("completion_on", "completed_time", "completion_date"):
        value = torrent.get(key)
        if isinstance(value, int) and value > 0:
            return value

    added_on = torrent.get("added_on")
    if isinstance(added_on, int) and added_on > 0:
        return added_on

    return None


def is_completed(torrent: dict[str, Any]) -> bool:
    progress = torrent.get("progress", 0)
    amount_left = torrent.get("amount_left", 1)
    state = str(torrent.get("state", ""))

    if progress >= 1.0:
        return True

    if amount_left == 0 and state:
        return True

    return False


def format_torrent(torrent: dict[str, Any]) -> str:
    name = torrent.get("name", "<unknown>")
    category = torrent.get("category", "")
    ratio = torrent.get("ratio", 0)
    state = torrent.get("state", "")
    save_path = torrent.get("save_path", "")
    return f"name={name!r} category={category!r} state={state!r} ratio={ratio} save_path={save_path!r}"


def main() -> int:
    try:
        config = load_config()
        client = QBittorrentClient(
            base_url=config["base_url"],
            username=config["username"],
            password=config["password"],
            verify_tls=config["verify_tls"],
            timeout=config["request_timeout_seconds"],
        )
    except Exception as exc:
        log.error("Startup failed: %s", exc)
        return 1

    now = int(time.time())
    min_age_seconds = config["age_minutes"] * 60

    try:
        torrents = client.torrents()
    except Exception as exc:
        log.error("Failed to fetch torrents: %s", exc)
        return 1

    log.info("Fetched %s torrents from qBittorrent", len(torrents))

    candidates: list[dict[str, Any]] = []
    for torrent in torrents:
        category = str(torrent.get("category", "")).strip()
        if category not in config["categories"]:
            continue

        if not is_completed(torrent):
            continue

        completed_epoch = torrent_completed_epoch(torrent)
        if not completed_epoch:
            log.warning("Skipping completed torrent with unknown completion time: %s", format_torrent(torrent))
            continue

        age_seconds = now - completed_epoch
        if age_seconds < min_age_seconds:
            continue

        candidates.append(torrent)

    if not candidates:
        log.info("No torrents matched cleanup rules")
        return 0

    log.info("Matched %s torrents for cleanup", len(candidates))
    for torrent in candidates:
        completed_epoch = torrent_completed_epoch(torrent) or 0
        age_minutes = (now - completed_epoch) // 60
        log.info("Candidate age=%sm %s", age_minutes, format_torrent(torrent))

    hashes = [str(t["hash"]) for t in candidates if t.get("hash")]

    if config["dry_run"]:
        log.info("Dry-run enabled, not deleting anything")
        return 0

    try:
        client.delete_torrents(hashes=hashes, delete_files=True)
        log.info("Deleted %s torrents and files", len(hashes))
    except Exception as exc:
        log.error("Failed to delete torrents: %s", exc)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())