"""Login (Firebase phone OTP, or an on-screen demo code) -> our own session token. Token signing is stdlib only."""
import base64
import hashlib
import hmac
import json
import re
import secrets
import threading
import time
from collections import defaultdict, deque

from fastapi import Header, HTTPException, status
from pymysql.connections import Connection

import firebase
import repo
from config import settings

_INDIAN = re.compile(r"^\+91([6-9]\d{9})$")


# Roster checks per IP: enough for typos, too few to walk through the roster. In memory, so it resets
# on restart; that's fine for one small server.
CHECKS_PER_WINDOW, WINDOW_SECONDS = 10, 600
_checks: defaultdict[str, deque[float]] = defaultdict(deque)
_checks_lock = threading.Lock()


def check_roster(conn: Connection, phone: str, client_ip: str) -> bool:
    """Before an SMS is spent. Every number may log in (new ones join the roster on first login),
    so this only rate-limits; it answers True for any valid number."""
    now = time.monotonic()
    with _checks_lock:
        recent = _checks[client_ip]
        while recent and now - recent[0] > WINDOW_SECONDS:
            recent.popleft()
        if len(recent) >= CHECKS_PER_WINDOW:
            raise HTTPException(status.HTTP_429_TOO_MANY_REQUESTS, "Too many tries. Wait 10 minutes and try again")
        recent.append(now)
    return True


def _student_for(conn: Connection, phone: str) -> int:
    """The student with this phone, enrolling them first if they're new."""
    student = repo.student_by_phone(conn, phone)
    if student is None:
        repo.enrol_guest(conn, phone)
        student = repo.student_by_phone(conn, phone)
    assert student is not None
    if student["status"] != "active":
        raise HTTPException(status.HTTP_403_FORBIDDEN, "This student has left or graduated")
    return int(student["id"])


# ---------- demo mode: used only while Firebase isn't set up ----------
# The server makes the code and the page shows it, so the whole flow works with no SMS account.
# Codes live in memory (hashed), last 5 minutes, work once, and allow 5 tries.
DEMO_TTL, DEMO_TRIES = 300, 5
_demo: dict[str, tuple[str, float, int]] = {}  # phone -> (code hash, expires at, tries left)


def demo_mode() -> bool:
    return not settings.firebase_project_id


def _hash(phone: str, code: str) -> str:
    return hmac.new(settings.token_secret, f"{phone}:{code}".encode(), hashlib.sha256).hexdigest()


def demo_send(phone: str) -> str:
    if not demo_mode():
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Real SMS login is on; demo codes are switched off")
    code = f"{secrets.randbelow(10**6):06d}"
    with _checks_lock:
        _demo[phone] = (_hash(phone, code), time.monotonic() + DEMO_TTL, DEMO_TRIES)
    return code


def demo_login(conn: Connection, phone: str, code: str) -> int:
    if not demo_mode():
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Real SMS login is on; demo codes are switched off")
    with _checks_lock:
        entry = _demo.get(phone)
        if entry is None or entry[1] < time.monotonic():
            _demo.pop(phone, None)
            raise HTTPException(status.HTTP_400_BAD_REQUEST, "That code expired. Tap “Resend code”")
        code_hash, expires, tries = entry
        if not hmac.compare_digest(code_hash, _hash(phone, code)):
            if tries <= 1:
                _demo.pop(phone, None)
                raise HTTPException(status.HTTP_429_TOO_MANY_REQUESTS, "Too many wrong codes. Tap “Resend code”")
            _demo[phone] = (code_hash, expires, tries - 1)
            raise HTTPException(status.HTTP_400_BAD_REQUEST, "Wrong code. Check it and try again")
        del _demo[phone]  # one use only
    student_id = _student_for(conn, phone)
    repo.record_login(conn, student_id, "demo")
    return student_id


def login(conn: Connection, id_token: str) -> int:
    """Firebase has already checked the SMS code. We check the token, then the roster."""
    if not settings.firebase_project_id:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "Login isn't set up yet (see HANDOVER.md, step 3)")
    try:
        uid, e164 = firebase.verify(id_token, settings.firebase_project_id)
    except firebase.InvalidToken as e:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, str(e)) from None
    m = _INDIAN.match(e164)
    if not m:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Only Indian (+91) mobile numbers can log in")
    student_id = _student_for(conn, m.group(1))
    repo.record_login(conn, student_id, uid)  # fires the LOGIN trigger
    return student_id


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _unb64(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def make_token(student_id: int) -> str:
    body = _b64(json.dumps({"sid": student_id, "exp": int(time.time()) + settings.token_ttl_seconds}).encode())
    sig = _b64(hmac.new(settings.token_secret, body.encode(), hashlib.sha256).digest())
    return f"{body}.{sig}"


def current_student(authorization: str = Header(default="")) -> int:
    """FastAPI dependency: returns student_id from 'Authorization: Bearer <token>'."""
    unauthorized = HTTPException(status.HTTP_401_UNAUTHORIZED, "Please log in again")
    scheme, _, token = authorization.partition(" ")
    if scheme.lower() != "bearer" or "." not in token:
        raise unauthorized
    body, sig = token.rsplit(".", 1)
    expected = _b64(hmac.new(settings.token_secret, body.encode(), hashlib.sha256).digest())
    if not hmac.compare_digest(sig, expected):
        raise unauthorized
    try:
        payload = json.loads(_unb64(body))
    except ValueError:
        raise unauthorized from None
    if payload.get("exp", 0) < time.time():
        raise unauthorized
    return int(payload["sid"])
