# /// script
# requires-python = ">=3.12"
# dependencies = [
#     "starlette>=0.40,<1.0",
#     "uvicorn>=0.30,<1.0",
# ]
# ///
"""ElevenLabs V3 TTS HTTP Daemon for Claude Code.

Standalone Starlette+Uvicorn server replacing the MCP server.
Provides REST API for TTS with audio queuing, multi-voice dialogue,
channel-based queue management, pause/resume, and playback history.

Dashboard at http://127.0.0.1:7865

Endpoints:
  POST /speak              Single voice TTS
  POST /speak/dialogue     Multi-voice dialogue
  GET  /queue              Queue status
  POST /queue/clear        Clear queue
  POST /queue/skip         Skip current
  POST /queue/pause        Pause playback
  POST /queue/resume       Resume playback
  GET  /history            Playback history
  POST /history/replay     Replay from cache
  GET  /voices             Voice configuration
  GET  /events             SSE stream
  GET  /health             Health check
  GET  /                   Friendly help message (use the menubar app or say.sh CLI)
  GET  /portraits/{name}   Caldwell portrait images (used by the menubar app)
"""

import asyncio
import collections
import hashlib
import json
import logging
import os

log = logging.getLogger("voice-daemon")
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from starlette.applications import Starlette
from starlette.middleware import Middleware
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request as StarletteRequest
from starlette.responses import FileResponse, JSONResponse, StreamingResponse
from starlette.routing import Route
import uvicorn

def _is_local_origin(origin: str) -> bool:
    if not origin:
        return True  # No Origin header = non-browser (curl, etc.)
    if origin == "null":
        return False  # Sandboxed iframes send "null" — reject
    origin = origin.rstrip("/")
    for prefix in ("http://127.0.0.1", "http://localhost", "http://[::1]"):
        if origin == prefix or origin.startswith(prefix + ":"):
            return True
    return False


class LocalhostGuardMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request, call_next):
        if request.method == "POST":
            origin = request.headers.get("origin", "")
            if origin and not _is_local_origin(origin):
                return JSONResponse({"error": "Forbidden origin"}, status_code=403)
        return await call_next(request)

# --- Config ---

REPO_ROOT = Path(__file__).resolve().parent.parent

API_BASE = "https://api.elevenlabs.io/v1"
DEFAULT_MODEL = "eleven_v3"
DEFAULT_FORMAT = "mp3_44100_128"
TEMP_PREFIX = "claude-tts-"
PORTRAITS_DIR = REPO_ROOT / "assets" / "portraits"
FFMPEG = (
    shutil.which("ffmpeg")
    or next((p for p in ("/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg") if Path(p).exists()), "ffmpeg")
)


CONFIG_PATH = REPO_ROOT / "config.json"
# config.json now holds non-secret config only (voice_id). The API key
# lives in macOS Keychain.
CONFIG_KEYS = ("ELEVENLABS_VOICE_ID", "CALDWELL_EXPLETIVES", "CALDWELL_MUTED")


def _expletives_enabled() -> bool:
    """Persona-mode toggle. Default True (Potty Mouth). Set false to put
    Caldwell in Polite mode — butler-formal RP, no expletives, no rough
    language. Persisted in config.json as '1' or '0'."""
    return os.environ.get("CALDWELL_EXPLETIVES", "1").strip().lower() not in ("0", "false", "no", "off", "")


def _muted() -> bool:
    """Hard mute — when true, /speak refuses to enqueue and never hits
    ElevenLabs. Useful when Sir is AFK and doesn't want background TTS
    burning credits. Persisted in config.json so daemon restart keeps
    the muted state."""
    return os.environ.get("CALDWELL_MUTED", "0").strip().lower() in ("1", "true", "yes", "on")

KEYCHAIN_SERVICE = "caldwell-speak"
KEYCHAIN_ACCOUNT_API_KEY = "elevenlabs-api-key"


def _keychain_get(service: str, account: str) -> str:
    try:
        result = subprocess.run(
            ["security", "find-generic-password", "-s", service, "-a", account, "-w"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0:
            return result.stdout.rstrip("\n")
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        pass
    return ""


def _keychain_set(service: str, account: str, value: str) -> bool:
    try:
        result = subprocess.run(
            ["security", "add-generic-password",
             "-s", service, "-a", account, "-w", value, "-U"],
            capture_output=True, text=True, timeout=5,
        )
        return result.returncode == 0
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return False


def _keychain_delete(service: str, account: str) -> bool:
    try:
        result = subprocess.run(
            ["security", "delete-generic-password", "-s", service, "-a", account],
            capture_output=True, text=True, timeout=5,
        )
        return result.returncode == 0
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return False


def _migrate_api_key_to_keychain() -> str:
    """One-time migration: if config.json has an API key, push it to
    Keychain and clear it from config.json. Returns migrated key, or ""
    if no migration was needed."""
    if not CONFIG_PATH.exists():
        return ""
    try:
        data = json.loads(CONFIG_PATH.read_text())
    except (json.JSONDecodeError, OSError):
        return ""
    if not isinstance(data, dict):
        return ""
    config_key = data.get("ELEVENLABS_API_KEY")
    if not (isinstance(config_key, str) and config_key):
        return ""

    if _keychain_get(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT_API_KEY):
        # Keychain already has its own value — just clean stale config entry
        data.pop("ELEVENLABS_API_KEY", None)
        try:
            tmp = CONFIG_PATH.with_suffix(".json.tmp")
            tmp.write_text(json.dumps(data, indent=2) + "\n")
            tmp.replace(CONFIG_PATH)
            log.info("Removed deprecated ELEVENLABS_API_KEY from config.json (Keychain has it).")
        except OSError as e:
            log.warning(f"Could not clean deprecated key from config.json: {e}")
        return ""

    if _keychain_set(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT_API_KEY, config_key):
        data.pop("ELEVENLABS_API_KEY", None)
        try:
            tmp = CONFIG_PATH.with_suffix(".json.tmp")
            tmp.write_text(json.dumps(data, indent=2) + "\n")
            tmp.replace(CONFIG_PATH)
            log.warning("Migrated ELEVENLABS_API_KEY from config.json to macOS Keychain.")
        except OSError as e:
            log.warning(f"Migrated key but could not clean config.json: {e}")
        return config_key

    log.warning("Could not migrate API key to Keychain; leaving in config.json")
    return ""


def _load_keychain_into_env():
    """Populate ELEVENLABS_API_KEY from Keychain if no real env var is set."""
    if os.environ.get("ELEVENLABS_API_KEY"):
        return
    key = _keychain_get(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT_API_KEY)
    if key:
        os.environ["ELEVENLABS_API_KEY"] = key


def _load_config_json():
    """UI-managed non-secret config (voice_id). Loaded before .env so
    it overrides dev defaults, but real env vars still win."""
    if not CONFIG_PATH.exists():
        return
    try:
        data = json.loads(CONFIG_PATH.read_text())
    except (json.JSONDecodeError, OSError) as e:
        log.warning(f"Failed to load config.json: {e}")
        return
    if not isinstance(data, dict):
        return
    for key in CONFIG_KEYS:
        value = data.get(key)
        if isinstance(value, str) and value:
            os.environ.setdefault(key, value)


def _save_config_json(updates: dict[str, str]):
    """Atomic write. Merges with existing config; only persists CONFIG_KEYS
    (i.e. non-secret values). API keys go to Keychain via _keychain_set."""
    existing: dict = {}
    if CONFIG_PATH.exists():
        try:
            loaded = json.loads(CONFIG_PATH.read_text())
            if isinstance(loaded, dict):
                existing = loaded
        except (json.JSONDecodeError, OSError):
            pass
    for key in CONFIG_KEYS:
        if key in updates:
            existing[key] = updates[key]
    tmp = CONFIG_PATH.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(existing, indent=2) + "\n")
    tmp.replace(CONFIG_PATH)


def _load_dotenv():
    env_path = REPO_ROOT / ".env"
    if not env_path.exists():
        return
    for line in env_path.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if not line or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip().strip("\"'")
        os.environ.setdefault(key, value)


# Priority for ELEVENLABS_API_KEY: real env > Keychain > .env
# Priority for ELEVENLABS_VOICE_ID: real env > config.json > .env
_load_keychain_into_env()       # Pull API key from Keychain if env not set
_migrate_api_key_to_keychain()  # One-time: move from config.json to Keychain
_load_keychain_into_env()       # If migration just happened, env may need refresh
_load_config_json()             # Voice ID and any future non-secret keys
_load_dotenv()                  # Dev-time fallback for everything

DASHBOARD_PORT = int(os.environ.get("SPEAK_PORT", "7865"))
CACHE_DIR = Path(os.environ.get("SPEAK_CACHE_DIR", str(REPO_ROOT / "cache")))

# Spend caps (free-tier protection). Override via env vars or config.json.
RATE_LIMIT_PER_MIN = int(os.environ.get("SPEAK_RATE_LIMIT_PER_MIN", "20"))
DAILY_CHAR_CAP = int(os.environ.get("SPEAK_DAILY_CHAR_CAP", "2000"))
USAGE_LOG_PATH = REPO_ROOT / "logs" / "usage.json"

# Voice generation settings — applied to every TTS request.
# Tuned for Caldwell (Alfred-with-trucker-mouth): low-medium stability for
# expressive variation across formal/blunt/dry registers; medium-high
# similarity to lock to the source voice; medium style to lean into the
# character; speaker boost on for clarity.
VOICE_STABILITY = float(os.environ.get("SPEAK_VOICE_STABILITY", "0.35"))
VOICE_SIMILARITY_BOOST = float(os.environ.get("SPEAK_VOICE_SIMILARITY_BOOST", "0.75"))
VOICE_STYLE = float(os.environ.get("SPEAK_VOICE_STYLE", "0.50"))
VOICE_SPEAKER_BOOST = os.environ.get("SPEAK_VOICE_SPEAKER_BOOST", "1").lower() not in ("0", "false", "no", "")


def _voice_settings() -> dict:
    return {
        "stability": VOICE_STABILITY,
        "similarity_boost": VOICE_SIMILARITY_BOOST,
        "style": VOICE_STYLE,
        "use_speaker_boost": VOICE_SPEAKER_BOOST,
    }


# --- Phrase cache ---
# Content-addressed cache of generated MP3s keyed by (text, voice_id, voice_settings).
# Repeated phrases like "On it Sir." replay from local disk — zero ElevenLabs credits.
PHRASE_CACHE_DIR = CACHE_DIR / "phrases"
PHRASE_CACHE_MAX_BYTES = int(os.environ.get("SPEAK_PHRASE_CACHE_MAX_BYTES", str(100 * 1024 * 1024)))
# Cache writes are gated solely by the explicit cacheable flag — caller (the
# skill) decides reusability based on context, not on length. The previous
# 40-char hard cap was blocking legitimately reusable longer phrases like
# "I'm afraid the tests are failing — log's in the chat."


def _phrase_cache_key(text: str, voice_id: str) -> str:
    payload = json.dumps({
        "text": text,
        "voice_id": voice_id,
        "voice_settings": _voice_settings(),
        "model": DEFAULT_MODEL,
    }, sort_keys=True).encode()
    return hashlib.sha256(payload).hexdigest()[:32]


def _phrase_cache_meta_path(key: str) -> Path:
    return PHRASE_CACHE_DIR / f"{key}.json"


def _phrase_cache_load_meta(key: str) -> dict | None:
    path = _phrase_cache_meta_path(key)
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text())
    except (json.JSONDecodeError, OSError):
        return None


