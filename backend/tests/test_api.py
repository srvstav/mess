"""Integration tests against the configured `mess` database (run setup first).

They add rows to the real database. Run `reset.bat` / `python setup.py reset` afterwards for a clean demo.
"""
import dataclasses
import random
import time
from datetime import timedelta

import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

import auth
import firebase
from config import settings, today
from db import connect
from main import app

client = TestClient(app)
PROJECT = "mess-test"

# Stand-in for Google's signing key: tokens are signed and checked for real, just with our key.
_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
_PEM = _KEY.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())


@pytest.fixture(autouse=True)
def fake_firebase(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(firebase, "_key_for", lambda kid: _KEY.public_key() if kid == "test" else None)
    monkeypatch.setattr(auth, "settings", dataclasses.replace(settings, firebase_project_id=PROJECT))


def _id_token(phone: str, project: str = PROJECT, kid: str = "test", age: int = 0) -> str:
    t = int(time.time()) - age
    claims = {"iss": f"https://securetoken.google.com/{project}", "aud": project, "sub": f"uid-{phone}",
              "iat": t, "exp": t + 3600, "auth_time": t, "phone_number": f"+91{phone}"}
    return jwt.encode(claims, _PEM, algorithm="RS256", headers={"kid": kid})


def _phone() -> str:
    """A new student on the roster (as the mess office would add one in Workbench)."""
    phone = f"8{random.randint(0, 10**9 - 1):09d}"
    with connect() as conn, conn.cursor() as cur:
        cur.execute(
            "INSERT INTO students (reg_no, full_name, gender, phone, email, programme_id, year_of_study, "
            "hostel_id, room_no, joined_on) VALUES (%s, 'Test Student', 'F', %s, %s, 1, 2, 13, '101', '2025-07-20')",
            (f"99{phone[-7:]}", phone, f"test.{phone}@example.com"))
        conn.commit()
    return phone


def _login(phone: str) -> dict[str, str]:
    token = client.post("/auth/login", json={"id_token": _id_token(phone)}).json()["token"]
    return {"Authorization": f"Bearer {token}"}


def _q(sql: str, args: tuple = ()) -> dict | None:
    with connect() as conn, conn.cursor() as cur:
        cur.execute(sql, args)
        return cur.fetchone()


def _booked(meal: str, mess: str) -> int:
    row = _q("SELECT booked FROM v_daily_forecast WHERE meal_date = %s AND meal = %s AND mess = %s",
             (today(), meal, mess))
    return int(row["booked"]) if row else 0


# ---------- login ----------

def test_login_returns_roster_profile_and_is_logged_by_trigger() -> None:
    phone = _phone()
    r = client.post("/auth/login", json={"id_token": _id_token(phone)})
    assert r.status_code == 200
    me = r.json()["student"]
    assert me["full_name"] == "Test Student" and me["hostel"] == "G1" and me["programme"] == "BTECH-CSE"
    auth_header = {"Authorization": f"Bearer {r.json()['token']}"}
    assert client.get("/me", headers=auth_header).json()["student"]["phone"] == phone
    events = _q("SELECT GROUP_CONCAT(a.event ORDER BY a.id) AS e FROM activity_log a "
                "JOIN students s ON s.id = a.student_id WHERE s.phone = %s", (phone,))
    assert events["e"] == "ENROL,LOGIN"


def test_roster_check_before_sms_and_its_rate_limit(monkeypatch: pytest.MonkeyPatch) -> None:
    phone = _phone()
    assert client.post("/auth/check", json={"phone": phone}).json() == {"on_roster": True}  # real-SMS mode: no code returned
    assert client.post("/auth/check", json={"phone": "12345"}).status_code == 422
    monkeypatch.setattr(auth, "_checks", auth.defaultdict(auth.deque))
    codes = [client.post("/auth/check", json={"phone": phone}).status_code for _ in range(auth.CHECKS_PER_WINDOW + 1)]
    assert codes[-1] == 429 and set(codes[:-1]) == {200}


def test_new_number_joins_the_roster_on_first_login() -> None:
    phone = f"6{random.randint(0, 10**9 - 1):09d}"
    assert client.post("/auth/check", json={"phone": phone}).json()["on_roster"] is True
    r = client.post("/auth/login", json={"id_token": _id_token(phone)})
    assert r.status_code == 200 and r.json()["student"]["full_name"] == f"Guest {phone[-4:]}"
    assert client.post("/auth/login", json={"id_token": _id_token(phone)}).status_code == 200  # second login: same student


@pytest.mark.parametrize("bad", [
    lambda p: _id_token(p, project="someone-else"),   # token from another Firebase project
    lambda p: _id_token(p, kid="unknown"),            # not signed by a Google key
    lambda p: _id_token(p, age=7200),                 # expired
    lambda p: _id_token(p)[:-4] + "AAAA",             # tampered signature
])
def test_forged_or_stale_tokens_are_refused(bad) -> None:
    assert client.post("/auth/login", json={"id_token": bad(_phone())}).status_code == 401


def test_roster_rules_live_in_the_database() -> None:
    import pymysql
    with connect() as conn, conn.cursor() as cur, pytest.raises(pymysql.err.OperationalError, match="other gender"):
        cur.execute("INSERT INTO students (reg_no, full_name, gender, phone, email, programme_id, year_of_study, "
                    "hostel_id, room_no, joined_on) VALUES ('990000001', 'X Y', 'M', '8000000001', 'x@y.in', 1, 1, 13, "
                    "'1', '2025-07-20')")


# ---------- menu ----------

def test_menu_has_both_messes_for_all_four_meals() -> None:
    r = client.get("/menu")
    assert r.status_code == 200
    slots = r.json()["slots"]
    assert [s["name"] for s in slots] == ["Breakfast", "Lunch", "Hi-Tea", "Dinner"]
    assert slots[0]["starts_at"] == "07:30"
    assert all(len(s["messes"]) == 2 and all(m["dishes"] for m in s["messes"]) for s in slots)


def test_site_and_dashboards_are_served() -> None:
    for path in ("/", "/dashboard.html", "/credits.html"):
        assert client.get(path).status_code == 200, path
    live = client.get("/admin/live")
    assert live.status_code == 200 and live.json()["roster"]["students"] >= 1200


# ---------- booking ----------

def test_booking_needs_login() -> None:
    body = {"meal_date": str(today()), "slot_id": 1, "mess_id": 1}
    assert client.post("/bookings", json=body).status_code == 401
    assert client.post("/bookings", json=body, headers={"Authorization": "Bearer x.y"}).status_code == 401


def test_rebooking_changes_choice_and_skip_is_not_counted() -> None:
    auth = _login(_phone())
    d = str(today())
    dove, spring = _booked("Dinner", "BluDove"), _booked("Dinner", "BluSpring")

    client.post("/bookings", json={"meal_date": d, "slot_id": 4, "mess_id": 1}, headers=auth)
    assert _booked("Dinner", "BluDove") == dove + 1

    client.post("/bookings", json={"meal_date": d, "slot_id": 4, "mess_id": 2}, headers=auth)
    assert (_booked("Dinner", "BluDove"), _booked("Dinner", "BluSpring")) == (dove, spring + 1)

    client.post("/bookings", json={"meal_date": d, "slot_id": 4}, headers=auth)
    assert (_booked("Dinner", "BluDove"), _booked("Dinner", "BluSpring")) == (dove, spring)

    mine = client.get(f"/bookings/me?meal_date={d}", headers=auth).json()
    assert mine["bookings"] == [{"slot_id": 4, "mess_id": None, "status": "skipped"}]


def test_date_window_and_unknown_ids() -> None:
    auth = _login(_phone())
    far, d = str(today() + timedelta(days=8)), str(today())
    assert client.post("/bookings", json={"meal_date": far, "slot_id": 1, "mess_id": 1}, headers=auth).status_code == 400
    assert client.post("/bookings", json={"meal_date": d, "slot_id": 9, "mess_id": 1}, headers=auth).status_code == 400
    assert client.post("/bookings", json={"meal_date": d, "slot_id": 1, "mess_id": 9}, headers=auth).status_code == 400


def test_cook_for_is_booked_plus_30_percent() -> None:
    # Own booking, so this passes on a brand-new empty database too.
    client.post("/bookings", json={"meal_date": str(today()), "slot_id": 1, "mess_id": 1}, headers=_login(_phone()))
    with connect() as conn, conn.cursor() as cur:
        cur.execute("SELECT booked, cook_for FROM v_daily_forecast")
        rows = cur.fetchall()
    assert rows
    for r in rows:
        assert r["cook_for"] == -(-r["booked"] * 13 // 10)  # ceil(booked * 1.3)


# ---------- pause / resume ----------

def test_pause_releases_meals_blocks_booking_and_resume_restores() -> None:
    auth = _login(_phone())
    day = today() + timedelta(days=2)
    client.post("/bookings", json={"meal_date": str(day), "slot_id": 2, "mess_id": 1}, headers=auth)

    r = client.post("/pause", json={"from_date": str(day), "to_date": str(day + timedelta(days=1))}, headers=auth)
    assert r.status_code == 200
    mine = client.get(f"/bookings/me?meal_date={day}", headers=auth).json()
    assert mine["paused"] is True
    assert mine["bookings"] == [{"slot_id": 2, "mess_id": None, "status": "paused"}]

    # The trigger refuses a booking on a paused day.
    r = client.post("/bookings", json={"meal_date": str(day), "slot_id": 2, "mess_id": 1}, headers=auth)
    assert r.status_code == 409 and "paused" in r.json()["detail"]

    assert client.post("/resume", headers=auth).status_code == 200
    assert client.get("/pause/me", headers=auth).json()["pauses"] == []
    r = client.post("/bookings", json={"meal_date": str(day), "slot_id": 2, "mess_id": 1}, headers=auth)
    assert r.status_code == 200


def test_pause_validation() -> None:
    auth = _login(_phone())
    t = today()
    bad = [
        {"from_date": str(t - timedelta(days=1)), "to_date": str(t)},          # in the past
        {"from_date": str(t + timedelta(days=3)), "to_date": str(t + timedelta(days=1))},  # backwards
        {"from_date": str(t), "to_date": str(t + timedelta(days=90))},          # too long
    ]
    for body in bad:
        assert client.post("/pause", json=body, headers=auth).status_code in (400, 422)


# ---------- attendance (face terminals), ratings, donations ----------

def _face_scan(phone: str, slot_id: int, mess_id: int) -> None:
    """What a mess's face-recognition terminal does when it recognises a student."""
    with connect() as conn, conn.cursor() as cur:
        cur.execute("INSERT INTO attendance (student_id, meal_date, slot_id, mess_id) "
                    "SELECT id, %s, %s, %s FROM students WHERE phone = %s", (today(), slot_id, mess_id, phone))
        conn.commit()


def test_rating_only_for_a_meal_eaten() -> None:
    phone = _phone()
    auth_h = _login(phone)
    body = {"meal_date": str(today()), "slot_id": 2, "stars": 4}
    assert client.post("/ratings", json=body, headers=auth_h).status_code == 409   # not eaten yet
    _face_scan(phone, 2, 1)
    assert client.post("/ratings", json=body, headers=auth_h).status_code == 200
    assert client.post("/ratings", json={**body, "stars": 2}, headers=auth_h).status_code == 200  # change of mind
    assert client.post("/ratings", json={**body, "stars": 6}, headers=auth_h).status_code == 422
    eaten = client.get(f"/bookings/me?meal_date={today()}", headers=auth_h).json()["eaten"]
    assert eaten == [{"slot_id": 2, "mess_id": 1, "stars": 2}]


def test_rating_trigger_refuses_a_meal_not_eaten() -> None:
    import pymysql
    phone = _phone()
    with connect() as conn, conn.cursor() as cur:
        cur.execute("SELECT id FROM students WHERE phone = %s", (phone,))
        sid = cur.fetchone()["id"]
        with pytest.raises(pymysql.err.OperationalError, match="rate a meal you have eaten"):
            cur.execute("INSERT INTO ratings (student_id, meal_date, slot_id, mess_id, stars) VALUES (%s, %s, 1, 1, 5)",
                        (sid, today()))


def test_finished_meals_close_by_themselves() -> None:
    with connect() as conn, conn.cursor() as cur:
        cur.execute("CALL sp_close_finished_meals()")  # what ev_close_meals runs every 10 minutes
        conn.commit()
        cur.execute("SELECT TIME(UTC_TIMESTAMP() + INTERVAL 330 MINUTE) AS now_ist")
        now_ist = cur.fetchone()["now_ist"]
        cur.execute("SELECT COUNT(*) AS n FROM meal_slots ms WHERE ms.ends_at <= %s AND EXISTS (SELECT 1 FROM v_meal_summary v "
                    "WHERE v.meal_date = DATE(UTC_TIMESTAMP() + INTERVAL 330 MINUTE) AND v.slot_id = ms.id AND v.donate > 0) "
                    "AND NOT EXISTS (SELECT 1 FROM donations d WHERE d.meal_date = DATE(UTC_TIMESTAMP() + INTERVAL 330 MINUTE) "
                    "AND d.slot_id = ms.id)", (now_ist,))
        assert cur.fetchone()["n"] == 0  # every finished meal with leftovers has been donated


def test_meal_summary_math_and_close_meal() -> None:
    with connect() as conn, conn.cursor() as cur:
        cur.execute("SELECT * FROM v_meal_summary")
        rows = cur.fetchall()
    for r in rows:
        assert r["cooked"] == -(-r["booked"] * 13 // 10)
        assert r["buffer_left"] == max(r["cooked"] - r["booked"] - r["walk_ins"], 0)
        assert r["donate"] == min(max(r["cooked"] - r["served"], 0), r["buffer_left"] + r["no_shows"] // 2)

    with connect() as conn, conn.cursor() as cur:
        cur.execute("CALL sp_close_meal(%s, 3)", (today(),))
        conn.commit()
        cur.execute("SELECT m.name AS mess, d.portions FROM donations d JOIN messes m ON m.id = d.mess_id "
                    "WHERE d.meal_date = %s AND d.slot_id = 3", (today(),))
        given = {r["mess"]: r["portions"] for r in cur.fetchall()}
    expected = {(x["mess"]): x["donate"] for x in rows if x["meal_date"] == today() and x["slot_id"] == 3 and x["donate"] > 0}
    assert given == expected


def test_demo_mode_shows_the_code_and_logs_in(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(auth, "settings", dataclasses.replace(settings, firebase_project_id=None))
    phone = _phone()
    code = client.post("/auth/check", json={"phone": phone}).json()["demo_code"]
    wrong = "000000" if code != "000000" else "111111"
    assert client.post("/auth/demo-verify", json={"phone": phone, "otp": wrong}).status_code == 400
    r = client.post("/auth/demo-verify", json={"phone": phone, "otp": code})
    assert r.status_code == 200 and r.json()["student"]["phone"] == phone
    assert client.post("/auth/demo-verify", json={"phone": phone, "otp": code}).status_code == 400  # one use


def test_demo_codes_are_off_when_firebase_is_on() -> None:
    assert client.post("/auth/demo-verify", json={"phone": _phone(), "otp": "123456"}).status_code == 403


def test_workbench_bundle_matches_the_sources() -> None:
    """db/mess_complete.sql must be rebuilt (python setup.py bundle) whenever schema, seed or roster change."""
    from pathlib import Path
    db = Path(__file__).resolve().parents[2] / "db"
    bundle = (db / "mess_complete.sql").read_text(encoding="utf-8")
    assert (db / "schema.sql").read_text(encoding="utf-8") in bundle
    assert (db / "seed.sql").read_text(encoding="utf-8") in bundle
    roster = (db / "students.csv").read_text(encoding="utf-8").splitlines()[1:]
    assert all(f"'{line.split(',')[0]}'" in bundle for line in roster)
