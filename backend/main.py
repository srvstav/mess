"""MUJ Mess API — controllers only. SQL lives in repo.py, login logic in auth.py."""
import logging
import re
from datetime import date, timedelta
from pathlib import Path
from typing import Annotated

import pymysql
from fastapi import Depends, FastAPI, HTTPException, Query, Request, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field, model_validator
from pymysql.connections import Connection

import auth
import repo
from config import now, settings, today
from db import get_conn

log = logging.getLogger("uvicorn.error")

app = FastAPI(title="MUJ Mess API", description="One fee, two messes, book every meal.")
app.add_middleware(
    CORSMiddleware,
    allow_origins=list(settings.allowed_origins),
    allow_methods=["GET", "POST"],
    allow_headers=["Authorization", "Content-Type"],
)

Conn = Annotated[Connection, Depends(get_conn)]
StudentId = Annotated[int, Depends(auth.current_student)]
Phone = Annotated[str, Field(pattern=r"^[6-9]\d{9}$", description="10-digit Indian mobile")]
SlotId = Annotated[int, Field(ge=1, le=255)]
MessId = Annotated[int, Field(ge=1, le=255)]


@app.exception_handler(pymysql.err.OperationalError)
async def db_rule_violation(_: Request, exc: pymysql.err.OperationalError) -> JSONResponse:
    # SIGNAL SQLSTATE '45000' inside a trigger arrives as MySQL error 1644 — a business rule, not a crash.
    if exc.args and exc.args[0] == 1644:
        return JSONResponse({"detail": exc.args[1]}, status_code=status.HTTP_409_CONFLICT)
    log.error("database error: %s", exc)  # shows up in the start.bat window / Render logs
    return JSONResponse({"detail": "Database is unavailable, try again"}, status_code=503)


# ---------- request bodies ----------

class PhoneIn(BaseModel):
    phone: Phone


class DemoVerifyIn(BaseModel):
    phone: Phone
    otp: Annotated[str, Field(pattern=r"^\d{6}$")]


class LoginIn(BaseModel):
    id_token: Annotated[str, Field(min_length=20, max_length=4096, description="Firebase ID token")]


class BookingIn(BaseModel):
    meal_date: date
    slot_id: SlotId
    mess_id: MessId | None = None  # None = skip this meal


class PauseIn(BaseModel):
    from_date: date
    to_date: date

    @model_validator(mode="after")
    def check_range(self) -> "PauseIn":
        if self.to_date < self.from_date:
            raise ValueError("Return date must be on or after the leaving date")
        return self


class RatingIn(BaseModel):
    meal_date: date
    slot_id: SlotId
    stars: Annotated[int, Field(ge=1, le=5)]
    comment: Annotated[str | None, Field(max_length=200)] = None


def _bad(msg: str) -> HTTPException:
    return HTTPException(status.HTTP_400_BAD_REQUEST, msg)


# ---------- health ----------

@app.get("/health", tags=["system"])
def health(conn: Conn) -> dict[str, str]:
    repo.slot_exists(conn, 1)  # proves the database answers, not just the API
    return {"status": "ok", "today": str(today())}


# ---------- login ----------

@app.post("/auth/check", tags=["login"])
def check(body: PhoneIn, request: Request, conn: Conn) -> dict:
    """Asked before the code is sent: rate-limits, and in demo mode returns the code. Any number may log in."""
    on_roster = auth.check_roster(conn, body.phone, request.client.host if request.client else "?")
    if on_roster and auth.demo_mode():
        # Demo mode (no Firebase yet): hand back the code instead of texting it.
        return {"on_roster": True, "demo_code": auth.demo_send(body.phone)}
    return {"on_roster": on_roster}


@app.post("/auth/demo-verify", tags=["login"])
def demo_verify(body: DemoVerifyIn, conn: Conn) -> dict:
    """Demo mode only: check the on-screen code and start a session."""
    student_id = auth.demo_login(conn, body.phone, body.otp)
    return {"token": auth.make_token(student_id), "student": repo.profile(conn, student_id)}


@app.post("/auth/login", tags=["login"])
def login(body: LoginIn, conn: Conn) -> dict:
    """The browser sends the SMS through Firebase, then posts Firebase's ID token here."""
    student_id = auth.login(conn, body.id_token)
    return {"token": auth.make_token(student_id), "student": repo.profile(conn, student_id)}


@app.get("/me", tags=["login"])
def me(student_id: StudentId, conn: Conn) -> dict:
    student = repo.profile(conn, student_id)
    if student is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Please log in again")
    return {"student": student}


# ---------- student ----------