def _phrase_cache_save_meta(key: str, meta: dict):
    path = _phrase_cache_meta_path(key)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(meta))
    except OSError as e:
        log.warning(f"Phrase cache meta save failed: {e}")


def _phrase_cache_get(text: str, voice_id: str) -> str | None:
    key = _phrase_cache_key(text, voice_id)
    path = PHRASE_CACHE_DIR / f"{key}.mp3"
    if path.exists():
        try:
            os.utime(path, None)  # touch atime for LRU
        except OSError:
            pass
        # Bump play_count + last_played_at on the sidecar (best-effort)
        meta = _phrase_cache_load_meta(key) or {
            "key": key,
            "text": "",
            "voice_id": voice_id,
            "voice_label": "",
            "first_cached_at": time.time(),
            "play_count": 0,
            "char_count": len(text),
        }
        meta["play_count"] = int(meta.get("play_count", 0)) + 1
        meta["last_played_at"] = time.time()
        # Backfill text on hit if it was missing (legacy entry)
        if not meta.get("text"):
            meta["text"] = text
            meta["char_count"] = len(text)
        if not meta.get("voice_label"):
            meta["voice_label"] = voice_label(voice_id)
        _phrase_cache_save_meta(key, meta)
        return str(path)
    return None


def _phrase_cache_put(text: str, voice_id: str, source_path: str):
    key = _phrase_cache_key(text, voice_id)
    path = PHRASE_CACHE_DIR / f"{key}.mp3"
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source_path, str(path))
    except OSError as e:
        log.warning(f"Phrase cache put failed: {e}")
        return
    now = time.time()
    meta = {
        "key": key,
        "text": text,
        "voice_id": voice_id,
        "voice_label": voice_label(voice_id),
        "first_cached_at": now,
        "last_played_at": now,
        "play_count": 1,
        "char_count": len(text),
    }
    _phrase_cache_save_meta(key, meta)


def _phrase_cache_list() -> list[dict]:
    """Return all cached phrases with metadata. Legacy entries (mp3
    without sidecar) get a stub record so they remain visible/playable."""
    if not PHRASE_CACHE_DIR.exists():
        return []
    items: list[dict] = []
    for p in PHRASE_CACHE_DIR.iterdir():
        if not p.is_file() or p.suffix != ".mp3":
            continue
        key = p.stem
        try:
            stat = p.stat()
        except OSError:
            continue
        meta = _phrase_cache_load_meta(key)
        if meta is None:
            meta = {
                "key": key,
                "text": "",
                "voice_id": "",
                "voice_label": "",
                "first_cached_at": stat.st_mtime,
                "last_played_at": stat.st_atime,
                "play_count": 0,
                "char_count": 0,
            }
        meta["size_bytes"] = stat.st_size
        items.append(meta)
    items.sort(key=lambda m: m.get("last_played_at") or 0, reverse=True)
    return items


def _prune_phrase_cache():
    if not PHRASE_CACHE_DIR.exists():
        return
    files: list = []
    total = 0
    for p2 in PHRASE_CACHE_DIR.iterdir():
        if p2.is_file() and p2.suffix == ".mp3":
            try:
                stat = p2.stat()
                files.append((stat.st_atime, stat.st_size, p2))
                total += stat.st_size
            except OSError:
                pass
    if total <= PHRASE_CACHE_MAX_BYTES:
        return
    files.sort()
    while total > PHRASE_CACHE_MAX_BYTES and files:
        _, size, p2 = files.pop(0)
        try:
            p2.unlink()
            total -= size
            # Also remove the sidecar
            sidecar = _phrase_cache_meta_path(p2.stem)
            if sidecar.exists():
                sidecar.unlink()
        except OSError:
            pass


def _load_voices() -> tuple[dict[str, str], dict[str, str]]:
    voices_path = REPO_ROOT / "voices.json"
    roster: dict[str, str] = {}
    by_name: dict[str, str] = {}
    if voices_path.exists():
        try:
            entries = json.loads(voices_path.read_text())
            if not isinstance(entries, list):
                log.warning("voices.json is not a list")
                return roster, by_name
            for entry in entries:
                if not isinstance(entry, dict):
                    continue
                name = entry.get("name")
                vid = entry.get("id")
                if not isinstance(name, str) or not isinstance(vid, str):
                    continue
                roster[vid] = name
                by_name[name.lower()] = vid
        except (json.JSONDecodeError, KeyError) as e:
            log.warning(f"Failed to load voices.json: {e}")
    return roster, by_name


VOICE_ROSTER, VOICE_BY_NAME = _load_voices()


# --- Spend Cap Tracker ---

class QuotaTracker:
    """Tracks per-minute call rate and per-day character usage. In-memory
    rate limit (60s window); daily char count persisted to logs/usage.json
    so daemon restart doesn't reset the cap mid-day."""

    def __init__(self):
        self._call_times: collections.deque[float] = collections.deque(maxlen=1000)
        self._daily_chars: int = 0
        self._daily_date: str = ""
        self._load()

    def _today(self) -> str:
        return time.strftime("%Y-%m-%d")

    def _load(self):
        try:
            if USAGE_LOG_PATH.exists():
                data = json.loads(USAGE_LOG_PATH.read_text())
                if isinstance(data, dict):
                    self._daily_date = data.get("date", "")
                    self._daily_chars = int(data.get("chars", 0))
        except (json.JSONDecodeError, OSError, ValueError) as e:
            log.warning(f"Failed to load usage log: {e}")
        if self._daily_date != self._today():
            self._daily_date = self._today()
            self._daily_chars = 0

    def _save(self):
        try:
            USAGE_LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
            tmp = USAGE_LOG_PATH.with_suffix(".json.tmp")
            tmp.write_text(json.dumps({
                "date": self._daily_date,
                "chars": self._daily_chars,
            }))
            tmp.replace(USAGE_LOG_PATH)
        except OSError as e:
            log.warning(f"Failed to save usage log: {e}")

    def _prune_calls(self, now: float):
        cutoff = now - 60.0
        while self._call_times and self._call_times[0] < cutoff:
            self._call_times.popleft()

    def _roll_day_if_needed(self):
        today = self._today()
        if today != self._daily_date:
            self._daily_date = today
            self._daily_chars = 0
            self._save()

    def check(self, text_len: int) -> tuple[bool, str]:
        """Returns (allowed, error_message). Does NOT increment."""
        now = time.time()
        self._prune_calls(now)
        self._roll_day_if_needed()
        if RATE_LIMIT_PER_MIN > 0 and len(self._call_times) >= RATE_LIMIT_PER_MIN:
            return False, f"Rate limit: {RATE_LIMIT_PER_MIN} calls/minute exceeded"
        if DAILY_CHAR_CAP > 0 and (self._daily_chars + text_len) > DAILY_CHAR_CAP:
            remaining = max(0, DAILY_CHAR_CAP - self._daily_chars)
            return False, f"Daily character cap reached ({self._daily_chars}/{DAILY_CHAR_CAP}, {remaining} left). Resets at midnight."
        return True, ""

    def increment(self, text_len: int):
        now = time.time()
        self._call_times.append(now)
        self._roll_day_if_needed()
        self._daily_chars += text_len
        self._save()

    def status(self) -> dict:
        now = time.time()
        self._prune_calls(now)
        self._roll_day_if_needed()
        return {
            "minute_calls": len(self._call_times),
            "minute_limit": RATE_LIMIT_PER_MIN,
            "daily_chars": self._daily_chars,
            "daily_cap": DAILY_CHAR_CAP,
            "daily_date": self._daily_date,
            "limits_active": RATE_LIMIT_PER_MIN > 0 or DAILY_CHAR_CAP > 0,
        }


