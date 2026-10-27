import base64
import json
import os
import re
import tempfile
from dataclasses import dataclass
from datetime import date, datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from dotenv import load_dotenv

load_dotenv(Path(__file__).parent / ".env")

# On Render every setting arrives packed in one value (made by setup_cloud.bat).
if packed := os.environ.get("MESS_SETTINGS"):
    for _k, _v in json.loads(base64.b64decode(packed)).items():
        os.environ.setdefault(_k, str(_v))

IST = ZoneInfo("Asia/Kolkata")  # cloud servers run on UTC; the mess runs on India time


def today() -> date:
    return datetime.now(IST).date()


def now() -> datetime:
    return datetime.now(IST).replace(tzinfo=None)


def _required(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"Missing env var {name}. Run setup first (setup.bat / python setup.py local).")
    return value


def _ssl_ca_path() -> str | None:
    """Cloud MySQL needs TLS. Accept a file path, or the PEM text itself (handy on Render)."""
    if path := os.environ.get("DB_SSL_CA"):
        return path
    if pem := os.environ.get("DB_SSL_CA_PEM"):
        f = tempfile.NamedTemporaryFile("w", suffix=".pem", delete=False)
        f.write(pem.replace("\\n", "\n"))
        f.close()
        return f.name
    return None


def _firebase_project_id() -> str | None:
    """The Firebase project lives in one place: docs/config.js (the website needs it too).
    FIREBASE_PROJECT_ID overrides it, e.g. on a server without the docs folder."""
    if pid := os.environ.get("FIREBASE_PROJECT_ID"):
        return pid
    site_config = Path(__file__).resolve().parent.parent / "docs" / "config.js"
    if site_config.exists():
        m = re.search(r'projectId:\s*"([a-z0-9-]+)"', site_config.read_text(encoding="utf-8"))
        return m.group(1) if m else None
    return None


@dataclass(frozen=True)
class Settings:
    db_host: str
    db_port: int
    db_user: str
    db_password: str
    db_name: str
    db_ssl_ca: str | None
    token_secret: bytes
    firebase_project_id: str | None  # None = login not set up yet (see HANDOVER.md, step 3)
    allowed_origins: tuple[str, ...]
    token_ttl_seconds: int = 7 * 24 * 3600
    booking_days_ahead: int = 7
    max_pause_days: int = 60


def load_settings() -> Settings:
    return Settings(
        db_host=os.environ.get("DB_HOST", "127.0.0.1"),
        db_port=int(os.environ.get("DB_PORT", "3306")),
        db_user=_required("DB_USER"),
        db_password=_required("DB_PASSWORD"),
        db_name=os.environ.get("DB_NAME", "mess"),
        db_ssl_ca=_ssl_ca_path(),
        token_secret=_required("TOKEN_SECRET").encode(),
        firebase_project_id=_firebase_project_id(),
        allowed_origins=tuple(o.strip() for o in os.environ.get("ALLOWED_ORIGINS", "*").split(",") if o.strip()),
    )


settings = load_settings()