@app.get("/menu", tags=["student"])
def get_menu(conn: Conn) -> dict:
    slots: dict[int, dict] = {}
    for r in repo.menu(conn):
        slot = slots.setdefault(r["slot_id"], {
            "slot_id": r["slot_id"], "code": r["slot_code"], "name": r["slot"],
            "starts_at": r["starts_at"], "ends_at": r["ends_at"], "messes": {},
        })
        mess = slot["messes"].setdefault(r["mess_id"], {"mess_id": r["mess_id"], "name": r["mess"], "dishes": []})
        mess["dishes"].append(r["dish"])
    return {"slots": [{**s, "messes": list(s["messes"].values())} for s in slots.values()]}


@app.get("/bookings/me", tags=["student"])
def my_bookings(student_id: StudentId, conn: Conn, meal_date: date | None = None) -> dict:
    d = meal_date or today()
    return {"meal_date": d, "paused": repo.is_paused(conn, student_id, d), "bookings": repo.bookings_for(conn, student_id, d),
            "eaten": repo.eaten_for(conn, student_id, d), "donations": repo.donations_on(conn, d)}


@app.post("/bookings", tags=["student"])
def book(body: BookingIn, student_id: StudentId, conn: Conn) -> dict[str, str]:
    t = today()
    if not t <= body.meal_date <= t + timedelta(days=settings.booking_days_ahead):
        raise _bad(f"Pick a date from today to {settings.booking_days_ahead} days ahead")
    if not repo.slot_exists(conn, body.slot_id) or (body.mess_id and not repo.mess_exists(conn, body.mess_id)):
        raise _bad("Unknown meal or mess")
    repo.upsert_booking(conn, student_id, body.meal_date, body.slot_id, body.mess_id)  # trigger blocks if paused
    return {"status": "booked" if body.mess_id else "skipped"}


@app.get("/pause/me", tags=["student"])
def my_pauses(student_id: StudentId, conn: Conn) -> dict:
    return {"pauses": repo.active_pauses(conn, student_id, today())}


@app.post("/pause", tags=["student"])
def pause(body: PauseIn, student_id: StudentId, conn: Conn) -> dict[str, str]:
    t = today()
    if body.from_date < t:
        raise _bad("You can't pause a day that has already passed")
    if (body.to_date - body.from_date).days >= settings.max_pause_days:
        raise _bad(f"A pause can be at most {settings.max_pause_days} days")
    repo.pause(conn, student_id, body.from_date, body.to_date)
    return {"status": "paused"}


@app.post("/resume", tags=["student"])
def resume(student_id: StudentId, conn: Conn) -> dict[str, str]:
    repo.resume(conn, student_id, today())
    return {"status": "resumed"}


# ---------- ratings: only for meals the student actually ate (the face terminals write attendance) ----------

@app.post("/ratings", tags=["student"])
def rate(body: RatingIn, student_id: StudentId, conn: Conn) -> dict[str, str]:
    if body.meal_date > today():
        raise _bad("You can't rate a meal that hasn't happened")
    if not repo.rate(conn, student_id, body.meal_date, body.slot_id, body.stars, body.comment):
        raise HTTPException(status.HTTP_409_CONFLICT, "You can only rate a meal you have eaten")
    return {"status": "rated"}


# ---------- public dashboards (no personal data) ----------

@app.get("/stats/today", tags=["dashboard"])
def stats_today(conn: Conn) -> dict:
    t = today()
    return {"meal_date": t, "forecast": repo.forecast(conn, t), "headline": repo.headline(conn, t)}


_PHONE = re.compile(r"\b([6-9]\d)\d{5}(\d{3})\b")


@app.get("/admin/live", tags=["dashboard"])
def live(conn: Conn, limit: int = Query(default=25, ge=1, le=100)) -> dict:
    t = today()
    # Phones are masked because this endpoint is public.
    activity = [{**a, "detail": _PHONE.sub(r"\1xxxxx\2", a["detail"])} for a in repo.recent_activity(conn, limit)]
    return {
        "meal_date": t,
        "activity": activity,
        "summary": repo.meal_summary(conn, t),
        "roster": repo.roster_counts(conn),
        "earnings": repo.earnings(conn, t, now().strftime("%H:%M:%S")),
        "tomorrow": repo.forecast(conn, t + timedelta(days=1)),
        "hostels": repo.hostel_split(conn, t),
        "donations": repo.donations_on(conn, t),
        "ngos": repo.ngo_totals(conn),
        "ratings": repo.ratings(conn, t),
    }


@app.get("/admin", include_in_schema=False)
def admin_redirect() -> RedirectResponse:
    return RedirectResponse("/dashboard.html")


@app.middleware("http")
async def always_fresh_site(request: Request, call_next):
    """Browsers must re-check pages and scripts each visit (a 304 if unchanged), so an update shows at once."""
    response = await call_next(request)
    if request.url.path == "/" or request.url.path.endswith((".html", ".js", ".css")):
        response.headers["Cache-Control"] = "no-cache"
    return response


# The same site that GitHub Pages serves, so the whole system also runs offline from one laptop.
SITE = Path(__file__).resolve().parent.parent / "docs"
if SITE.is_dir():
    app.mount("/", StaticFiles(directory=SITE, html=True), name="site")