QUOTA = QuotaTracker()

_api_voices_cache: dict[str, str] | None = None

# ElevenLabs subscription cache — pulled from /v1/user, TTL 5 min.
# Source of truth for tier name + monthly character allowance + actual
# usage counter (ElevenLabs tracks it server-side; we just read it).
_eleven_subscription_cache: dict | None = None
_eleven_subscription_cache_at: float = 0.0
ELEVEN_SUBSCRIPTION_CACHE_TTL = 300  # seconds


def _fetch_elevenlabs_subscription() -> dict | None:
    """Blocking — must be run via asyncio.to_thread. Returns dict with
    tier, character_count, character_limit, next_reset_unix, fetched_at,
    or None on failure (network, no API key, parse error)."""
    global _eleven_subscription_cache, _eleven_subscription_cache_at

    now = time.time()
    if _eleven_subscription_cache and (now - _eleven_subscription_cache_at) < ELEVEN_SUBSCRIPTION_CACHE_TTL:
        return _eleven_subscription_cache

    api_key = os.environ.get("ELEVENLABS_API_KEY", "")
    if not api_key:
        return None

    try:
        req = Request(f"{API_BASE}/user", headers={"xi-api-key": api_key})
        with urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read())
    except (HTTPError, URLError, json.JSONDecodeError, OSError) as e:
        log.warning(f"Could not fetch ElevenLabs subscription: {e}")
        return None

    subscription = data.get("subscription", {}) if isinstance(data, dict) else {}
    if not isinstance(subscription, dict):
        return None

    # billing_period maps to a billing cycle length in days. Free tier
    # returns "monthly_period" which is rolling 30 days from signup.
    billing_period = str(subscription.get("billing_period", "monthly_period"))
    nominal_period_days = {
        "monthly_period": 30.0,
        "annually_period": 365.0,
        "yearly_period": 365.0,
    }.get(billing_period, 30.0)

    next_reset = int(subscription.get("next_character_count_reset_unix", 0) or 0)
    # User account creation time — character_count starts at 0 at signup,
    # so first-cycle users must anchor period_start to created_at, not to
    # a naive (next_reset − 30) calculation that would land 12+ hours
    # AFTER signup and report bogus 0.0 days_elapsed.
    created_at = int(data.get("created_at", 0) or 0)

    # First cycle = account is younger than one nominal billing period.
    # In that case, the chars accumulated since signup; period_start is
    # created_at and period_days is the actual gap (~30.5 days for free).
    # Otherwise, rolling-30 anchored to next_reset.
    account_age_seconds = (now - created_at) if created_at > 0 else float("inf")
    in_first_cycle = (account_age_seconds < nominal_period_days * 86400) and created_at > 0

    if in_first_cycle:
        period_start = created_at
    elif next_reset > 0:
        period_start = next_reset - int(nominal_period_days * 86400)
    else:
        period_start = 0

    period_days = (
        (next_reset - period_start) / 86400.0
        if (next_reset > 0 and period_start > 0)
        else nominal_period_days
    )

    result = {
        "tier": str(subscription.get("tier", "unknown")),
        "character_count": int(subscription.get("character_count", 0) or 0),
        "character_limit": int(subscription.get("character_limit", 0) or 0),
        "next_reset_unix": next_reset,
        "period_start_unix": period_start,
        "created_at_unix": created_at,
        "billing_period": billing_period,
        "period_days": round(period_days, 2),
        "fetched_at": now,
    }
    _eleven_subscription_cache = result
    _eleven_subscription_cache_at = now
    return result


def _compute_run_rate(subscription: dict) -> dict:
    """Add derived run-rate fields to a subscription dict.

    Period bounds come from the subscription itself (period_start_unix +
    next_reset_unix), not a hardcoded constant — so the math aligns with
    the user's actual ElevenLabs billing cycle anchored at their signup
    date, not "30 days from now".

    Status thresholds (vs expected linear pace through billing period):
      ok       — under 1.0× expected (on or below pace)
      watch    — 1.0-1.2× expected
      warning  — 1.2-1.5× expected
      critical — 1.5×+ expected
      exhausted — at or over 100% of monthly limit
    """
    limit = subscription.get("character_limit", 0) or 0
    used = subscription.get("character_count", 0) or 0
    next_reset = subscription.get("next_reset_unix", 0) or 0
    period_start = subscription.get("period_start_unix", 0) or 0
    period_days = subscription.get("period_days", 30.0) or 30.0

    percent_used = (used / limit * 100.0) if limit > 0 else 0.0

    now = time.time()
    seconds_left = max(0.0, next_reset - now) if next_reset > 0 else 0.0
    days_until_reset = seconds_left / 86400.0

    # Real days elapsed in the current billing cycle, anchored to the
    # actual period_start from ElevenLabs.
    if period_start > 0:
        days_elapsed = max(0.0, (now - period_start) / 86400.0)
    else:
        days_elapsed = max(0.0, period_days - days_until_reset)

    expected_pct = (days_elapsed / period_days * 100.0) if period_days > 0 else 0.0
    run_rate_ratio = (percent_used / expected_pct) if expected_pct > 0 else 0.0

    # Status logic depends on where in the billing period we are.
    # In the first 3 days, days_elapsed is too small for the ratio to be
    # meaningful (any usage produces a misleadingly high number). Fall
    # back to absolute-percent thresholds during this window.
    if percent_used >= 100.0:
        status = "exhausted"
    elif days_elapsed < 3.0:
        # Early-period: judge by absolute usage, not run-rate
        if percent_used >= 50.0:
            status = "critical"
        elif percent_used >= 25.0:
            status = "warning"
        elif percent_used >= 15.0:
            status = "watch"
        else:
            status = "ok"
    else:
        # Normal run-rate-based status
        if run_rate_ratio >= 1.5:
            status = "critical"
        elif run_rate_ratio >= 1.2:
            status = "warning"
        elif run_rate_ratio >= 1.0:
            status = "watch"
        else:
            status = "ok"

    return {
        **subscription,
        "percent_used": round(percent_used, 1),
        "days_until_reset": round(days_until_reset, 1),
        "days_elapsed": round(days_elapsed, 1),
        "expected_usage_pct": round(expected_pct, 1),
        "run_rate_ratio": round(run_rate_ratio, 2),
        "run_rate_status": status,
    }


def _fetch_voices_from_api() -> dict[str, str]:
    """Blocking call — must be run via asyncio.to_thread from async context."""
    global _api_voices_cache
    if _api_voices_cache is not None:
        return _api_voices_cache
    _api_voices_cache = {}
    key = _api_key()
    if not key:
        return _api_voices_cache
    try:
        req = Request(f"{API_BASE}/voices", headers={"xi-api-key": key})
        with urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read())
        for v in data.get("voices", []):
            name = v.get("name")
            vid = v.get("voice_id")
            if isinstance(name, str) and isinstance(vid, str):
                _api_voices_cache[name.lower()] = vid
    except Exception as e:
        log.warning(f"Failed to fetch voices from API: {e}")
    return _api_voices_cache


def resolve_voice(voice: str | None) -> str:
    if not voice:
        return os.environ.get("ELEVENLABS_VOICE_ID", "")
    if voice.lower() in VOICE_BY_NAME:
        return VOICE_BY_NAME[voice.lower()]
    if _api_voices_cache is not None and voice.lower() in _api_voices_cache:
        return _api_voices_cache[voice.lower()]
    return voice


async def resolve_voice_async(voice: str | None) -> str:
    if not voice:
        return os.environ.get("ELEVENLABS_VOICE_ID", "")
    if voice.lower() in VOICE_BY_NAME:
        return VOICE_BY_NAME[voice.lower()]
    api_voices = await asyncio.to_thread(_fetch_voices_from_api)
    if voice.lower() in api_voices:
        return api_voices[voice.lower()]
    return voice


def voice_label(voice_id: str) -> str:
    return VOICE_ROSTER.get(voice_id, voice_id[:12])


# --- SSE Broadcaster ---

MAX_SSE_QUEUE = 256
MAX_TEXT_LENGTH = 10000
MAX_HISTORY = 1000


class SSEBroadcaster:
    def __init__(self):
        self._clients: list[asyncio.Queue] = []

    def subscribe(self) -> asyncio.Queue:
        q: asyncio.Queue = asyncio.Queue(maxsize=MAX_SSE_QUEUE)
        self._clients.append(q)
        return q

    def unsubscribe(self, q: asyncio.Queue):
        try:
            self._clients.remove(q)
        except ValueError:
            pass

    async def send(self, event: str, data: dict):
        msg = f"event: {event}\ndata: {json.dumps(data)}\n\n"
        dead: list[asyncio.Queue] = []
        for q in list(self._clients):
            try:
                q.put_nowait(msg)
            except asyncio.QueueFull:
                dead.append(q)
        for q in dead:
            try:
                self._clients.remove(q)
            except ValueError:
                pass


# --- Audio Duration ---

def _get_audio_duration(path: str) -> float | None:
    try:
        result = subprocess.run(
            ["afinfo", path],
            capture_output=True, text=True, timeout=5,
        )
        m = re.search(r"estimated duration:\s*([\d.]+)", result.stdout)
        if m:
            return float(m.group(1))
    except Exception:
        pass
    return None


def _extract_envelope(path: str, chunk_ms: int = 50) -> list[float]:
    try:
        result = subprocess.run(
            [FFMPEG, "-i", path, "-f", "s16le", "-ac", "1", "-ar", "16000",
             "-acodec", "pcm_s16le", "-loglevel", "error", "-"],
            capture_output=True, timeout=30,
        )
        raw = result.stdout
    except Exception:
        return []
    if not raw:
        return []
    samples_per_chunk = 16000 * chunk_ms // 1000
    bytes_per_chunk = samples_per_chunk * 2
    envelope = []
    for i in range(0, len(raw) - 1, bytes_per_chunk):
        chunk = raw[i:i + bytes_per_chunk]
        n = len(chunk) // 2
        if n == 0:
            break
        vals = struct.unpack(f'<{n}h', chunk[:n * 2])
        rms = (sum(v * v for v in vals) / n) ** 0.5 / 32768.0
        envelope.append(rms)
    if envelope:
        p95 = sorted(envelope)[int(len(envelope) * 0.95)] or 0.001
        envelope = [round(min(v / p95, 1.0), 3) for v in envelope]
    return envelope


# --- ElevenLabs API (sync, run via asyncio.to_thread) ---

def _api_key() -> str:
    return os.environ.get("ELEVENLABS_API_KEY", "")


def _validate_mp3(data: bytes) -> bool:
    if len(data) < 4:
        return False
    if data[:3] == b"ID3":
        return True
    if len(data) >= 2 and data[0] == 0xFF and (data[1] & 0xE0) == 0xE0:
        return True
    return False


def _fetch_tts(text: str, voice_id: str, retries: int = 2) -> str:
    url = f"{API_BASE}/text-to-speech/{voice_id}?output_format={DEFAULT_FORMAT}"
    payload = json.dumps({
        "text": text,
        "model_id": DEFAULT_MODEL,
        "voice_settings": _voice_settings(),
    }).encode()
    for attempt in range(1 + retries):
        req = Request(url, data=payload, headers={
            "xi-api-key": _api_key(),
            "Content-Type": "application/json",
        })
        try:
            with urlopen(req) as resp:
                content_type = resp.headers.get("Content-Type", "")
                data = resp.read()
        except HTTPError as e:
            body = ""
            try:
                body = e.read().decode("utf-8", errors="replace")[:500]
            except Exception:
                pass
            log.error(
                f"TTS attempt {attempt+1}: HTTP {e.code} from {url} | "
                f"key_prefix={_api_key()[:6]} key_suffix={_api_key()[-4:]} | "
                f"model={DEFAULT_MODEL} payload_len={len(payload)} | "
                f"response_body={body}"
            )
            if attempt < retries and e.code >= 500:
                continue
            raise
        if not _validate_mp3(data):
            log.warning(f"TTS attempt {attempt+1}: invalid MP3 (Content-Type={content_type}, {len(data)} bytes)")
            if attempt < retries:
                continue
            raise ValueError(f"API returned invalid audio after {1+retries} attempts")
        break
    fd, path = tempfile.mkstemp(prefix=TEMP_PREFIX, suffix=".mp3")
    with os.fdopen(fd, "wb") as f:
        f.write(data)
    return path


def _fetch_dialogue(inputs: list[dict], retries: int = 2) -> str:
    url = f"{API_BASE}/text-to-dialogue?output_format={DEFAULT_FORMAT}"
    payload = json.dumps({"inputs": inputs, "model_id": DEFAULT_MODEL}).encode()
    for attempt in range(1 + retries):
        req = Request(url, data=payload, headers={
            "xi-api-key": _api_key(),
            "Content-Type": "application/json",
        })
        with urlopen(req) as resp:
            data = resp.read()
        if not _validate_mp3(data):
            log.warning(f"Dialogue attempt {attempt+1}: invalid MP3 ({len(data)} bytes)")
            if attempt < retries:
                continue
            raise ValueError(f"API returned invalid audio after {1+retries} attempts")
        break
    fd, path = tempfile.mkstemp(prefix=TEMP_PREFIX, suffix=".mp3")
    with os.fdopen(fd, "wb") as f:
        f.write(data)
    return path


# --- Audio Queue ---

@dataclass
class QueueEntry:
    id: str
    audio_path: str
    text_preview: str
    voice_label: str
    created_at: float
    entry_type: str = "speak"
    dialogue_segments: list[dict] = field(default_factory=list)
    channel: str | None = None
    priority: bool = False
    history_id: str = ""
    full_text: str = ""
    is_replay: bool = False
    ready: asyncio.Event = field(default_factory=asyncio.Event)
    fetch_failed: bool = False

    def __post_init__(self):
        if not self.history_id:
            self.history_id = self.id
        if self.audio_path:
            self.ready.set()


class AudioQueue:
    def __init__(self, broadcaster: SSEBroadcaster):
        self._deque: collections.deque[QueueEntry] = collections.deque()
        self._has_items = asyncio.Event()
        self._paused_global = False
        self._resume_event = asyncio.Event()
        self._resume_event.set()
        self._paused_channels: set[str] = set()
        self._current: QueueEntry | None = None
        self._process: asyncio.subprocess.Process | None = None
        self._history: list[dict] = []
        self._broadcaster = broadcaster
        self._cache_dir = CACHE_DIR
        self._cache_dir.mkdir(parents=True, exist_ok=True)
        self._pause_requested = False
        self._play_start: float = 0.0
        self._seek_offset: float | None = None

    def start(self):
        asyncio.create_task(self._worker())

    def enqueue(self, entry: QueueEntry) -> int:
        if entry.priority:
            self._deque.appendleft(entry)
        else:
            self._deque.append(entry)
        self._has_items.set()
        return len(self._deque)

    def _pick_next(self) -> QueueEntry | None:
        for i, entry in enumerate(self._deque):
            if entry.channel and entry.channel in self._paused_channels:
                continue
            del self._deque[i]
            return entry
        return None

    async def _trim_audio(self, path: str, offset_seconds: float) -> str:
        fd, tmp = tempfile.mkstemp(prefix=TEMP_PREFIX, suffix=".mp3")
        os.close(fd)
        proc = await asyncio.create_subprocess_exec(
            FFMPEG, "-ss", str(offset_seconds), "-i", path,
            "-acodec", "libmp3lame", "-ab", "128k", "-y", tmp,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
        )
        await proc.wait()
        return tmp

    async def _worker(self):
        while True:
            await self._has_items.wait()

            if self._paused_global:
                await self._resume_event.wait()

            entry = self._pick_next()
            if not entry:
                self._has_items.clear()
                continue

            self._current = entry
            self._seek_offset = None
            duration = None
            play_offset = 0.0
            trimmed_path = None
            play_failed = False

            # Wait for TTS audio to be ready (instant for replays/pre-fetched)
            await entry.ready.wait()
            if entry.fetch_failed:
                log.warning(f"Worker: skipping {entry.id} — TTS fetch failed")
                play_failed = True
                # Jump to finally block
                self._current = None
                self._process = None
                if not self._deque:
                    self._has_items.clear()
                await self._broadcaster.send("voice_active", {
                    "id": None, "voice": None, "type": "idle",
                    "text": None, "duration": None, "segments": None,
                    "queued": len(self._deque),
                    "channel": None, "priority": False,
                })
                if not entry.is_replay:
                    history_entry = {
                        "id": entry.history_id,
                        "voice": entry.voice_label,
                        "text": entry.full_text or entry.text_preview,
                        "channel": entry.channel,
                        "timestamp": entry.created_at,
                        "duration": None,
                        "type": entry.entry_type,
                        "failed": True,
                    }
                    self._history.append(history_entry)
                    await self._broadcaster.send("history_update", history_entry)
                continue

            try:
                duration, envelope = await asyncio.gather(
                    asyncio.to_thread(_get_audio_duration, entry.audio_path),
                    asyncio.to_thread(_extract_envelope, entry.audio_path),
                )

                # Cache MP3 for history replay
                cache_path = self._cache_dir / f"{entry.history_id}.mp3"
                try:
                    await asyncio.to_thread(shutil.copy2, entry.audio_path, str(cache_path))
                except Exception:
                    pass

                if entry.entry_type == "dialogue" and entry.dialogue_segments and duration:
                    total_chars = sum(s.get("chars", 1) for s in entry.dialogue_segments)
                    seg_offset = 0.0
                    for seg in entry.dialogue_segments:
                        seg_dur = (seg.get("chars", 1) / max(total_chars, 1)) * duration
                        seg["start"] = round(seg_offset, 3)
                        seg["end"] = round(seg_offset + seg_dur, 3)
                        seg_offset += seg_dur

                while True:
                    # Determine which file to play
                    if play_offset > 0:
                        trimmed_path = await self._trim_audio(entry.audio_path, play_offset)
                        play_file = trimmed_path
                    else:
                        play_file = entry.audio_path

                    # Get envelope for current play file
                    play_dur, play_env = None, envelope
                    if play_offset > 0:
                        play_dur, play_env = await asyncio.gather(
                            asyncio.to_thread(_get_audio_duration, play_file),
                            asyncio.to_thread(_extract_envelope, play_file),
                        )
                    else:
                        play_dur = duration

                    self._process = await asyncio.create_subprocess_exec(
                        "afplay", play_file,
                        stdout=asyncio.subprocess.DEVNULL,
                        stderr=asyncio.subprocess.DEVNULL,
                    )
                    self._play_start = time.monotonic()

                    voice_event = {
                        "id": entry.id,
                        "voice": entry.voice_label,
                        "type": entry.entry_type,
                        "text": entry.text_preview,
                        "duration": round(play_dur, 3) if play_dur else None,
                        "total_duration": round(duration, 3) if duration else None,
                        "offset": round(play_offset, 3),
                        "segments": entry.dialogue_segments if entry.entry_type == "dialogue" else None,
                        "envelope": play_env,
                        "chunk_ms": 50,
                        "queued": len(self._deque),
                        "channel": entry.channel,
                        "priority": entry.priority,
                    }
                    await self._broadcaster.send("voice_active", voice_event)

                    ret = await self._process.wait()
                    log.info(f"Worker: process exited rc={ret}, pause_requested={self._pause_requested}")

                    if ret != 0 and not self._pause_requested:
                        play_failed = True

                    # Clean up trimmed file
                    if trimmed_path:
                        try:
                            os.unlink(trimmed_path)
                        except OSError:
                            pass
                        trimmed_path = None

                    if self._pause_requested:
                        if self._seek_offset is not None:
                            play_offset = self._seek_offset
                            self._seek_offset = None
                            self._pause_requested = False
                            self._process = None
                            log.info(f"Worker: seek to offset={play_offset:.2f}s")
                            continue
                        elapsed = time.monotonic() - self._play_start
                        play_offset += elapsed
                        self._pause_requested = False
                        self._process = None
                        log.info(f"Worker: paused at offset={play_offset:.2f}s, waiting for resume")
                        await self._resume_event.wait()
                        log.info(f"Worker: resumed, will play from offset={play_offset:.2f}s")
                        continue
                    else:
                        break
            except Exception as exc:
                play_failed = True
                log.error(f"Worker: exception in playback loop: {exc}", exc_info=True)
            finally:
                if trimmed_path:
                    try:
                        os.unlink(trimmed_path)
                    except OSError:
                        pass
                try:
                    os.unlink(entry.audio_path)
                except OSError:
                    pass

                if not entry.is_replay:
                    history_entry = {
                        "id": entry.history_id,
                        "voice": entry.voice_label,
                        "text": entry.full_text or entry.text_preview,
                        "channel": entry.channel,
                        "timestamp": entry.created_at,
                        "duration": round(duration, 3) if duration else None,
                        "type": entry.entry_type,
                        "failed": play_failed,
                    }
                    self._history.append(history_entry)
                    if len(self._history) > MAX_HISTORY:
                        self._history = self._history[-MAX_HISTORY:]

                    await self._broadcaster.send("history_update", history_entry)

                self._current = None
                self._process = None

                if not self._deque:
                    self._has_items.clear()

                await self._broadcaster.send("voice_active", {
                    "id": None, "voice": None, "type": "idle",
                    "text": None, "duration": None, "segments": None,
                    "queued": len(self._deque),
                    "channel": None, "priority": False,
                })

    def status(self, channel: str | None = None) -> dict:
        items = []
        if self._current:
            if channel is None or self._current.channel == channel:
                items.append({
                    "position": 0, "status": "playing",
                    "id": self._current.id,
                    "voice": self._current.voice_label,
                    "text": self._current.text_preview,
                    "channel": self._current.channel,
                    "priority": self._current.priority,
                })

        for i, entry in enumerate(self._deque):
            if channel is not None and entry.channel != channel:
                continue
            status = "queued" if entry.ready.is_set() else "pending"
            items.append({
                "position": i + 1, "status": status,
                "id": entry.id,
                "voice": entry.voice_label,
                "text": entry.text_preview,
                "channel": entry.channel,
                "priority": entry.priority,
            })

        return {
            "playing": self._current is not None,
            "queued": len(self._deque),
            "total": len(items),
            "items": items,
            "paused": self._paused_global,
            "channel_paused": sorted(self._paused_channels),
        }

    async def clear(self, channel: str | None = None) -> int:
        cleared = 0
        if channel is None:
            while self._deque:
                entry = self._deque.popleft()
                entry.fetch_failed = True  # Signal bg fetch to clean up
                if entry.audio_path:
                    try:
                        os.unlink(entry.audio_path)
                    except OSError:
                        pass
                cleared += 1
            if self._process and self._process.returncode is None:
                try:
                    self._process.kill()
                except ProcessLookupError:
                    pass
                cleared += 1
            self._has_items.clear()
        else:
            new_deque = collections.deque()
            for entry in self._deque:
                if entry.channel == channel:
                    try:
                        os.unlink(entry.audio_path)
                    except OSError:
                        pass
                    cleared += 1
                else:
                    new_deque.append(entry)
            self._deque = new_deque
            if not self._deque:
                self._has_items.clear()
        return cleared

    async def skip(self) -> bool:
        if self._process and self._process.returncode is None:
            try:
                self._process.kill()
            except ProcessLookupError:
                pass
            return True
        return False

    def seek(self, offset: float) -> bool:
        if not self._current or not self._process or self._process.returncode is not None:
            return False
        self._seek_offset = offset
        self._pause_requested = True
        try:
            self._process.kill()
        except ProcessLookupError:
            self._pause_requested = False
            self._seek_offset = None
            return False
        return True

    def pause(self, channel: str | None = None):
        if channel is None:
            self._paused_global = True
            self._resume_event.clear()
            if self._process and self._process.returncode is None:
                self._pause_requested = True
                try:
                    self._process.kill()
                    log.info("Pause: killed process, pause_requested=True")
                except ProcessLookupError:
                    log.warning("Pause: process already dead")
                    self._pause_requested = False
            else:
                log.info("Pause: no active process to kill")
        else:
            self._paused_channels.add(channel)

    def resume(self, channel: str | None = None):
        if channel is None:
            self._paused_global = False
            self._resume_event.set()
            log.info("Resume: set resume event")
        else:
            self._paused_channels.discard(channel)

    def get_history(self, limit: int = 50, offset: int = 0, channel: str | None = None) -> list[dict]:
        entries = self._history
        if channel is not None:
            entries = [e for e in entries if e.get("channel") == channel]
        entries = list(reversed(entries))
        return entries[offset:offset + limit]

    def find_history(self, history_id: str) -> dict | None:
        for entry in reversed(self._history):
            if entry["id"] == history_id:
                return entry
        return None


def _clean_old_cache(cache_dir: Path, max_age_hours: int = 24):
    if not cache_dir.exists():
        return
    cutoff = time.time() - max_age_hours * 3600
    for f in cache_dir.iterdir():
        if f.is_file() and f.stat().st_mtime < cutoff:
            try:
                f.unlink()
            except OSError:
                pass


# --- REST API Route Handlers ---

async def handle_speak(request: StarletteRequest) -> JSONResponse:
    queue: AudioQueue = request.app.state.queue
    try:
        body = await request.json()
    except Exception:
        return JSONResponse({"error": "Invalid JSON"}, status_code=400)
    if not isinstance(body, dict):
        return JSONResponse({"error": "Expected JSON object"}, status_code=400)

    text = body.get("text", "")
    if not isinstance(text, str) or not text.strip():
        return JSONResponse({"error": "No text provided"}, status_code=400)
    if len(text) > MAX_TEXT_LENGTH:
        return JSONResponse({"error": f"Text too long (max {MAX_TEXT_LENGTH} chars)"}, status_code=400)

    # Hard mute — refuse before any ElevenLabs work. Returns 200 with a
    # `muted` flag so callers (say.sh, the skill) can distinguish from
    # genuine errors but don't retry.
    if _muted():
        return JSONResponse({
            "muted": True,
            "text_preview": text[:100],
        })

    voice_raw = body.get("voice")
    if voice_raw is not None and not isinstance(voice_raw, str):
        return JSONResponse({"error": "Voice must be a string"}, status_code=400)
    channel = body.get("channel")
    if channel is not None and not isinstance(channel, str):
        return JSONResponse({"error": "Channel must be a string"}, status_code=400)

    # Cache discipline: only generic, reusable phrases get cached. Default
    # false — caller (Caldwell-the-skill) opts in based on judgment about
    # whether the line is likely to recur. No length cap; reusability is
    # contextual, not character-bound.
    cacheable = bool(body.get("cacheable", False))

    # Cache-warming mode: fetch + cache the audio but don't enqueue for
    # playback. Used by scripts/warm-cache.sh during first-time setup so
    # the canonical canon is pre-cached without making first-install a
    # 25-line concert. Implies cacheable=true.
    cache_only = bool(body.get("cache_only", False))
    if cache_only:
        cacheable = True

    # Resolve voice ID before the cache check — it's part of the cache key.
    # Intentionally do NOT gate on api_key or vid yet: cached phrases replay
    # from disk with zero ElevenLabs involvement, so they must succeed even
    # when the API key is absent or the monthly quota is exhausted.
    vid = await resolve_voice_async(voice_raw)

    # Phrase cache check — repeated phrases replay free (no API call, no quota cost).
    # This runs before api_key / vid / quota validation so cached lines always play.
    cache_hit_path = await asyncio.to_thread(_phrase_cache_get, text, vid) if vid else None

    # cache_only short-circuit: if the phrase is already cached, return
    # immediately without enqueueing. If it's a miss, fall through to fetch
    # below but skip the queue entry on the way out.
    if cache_only and cache_hit_path is not None:
        return JSONResponse({
            "cached": True,
            "fresh": False,
            "key": _phrase_cache_key(text, vid),
            "char_count": len(text),
        })

    # From here on we need ElevenLabs — validate credentials and quota.
    # Cache hits bypass this block entirely (they jump to the enqueue path below).
    if cache_hit_path is None:
        if not _api_key():
            return JSONResponse({"error": "ELEVENLABS_API_KEY not set"}, status_code=500)
        if not vid:
            return JSONResponse({"error": "No voice specified and ELEVENLABS_VOICE_ID not set"}, status_code=400)
        ok, err = QUOTA.check(len(text))
        if not ok:
            log.warning(f"Quota refused: {err}")
            await request.app.state.broadcaster.send("quota_blocked", {
                "reason": err,
                **QUOTA.status(),
            })
            return JSONResponse({"error": err, "quota": QUOTA.status()}, status_code=429)
        QUOTA.increment(len(text))

    # cache_only on a miss: synchronously fetch, cache, return — no queue
    if cache_only:
        try:
            path = await asyncio.to_thread(_fetch_tts, text, vid)
            await asyncio.to_thread(_phrase_cache_put, text, vid, path)
            try:
                os.unlink(path)
            except OSError:
                pass
            return JSONResponse({
                "cached": True,
                "fresh": True,
                "key": _phrase_cache_key(text, vid),
                "char_count": len(text),
            })
        except Exception as exc:
            log.error(f"cache_only fetch failed for '{text[:40]}...': {exc}")
            return JSONResponse({"error": str(exc)}, status_code=500)

    entry_id = uuid.uuid4().hex[:8]

    # Cache hit: copy MP3 to a temp file so worker cleanup doesn't delete the cache entry
    audio_path = ""
    if cache_hit_path:
        fd_c, tmp_c = tempfile.mkstemp(prefix=TEMP_PREFIX, suffix=".mp3")
        with os.fdopen(fd_c, "wb") as fc:
            fc.write(Path(cache_hit_path).read_bytes())
        audio_path = tmp_c
        log.info(f"Phrase cache HIT for {entry_id}")

    entry = QueueEntry(
        id=entry_id,
        audio_path=audio_path,
        text_preview=text[:100],
        voice_label=voice_label(vid),
        created_at=time.time(),
        channel=channel or None,
        priority=bool(body.get("priority", False)),
        full_text=text,
    )
    pos = queue.enqueue(entry)

    if cache_hit_path is None:
        async def _fetch_bg():
            try:
                path = await asyncio.to_thread(_fetch_tts, text, vid)
                entry.audio_path = path
                if cacheable:
                    await asyncio.to_thread(_phrase_cache_put, text, vid, path)
            except Exception as exc:
                log.error(f"Background TTS fetch failed for {entry_id}: {exc}")
                entry.fetch_failed = True
            finally:
                entry.ready.set()

        asyncio.create_task(_fetch_bg())

    return JSONResponse({
        "id": entry.id,
        "position": pos,
        "voice": entry.voice_label,
        "text_preview": entry.text_preview,
    })


async def handle_speak_dialogue(request: StarletteRequest) -> JSONResponse:
    queue: AudioQueue = request.app.state.queue
    try:
        body = await request.json()
    except Exception:
        return JSONResponse({"error": "Invalid JSON"}, status_code=400)
    if not isinstance(body, dict):
        return JSONResponse({"error": "Expected JSON object"}, status_code=400)

    dialogue = body.get("dialogue", [])
    if not isinstance(dialogue, list) or not dialogue:
        return JSONResponse({"error": "No dialogue provided"}, status_code=400)
    channel = body.get("channel")
    if channel is not None and not isinstance(channel, str):
        return JSONResponse({"error": "Channel must be a string"}, status_code=400)
    if not _api_key():
        return JSONResponse({"error": "ELEVENLABS_API_KEY not set"}, status_code=500)

    inputs = []
    labels = []
    for i, line in enumerate(dialogue):
        if not isinstance(line, dict):
            return JSONResponse({"error": f"Dialogue item {i} must be an object"}, status_code=400)
        text = line.get("text")
        voice = line.get("voice")
        if not isinstance(text, str) or not text.strip():
            return JSONResponse({"error": f"Dialogue item {i} missing 'text'"}, status_code=400)
        if len(text) > MAX_TEXT_LENGTH:
            return JSONResponse({"error": f"Dialogue item {i} text too long"}, status_code=400)
        if voice is not None and not isinstance(voice, str):
            return JSONResponse({"error": f"Dialogue item {i} voice must be a string"}, status_code=400)
        vid = await resolve_voice_async(voice)
        if not vid:
            return JSONResponse({"error": f"Cannot resolve voice: {voice}"}, status_code=400)
        inputs.append({"voice_id": vid, "text": text})
        labels.append(voice_label(vid))

    # Spend cap check on total dialogue chars
    total_chars = sum(len(line.get("text", "")) for line in dialogue)
    ok, err = QUOTA.check(total_chars)
    if not ok:
        log.warning(f"Quota refused (dialogue): {err}")
        await request.app.state.broadcaster.send("quota_blocked", {
            "reason": err,
            **QUOTA.status(),
        })
        return JSONResponse({"error": err, "quota": QUOTA.status()}, status_code=429)
    QUOTA.increment(total_chars)

    voices_str = " + ".join(sorted(set(labels)))
    preview = " / ".join(f"{l}: \"{t['text'][:25]}\"" for l, t in zip(labels, dialogue))
    full_dialogue = " / ".join(f"{l}: \"{line['text']}\"" for l, line in zip(labels, dialogue))
    segments = [
        {"voice": lbl, "text": line["text"], "chars": len(line["text"])}
        for lbl, line in zip(labels, dialogue)
    ]

    entry_id = uuid.uuid4().hex[:8]
    entry = QueueEntry(
        id=entry_id,
        audio_path="",
        text_preview=preview[:100],
        voice_label=voices_str,
        created_at=time.time(),
        entry_type="dialogue",
        dialogue_segments=segments,
        channel=channel or None,
        priority=bool(body.get("priority", False)),
        full_text=full_dialogue,
    )
    pos = queue.enqueue(entry)

    async def _fetch_bg():
        try:
            path = await asyncio.to_thread(_fetch_dialogue, inputs)
            entry.audio_path = path
        except Exception as exc:
            log.error(f"Background dialogue fetch failed for {entry_id}: {exc}")
            entry.fetch_failed = True
        finally:
            entry.ready.set()

    asyncio.create_task(_fetch_bg())

    return JSONResponse({
        "id": entry.id,
        "position": pos,
        "voices": voices_str,
    })


async def handle_queue_status(request: StarletteRequest) -> JSONResponse:
    queue: AudioQueue = request.app.state.queue
    channel = request.query_params.get("channel")
    return JSONResponse(queue.status(channel=channel))


async def handle_queue_clear(request: StarletteRequest) -> JSONResponse:
    queue: AudioQueue = request.app.state.queue
    try:
        body = await request.json()
        if not isinstance(body, dict):
            body = {}
    except Exception:
        body = {}
    channel = body.get("channel")
    if channel is not None and not isinstance(channel, str):
        return JSONResponse({"error": "Channel must be a string"}, status_code=400)
    n = await queue.clear(channel=channel)
    return JSONResponse({"cleared": n})


async def handle_queue_skip(request: StarletteRequest) -> JSONResponse:
    queue: AudioQueue = request.app.state.queue
    skipped = await queue.skip()
    return JSONResponse({"skipped": skipped})


async def handle_queue_seek(request: StarletteRequest) -> JSONResponse:
    queue: AudioQueue = request.app.state.queue
    try:
        body = await request.json()
    except Exception:
        return JSONResponse({"error": "Invalid JSON"}, status_code=400)
    if not isinstance(body, dict):
        return JSONResponse({"error": "Expected JSON object"}, status_code=400)
    offset = body.get("offset")
    if offset is None:
        return JSONResponse({"error": "No offset provided"}, status_code=400)
    try:
        offset = float(offset)
    except (TypeError, ValueError):
        return JSONResponse({"error": "Invalid offset"}, status_code=400)
    seeked = queue.seek(max(0.0, offset))
    if not seeked:
        return JSONResponse({"error": "Nothing playing to seek"}, status_code=409)
    return JSONResponse({"seeked": True, "offset": offset})


async def handle_queue_pause(request: StarletteRequest) -> JSONResponse:
    queue: AudioQueue = request.app.state.queue
    try:
        body = await request.json()
        if not isinstance(body, dict):
            body = {}
    except Exception:
        body = {}
    channel = body.get("channel")
    if channel is not None and not isinstance(channel, str):
        return JSONResponse({"error": "Channel must be a string"}, status_code=400)
    queue.pause(channel=channel)

    await request.app.state.broadcaster.send("pause_state", {
        "global_paused": queue._paused_global,
        "channel_paused": sorted(queue._paused_channels),
    })
    return JSONResponse({"paused": True, "channel": channel})


async def handle_queue_resume(request: StarletteRequest) -> JSONResponse:
    queue: AudioQueue = request.app.state.queue
    try:
        body = await request.json()
        if not isinstance(body, dict):
            body = {}
    except Exception:
        body = {}
    channel = body.get("channel")
    if channel is not None and not isinstance(channel, str):
        return JSONResponse({"error": "Channel must be a string"}, status_code=400)
    queue.resume(channel=channel)

    await request.app.state.broadcaster.send("pause_state", {
        "global_paused": queue._paused_global,
        "channel_paused": sorted(queue._paused_channels),
    })
    return JSONResponse({"resumed": True, "channel": channel})


async def handle_history(request: StarletteRequest) -> JSONResponse:
    queue: AudioQueue = request.app.state.queue
    try:
        limit = max(1, min(int(request.query_params.get("limit", "50")), 500))
    except (ValueError, TypeError):
        limit = 50
    try:
        offset = max(0, int(request.query_params.get("offset", "0")))
    except (ValueError, TypeError):
        offset = 0
    channel = request.query_params.get("channel")
    entries = queue.get_history(limit=limit, offset=offset, channel=channel)
    return JSONResponse({"entries": entries, "total": len(queue._history)})


async def handle_history_replay(request: StarletteRequest) -> JSONResponse:
    queue: AudioQueue = request.app.state.queue
    try:
        body = await request.json()
    except Exception:
        return JSONResponse({"error": "Invalid JSON"}, status_code=400)
    if not isinstance(body, dict):
        return JSONResponse({"error": "Expected JSON object"}, status_code=400)

    history_id = body.get("id", "")
    if not isinstance(history_id, str) or not history_id:
        return JSONResponse({"error": "No id provided"}, status_code=400)

    entry_data = queue.find_history(history_id)
    if not entry_data:
        return JSONResponse({"error": "Entry not found in history"}, status_code=404)

    cache_path = queue._cache_dir / f"{history_id}.mp3"
    if not cache_path.exists():
        return JSONResponse({"error": "Cached audio not found (may have expired)"}, status_code=404)

    # Copy cached MP3 to temp file for playback (worker deletes after play)
    fd, tmp_path = tempfile.mkstemp(prefix=TEMP_PREFIX, suffix=".mp3")
    with os.fdopen(fd, "wb") as f:
        f.write(cache_path.read_bytes())

    replay_id = uuid.uuid4().hex[:8]
    entry = QueueEntry(
        id=replay_id,
        audio_path=tmp_path,
        text_preview=entry_data.get("text", ""),
        voice_label=entry_data.get("voice", ""),
        created_at=time.time(),
        entry_type=entry_data.get("type", "speak"),
        channel=entry_data.get("channel"),
        history_id=replay_id,
        is_replay=True,
    )
    pos = queue.enqueue(entry)
    return JSONResponse({"id": replay_id, "position": pos, "replaying": history_id})


async def handle_cache_list(request: StarletteRequest) -> JSONResponse:
    items = await asyncio.to_thread(_phrase_cache_list)
    total_size = sum(int(it.get("size_bytes") or 0) for it in items)
    try:
        limit = max(1, min(int(request.query_params.get("limit", "200")), 1000))
    except (ValueError, TypeError):
        limit = 200
    sort = request.query_params.get("sort", "recent")
    if sort == "popular":
        items.sort(key=lambda m: int(m.get("play_count") or 0), reverse=True)
    return JSONResponse({
        "phrases": items[:limit],
        "total": len(items),
        "total_size_bytes": total_size,
        "max_bytes": PHRASE_CACHE_MAX_BYTES,
    })


async def handle_cache_delete(request: StarletteRequest) -> JSONResponse:
    key = request.path_params.get("key", "")
    if not isinstance(key, str) or not key:
        return JSONResponse({"error": "No key provided"}, status_code=400)
    # Defend against path traversal — keys are SHA256 hex prefixes
    if not all(c in "0123456789abcdef" for c in key) or len(key) > 64:
        return JSONResponse({"error": "Invalid key format"}, status_code=400)

    cache_path = PHRASE_CACHE_DIR / f"{key}.mp3"
    sidecar_path = _phrase_cache_meta_path(key)
    deleted = False
    if cache_path.exists():
        try:
            cache_path.unlink()
            deleted = True
        except OSError as e:
            return JSONResponse({"error": f"Could not delete: {e}"}, status_code=500)
    if sidecar_path.exists():
        try:
            sidecar_path.unlink()
        except OSError:
            pass

    if not deleted:
        return JSONResponse({"error": "Cached phrase not found"}, status_code=404)
    return JSONResponse({"deleted": True, "key": key})


async def handle_cache_clear(request: StarletteRequest) -> JSONResponse:
    """Wipe every cached phrase. Destructive — used to reset the canon."""
    if not PHRASE_CACHE_DIR.exists():
        return JSONResponse({"deleted": 0})
    count = 0
    for p in list(PHRASE_CACHE_DIR.iterdir()):
        if p.is_file() and p.suffix in (".mp3", ".json"):
            try:
                p.unlink()
                if p.suffix == ".mp3":
                    count += 1
            except OSError:
                pass
    return JSONResponse({"deleted": count})


async def handle_cache_play(request: StarletteRequest) -> JSONResponse:
    queue: AudioQueue = request.app.state.queue
    try:
        body = await request.json()
    except Exception:
        return JSONResponse({"error": "Invalid JSON"}, status_code=400)
    if not isinstance(body, dict):
        return JSONResponse({"error": "Expected JSON object"}, status_code=400)

    key = body.get("key", "")
    if not isinstance(key, str) or not key:
        return JSONResponse({"error": "No key provided"}, status_code=400)

    cache_path = PHRASE_CACHE_DIR / f"{key}.mp3"
    if not cache_path.exists():
        return JSONResponse({"error": "Cached phrase not found"}, status_code=404)

    meta = _phrase_cache_load_meta(key) or {}

    # Bump play_count + last_played_at on replay
    meta_text = str(meta.get("text") or "")
    meta_voice_label = str(meta.get("voice_label") or "")
    meta["key"] = key
    meta["play_count"] = int(meta.get("play_count", 0)) + 1
    meta["last_played_at"] = time.time()
    _phrase_cache_save_meta(key, meta)
    try:
        os.utime(cache_path, None)
    except OSError:
        pass

    # Copy cached MP3 to a temp file so the worker's cleanup doesn't delete the cache entry
    fd, tmp_path = tempfile.mkstemp(prefix=TEMP_PREFIX, suffix=".mp3")
    with os.fdopen(fd, "wb") as f:
        f.write(cache_path.read_bytes())

    entry_id = uuid.uuid4().hex[:8]
    entry = QueueEntry(
        id=entry_id,
        audio_path=tmp_path,
        text_preview=(meta_text or "(cached phrase)")[:100],
        voice_label=meta_voice_label or "Caldwell",
        created_at=time.time(),
        full_text=meta_text,
    )
    pos = queue.enqueue(entry)
    return JSONResponse({
        "id": entry_id,
        "position": pos,
        "key": key,
        "play_count": meta.get("play_count"),
    })


async def handle_events(request: StarletteRequest) -> StreamingResponse:
    broadcaster: SSEBroadcaster = request.app.state.broadcaster
    queue: AudioQueue = request.app.state.queue
    client_q = broadcaster.subscribe()

    async def stream():
        try:
            state = queue.status()
            state["recent_history"] = queue.get_history(limit=20)
            yield f"event: state\ndata: {json.dumps(state)}\n\n"
            while True:
                msg = await client_q.get()
                yield msg
        except asyncio.CancelledError:
            pass
        finally:
            broadcaster.unsubscribe(client_q)

    return StreamingResponse(
        stream(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )


async def handle_health(request: StarletteRequest) -> JSONResponse:
    queue: AudioQueue = request.app.state.queue
    return JSONResponse({
        "status": "ok",
        "version": "2.0",
        "queue_size": len(queue._deque) + (1 if queue._current else 0),
    })


async def handle_index(request: StarletteRequest) -> JSONResponse:
    """Friendly landing — the web dashboard was dropped (redundant with the
    macOS menubar app). Anyone hitting / by accident gets a quick pointer
    rather than a 404."""
    return JSONResponse({
        "name": "Caldwell daemon",
        "version": "2.0",
        "ui": "Use Caldwell.app (menu-bar) or scripts/say.sh CLI",
        "setup": "say.sh --set-api-key sk_... && say.sh --set-voice-id <20-char>",
        "health": "/health",
        "endpoints": "/speak, /queue, /history, /cache/phrases, /settings, /usage, /events",
    })


def _mask_api_key(key: str) -> str:
    if not key:
        return ""
    if len(key) <= 8:
        return "•" * len(key)
    return key[:4] + "•" * 8 + key[-4:]


def _validate_api_key(key: str) -> tuple[bool, str]:
    """Hit ElevenLabs /v1/user. Returns (ok, error_message)."""
    try:
        req = Request(f"{API_BASE}/user", headers={"xi-api-key": key})
        with urlopen(req, timeout=10) as resp:
            resp.read()
        return True, ""
    except HTTPError as e:
        if e.code == 401:
            return False, "API key rejected by ElevenLabs (401)"
        return False, f"ElevenLabs returned HTTP {e.code}"
    except URLError as e:
        return False, f"Could not reach ElevenLabs: {e.reason}"
    except Exception as e:
        return False, f"Validation error: {e}"


def _validate_voice_id(key: str, voice_id: str) -> tuple[bool, str, dict]:
    """Hit /v1/voices/{voice_id}. Returns (ok, error_message, voice_metadata)."""
    try:
        req = Request(f"{API_BASE}/voices/{voice_id}", headers={"xi-api-key": key})
        with urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read())
        return True, "", {
            "name": data.get("name", ""),
            "category": data.get("category", ""),
            "labels": data.get("labels", {}),
        }
    except HTTPError as e:
        if e.code == 404:
            return False, "Voice not found in your ElevenLabs account", {}
        if e.code == 401:
            return False, "API key rejected when checking voice", {}
        return False, f"ElevenLabs returned HTTP {e.code}", {}
    except URLError as e:
        return False, f"Could not reach ElevenLabs: {e.reason}", {}
    except Exception as e:
        return False, f"Validation error: {e}", {}


async def handle_settings_get(request: StarletteRequest) -> JSONResponse:
    api_key = os.environ.get("ELEVENLABS_API_KEY", "")
    voice_id = os.environ.get("ELEVENLABS_VOICE_ID", "")
    return JSONResponse({
        "api_key_set": bool(api_key),
        "api_key_preview": _mask_api_key(api_key),
        "voice_id": voice_id,
        "voice_label": voice_label(voice_id) if voice_id else "",
        "expletives_enabled": _expletives_enabled(),
        "muted": _muted(),
    })


async def handle_settings_post(request: StarletteRequest) -> JSONResponse:
    global _api_voices_cache
    try:
        body = await request.json()
    except Exception:
        return JSONResponse({"error": "Invalid JSON"}, status_code=400)
    if not isinstance(body, dict):
        return JSONResponse({"error": "Expected JSON object"}, status_code=400)

    raw_key = body.get("api_key")
    raw_voice = body.get("voice_id")
    raw_expl = body.get("expletives_enabled")
    raw_mute = body.get("muted")

    if raw_key is not None and not isinstance(raw_key, str):
        return JSONResponse({"error": "api_key must be a string"}, status_code=400)
    if raw_voice is not None and not isinstance(raw_voice, str):
        return JSONResponse({"error": "voice_id must be a string"}, status_code=400)
    if raw_expl is not None and not isinstance(raw_expl, bool):
        return JSONResponse({"error": "expletives_enabled must be a boolean"}, status_code=400)
    if raw_mute is not None and not isinstance(raw_mute, bool):
        return JSONResponse({"error": "muted must be a boolean"}, status_code=400)

    new_key = raw_key.strip() if isinstance(raw_key, str) else None
    new_voice = raw_voice.strip() if isinstance(raw_voice, str) else None
    new_expl: bool | None = raw_expl if isinstance(raw_expl, bool) else None
    new_mute: bool | None = raw_mute if isinstance(raw_mute, bool) else None

    if new_key is None and new_voice is None and new_expl is None and new_mute is None:
        return JSONResponse({"error": "No fields to update"}, status_code=400)

    # Determine the key to use for validating voice_id
    effective_key = new_key if new_key else os.environ.get("ELEVENLABS_API_KEY", "")

    config_updates: dict[str, str] = {}  # Non-secret values for config.json
    env_updates: dict[str, str] = {}     # Hot-reload mutations to os.environ
    voice_meta: dict = {}

    if new_key:
        ok, err = await asyncio.to_thread(_validate_api_key, new_key)
        if not ok:
            return JSONResponse({"error": err, "field": "api_key"}, status_code=400)
        # Write to Keychain, not config.json
        if not await asyncio.to_thread(
            _keychain_set, KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT_API_KEY, new_key
        ):
            return JSONResponse({
                "error": "Could not write API key to macOS Keychain. "
                         "Check that the security command is available.",
                "field": "api_key",
            }, status_code=500)
        env_updates["ELEVENLABS_API_KEY"] = new_key

    if new_voice is not None:
        if new_voice == "":
            config_updates["ELEVENLABS_VOICE_ID"] = ""
            env_updates["ELEVENLABS_VOICE_ID"] = ""
        else:
            if not effective_key:
                return JSONResponse({
                    "error": "Cannot validate voice ID without an API key",
                    "field": "voice_id",
                }, status_code=400)
            ok, err, meta = await asyncio.to_thread(_validate_voice_id, effective_key, new_voice)
            if not ok:
                return JSONResponse({"error": err, "field": "voice_id"}, status_code=400)
            config_updates["ELEVENLABS_VOICE_ID"] = new_voice
            env_updates["ELEVENLABS_VOICE_ID"] = new_voice
            voice_meta = meta

    if new_expl is not None:
        flag = "1" if new_expl else "0"
        config_updates["CALDWELL_EXPLETIVES"] = flag
        env_updates["CALDWELL_EXPLETIVES"] = flag

    if new_mute is not None:
        flag = "1" if new_mute else "0"
        config_updates["CALDWELL_MUTED"] = flag
        env_updates["CALDWELL_MUTED"] = flag

    if config_updates:
        try:
            await asyncio.to_thread(_save_config_json, config_updates)
        except OSError as e:
            return JSONResponse({"error": f"Could not save config: {e}"}, status_code=500)

    # Hot-reload: mutate os.environ so live requests pick up the new values
    for k, v in env_updates.items():
        if v:
            os.environ[k] = v
        else:
            os.environ.pop(k, None)

    # Invalidate cached API voice lookups (keyed off the old API key)
    if "ELEVENLABS_API_KEY" in env_updates:
        _api_voices_cache = None

    return JSONResponse({
        "saved": True,
        "api_key_set": bool(os.environ.get("ELEVENLABS_API_KEY", "")),
        "api_key_preview": _mask_api_key(os.environ.get("ELEVENLABS_API_KEY", "")),
        "voice_id": os.environ.get("ELEVENLABS_VOICE_ID", ""),
        "voice_meta": voice_meta,
        "expletives_enabled": _expletives_enabled(),
        "muted": _muted(),
    })


async def handle_usage(request: StarletteRequest) -> JSONResponse:
    base = QUOTA.status()
    subscription = await asyncio.to_thread(_fetch_elevenlabs_subscription)
    if subscription:
        base["elevenlabs"] = _compute_run_rate(subscription)
    return JSONResponse(base)


async def handle_portrait(request: StarletteRequest) -> FileResponse | JSONResponse:
    """Serve Caldwell's portrait images to the menubar app's PortraitManager.
    The web dashboard was dropped, but the portraits are still a real asset
    used by the floating panel and Now Playing portrait views."""
    name = request.path_params["name"]
    portraits_root = PORTRAITS_DIR.resolve()
    portrait_path = (portraits_root / name).resolve()
    try:
        portrait_path.relative_to(portraits_root)
    except ValueError:
        return JSONResponse({"error": "Not found"}, status_code=404)

    if portrait_path.exists() and portrait_path.is_file():
        suffix = portrait_path.suffix.lower()
        media = {
            ".png": "image/png", ".jpg": "image/jpeg",
            ".jpeg": "image/jpeg", ".webp": "image/webp",
        }.get(suffix, "application/octet-stream")
        return FileResponse(portrait_path, media_type=media)
    return JSONResponse({"error": "Not found"}, status_code=404)


async def handle_voices(request: StarletteRequest) -> JSONResponse:
    voices_path = REPO_ROOT / "voices.json"
    if voices_path.exists():
        try:
            data = json.loads(voices_path.read_text())
            return JSONResponse(data)
        except json.JSONDecodeError:
            pass
    return JSONResponse([])


# --- Main ---

async def main():
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    _clean_old_cache(CACHE_DIR)

    async def _periodic_cache_cleanup():
        while True:
            await asyncio.sleep(3600)
            try:
                await asyncio.to_thread(_clean_old_cache, CACHE_DIR)
                await asyncio.to_thread(_prune_phrase_cache)
            except Exception as e:
                log.warning(f"Cache cleanup error: {e}")

    broadcaster = SSEBroadcaster()
    queue = AudioQueue(broadcaster)
    queue.start()
    asyncio.create_task(_periodic_cache_cleanup())

    app = Starlette(middleware=[Middleware(LocalhostGuardMiddleware)], routes=[
        Route("/speak", handle_speak, methods=["POST"]),
        Route("/speak/dialogue", handle_speak_dialogue, methods=["POST"]),
        Route("/queue", handle_queue_status, methods=["GET"]),
        Route("/queue/clear", handle_queue_clear, methods=["POST"]),
        Route("/queue/skip", handle_queue_skip, methods=["POST"]),
        Route("/queue/seek", handle_queue_seek, methods=["POST"]),
        Route("/queue/pause", handle_queue_pause, methods=["POST"]),
        Route("/queue/resume", handle_queue_resume, methods=["POST"]),
        Route("/history", handle_history, methods=["GET"]),
        Route("/history/replay", handle_history_replay, methods=["POST"]),
        Route("/cache/phrases", handle_cache_list, methods=["GET"]),
        Route("/cache/phrases/{key}", handle_cache_delete, methods=["DELETE"]),
        Route("/cache/clear", handle_cache_clear, methods=["POST"]),
        Route("/cache/play", handle_cache_play, methods=["POST"]),
        Route("/events", handle_events, methods=["GET"]),
        Route("/voices", handle_voices, methods=["GET"]),
        Route("/settings", handle_settings_get, methods=["GET"]),
        Route("/settings", handle_settings_post, methods=["POST"]),
        Route("/usage", handle_usage, methods=["GET"]),
        Route("/health", handle_health, methods=["GET"]),
        Route("/", handle_index, methods=["GET"]),
        Route("/portraits/{name:path}", handle_portrait, methods=["GET"]),
    ])
    app.state.queue = queue
    app.state.broadcaster = broadcaster

    config = uvicorn.Config(
        app, host="127.0.0.1", port=DASHBOARD_PORT,
        log_level="info",
    )
    server = uvicorn.Server(config)
    await server.serve()


if __name__ == "__main__":
    asyncio.run(main())
