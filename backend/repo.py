"""Repository Pattern: every SQL statement lives here, and all of them use parameters (no string-built SQL).

PyMySQL only %-formats a query when parameters are passed (args is not None), so a literal %
is written as %% in queries with parameters and as % in queries without.
"""
from datetime import date
from typing import Any

import secrets

import pymysql
from pymysql.connections import Connection

Row = dict[str, Any]


def _one(conn: Connection, sql: str, args: tuple | None = None) -> Row | None:
    with conn.cursor() as cur:
        cur.execute(sql, args)
        return cur.fetchone()


def _all(conn: Connection, sql: str, args: tuple | None = None) -> list[Row]:
    with conn.cursor() as cur:
        cur.execute(sql, args)
        return list(cur.fetchall())


def _exec(conn: Connection, sql: str, args: tuple | None = None) -> int:
    with conn.cursor() as cur:
        return cur.execute(sql, args)


# ---------- students (the roster) ----------

def student_by_phone(conn: Connection, phone: str) -> Row | None:
    return _one(conn, "SELECT id, full_name, status FROM students WHERE phone = %s", (phone,))


def enrol_guest(conn: Connection, phone: str) -> None:
    """A number that isn't on the roster joins it on first login (fires the ENROL trigger).
    Placeholder details, so a demo never stops at the door; the mess office can correct them later."""
    for reg_no in (f"9{phone[2:]}", f"98{secrets.randbelow(10**7):07d}"):  # second try only if the first is taken
        try:
            _exec(conn,
                "INSERT INTO students (reg_no, full_name, gender, phone, email, programme_id, year_of_study, "
                "hostel_id, room_no, joined_on) VALUES (%s, %s, 'M', %s, %s, 1, 1, 1, '100', CURRENT_DATE)",
                (reg_no, f"Guest {phone[-4:]}", phone, f"guest.{phone}@muj.manipal.edu"))
            return
        except pymysql.err.IntegrityError:
            continue


def record_login(conn: Connection, student_id: int, firebase_uid: str) -> None:
    _exec(conn, "INSERT INTO logins (student_id, firebase_uid) VALUES (%s, %s)", (student_id, firebase_uid))


def profile(conn: Connection, student_id: int) -> Row | None:
    return _one(conn,
        "SELECT reg_no, full_name, phone, programme, year_of_study, hostel, room_no, meals_booked, meals_eaten "
        "FROM v_student_directory WHERE id = %s", (student_id,))


def roster_counts(conn: Connection) -> Row:
    row = _one(conn,
        "SELECT COUNT(*) AS students, COUNT(DISTINCT hostel_id) AS hostels, "
        "(SELECT COUNT(DISTINCT student_id) FROM logins) AS logged_in "
        "FROM students WHERE status = 'active'")
    assert row is not None
    return {k: int(v or 0) for k, v in row.items()}


def hostel_split(conn: Connection, meal_date: date) -> list[Row]:
    return _all(conn,
        "SELECT hostel, mess, SUM(booked) AS booked FROM v_hostel_split WHERE meal_date = %s "
        "GROUP BY hostel_id, hostel, mess ORDER BY hostel_id, mess", (meal_date,))


# ---------- menu ----------

def menu(conn: Connection) -> list[Row]:
    return _all(conn,
        "SELECT m.id AS mess_id, m.name AS mess, s.id AS slot_id, s.code AS slot_code, s.name AS slot, "
        "TIME_FORMAT(s.starts_at, '%H:%i') AS starts_at, TIME_FORMAT(s.ends_at, '%H:%i') AS ends_at, i.dish "
        "FROM menu_items i JOIN messes m ON m.id = i.mess_id JOIN meal_slots s ON s.id = i.slot_id "
        "ORDER BY s.id, m.id, i.id")


def slot_exists(conn: Connection, slot_id: int) -> bool:
    return _one(conn, "SELECT 1 AS ok FROM meal_slots WHERE id = %s", (slot_id,)) is not None


def mess_exists(conn: Connection, mess_id: int) -> bool:
    return _one(conn, "SELECT 1 AS ok FROM messes WHERE id = %s", (mess_id,)) is not None


# ---------- bookings ----------

def upsert_booking(conn: Connection, student_id: int, meal_date: date, slot_id: int, mess_id: int | None) -> None:
    status = "booked" if mess_id is not None else "skipped"
    _exec(conn,
        "INSERT INTO bookings (student_id, meal_date, slot_id, mess_id, status) VALUES (%s, %s, %s, %s, %s) AS new "
        "ON DUPLICATE KEY UPDATE mess_id = new.mess_id, status = new.status",
        (student_id, meal_date, slot_id, mess_id, status))


def bookings_for(conn: Connection, student_id: int, meal_date: date) -> list[Row]:
    return _all(conn, "SELECT slot_id, mess_id, status FROM bookings WHERE student_id = %s AND meal_date = %s",
                (student_id, meal_date))


# ---------- pause / resume (stored procedures) ----------

def pause(conn: Connection, student_id: int, from_date: date, to_date: date) -> None:
    _exec(conn, "CALL sp_pause_mess(%s, %s, %s)", (student_id, from_date, to_date))


def resume(conn: Connection, student_id: int, today: date) -> None:
    _exec(conn, "CALL sp_resume_mess(%s, %s)", (student_id, today))


def active_pauses(conn: Connection, student_id: int, today: date) -> list[Row]:
    """Pauses still running or still to come."""
    return _all(conn,
        "SELECT id, from_date, to_date FROM pauses "
        "WHERE student_id = %s AND ended_on IS NULL AND to_date >= %s ORDER BY from_date",
        (student_id, today))


def is_paused(conn: Connection, student_id: int, d: date) -> bool:
    return _one(conn,
        "SELECT 1 AS ok FROM pauses WHERE student_id = %s AND %s BETWEEN from_date AND to_date "
        "AND (ended_on IS NULL OR %s < ended_on) LIMIT 1", (student_id, d, d)) is not None


# ---------- attendance and donations ----------

def eaten_for(conn: Connection, student_id: int, meal_date: date) -> list[Row]:
    """Meals the face terminals recorded for this student on this day, with their rating if any."""
    return _all(conn,
        "SELECT a.slot_id, a.mess_id, r.stars FROM attendance a LEFT JOIN ratings r "
        "ON r.student_id = a.student_id AND r.meal_date = a.meal_date AND r.slot_id = a.slot_id "
        "WHERE a.student_id = %s AND a.meal_date = %s", (student_id, meal_date))


def rate(conn: Connection, student_id: int, meal_date: date, slot_id: int, stars: int, comment: str | None) -> bool:
    """Rate a meal at the mess where it was eaten. False if it wasn't eaten (nothing to rate)."""
    eaten = _one(conn, "SELECT mess_id FROM attendance WHERE student_id = %s AND meal_date = %s AND slot_id = %s",
                 (student_id, meal_date, slot_id))
    if eaten is None:
        return False
    _exec(conn,
        "INSERT INTO ratings (student_id, meal_date, slot_id, mess_id, stars, comment) VALUES (%s, %s, %s, %s, %s, %s) AS new "
        "ON DUPLICATE KEY UPDATE stars = new.stars, comment = new.comment",
        (student_id, meal_date, slot_id, eaten["mess_id"], stars, comment))
    return True


def ratings(conn: Connection, today: date, days: int = 7) -> list[Row]:
    return _all(conn,
        "SELECT mess_id, mess, slot_id, meal, ROUND(SUM(avg_stars * ratings) / SUM(ratings), 2) AS avg_stars, "
        "SUM(ratings) AS ratings, SUM(unhappy) AS unhappy FROM v_mess_ratings "
        "WHERE meal_date BETWEEN %s - INTERVAL %s DAY AND %s "
        "GROUP BY mess_id, mess, slot_id, meal ORDER BY slot_id, mess_id", (today, days - 1, today))


def meal_summary(conn: Connection, meal_date: date) -> list[Row]:
    return _all(conn,
        "SELECT mess_id, mess, slot_id, meal, booked, cooked, served, no_shows, walk_ins, buffer_left, donate "
        "FROM v_meal_summary WHERE meal_date = %s ORDER BY slot_id, mess_id", (meal_date,))


def donations_on(conn: Connection, meal_date: date) -> list[Row]:
    return _all(conn,
        "SELECT d.slot_id, d.mess_id, ms.name AS meal, m.name AS mess, n.name AS ngo, n.area, d.portions "
        "FROM donations d JOIN messes m ON m.id = d.mess_id JOIN meal_slots ms ON ms.id = d.slot_id "
        "JOIN ngos n ON n.id = d.ngo_id WHERE d.meal_date = %s ORDER BY d.slot_id, d.mess_id", (meal_date,))


def earnings(conn: Connection, today: date, now_time: str, days: int = 7) -> list[Row]:
    """Profit per mess per meal for the last `days` days. Today counts only meals that have started,
    so a dinner that hasn't been served yet doesn't show up as a loss."""
    return _all(conn,
        "SELECT meal_date, mess_id, mess, slot_id, meal, booked, cooked, served, no_shows, donated, wasted, "
        "revenue, food_cost, profit FROM v_mess_earnings "
        "WHERE meal_date BETWEEN %s - INTERVAL %s DAY AND %s AND (meal_date < %s OR starts_at <= %s) "
        "ORDER BY meal_date, slot_id, mess_id", (today, days - 1, today, today, now_time))


def ngo_totals(conn: Connection) -> list[Row]:
    return _all(conn, "SELECT name, area, deliveries, portions FROM v_ngo_totals ORDER BY portions DESC, name")


# ---------- dashboards ----------

def recent_activity(conn: Connection, limit: int) -> list[Row]:
    return _all(conn,
        "SELECT id, DATE_FORMAT(at, '%%H:%%i:%%s') AS at, event, detail "
        "FROM activity_log ORDER BY id DESC LIMIT %s", (limit,))


def headline(conn: Connection, today: date) -> Row:
    """The three live numbers on the home page."""
    row = _one(conn,
        "SELECT (SELECT COUNT(DISTINCT student_id) FROM bookings WHERE meal_date = %s AND status <> 'paused') AS students_today, "
        "(SELECT COALESCE(SUM(portions), 0) FROM donations WHERE meal_date BETWEEN %s - INTERVAL 6 DAY AND %s) AS donated_week, "
        "(SELECT COALESCE(ROUND(AVG(stars), 1), 0) FROM ratings WHERE meal_date BETWEEN %s - INTERVAL 6 DAY AND %s) AS rating_week",
        (today, today, today, today, today))
    assert row is not None
    return {k: float(v) for k, v in row.items()}


def forecast(conn: Connection, meal_date: date) -> list[Row]:
    return _all(conn,
        "SELECT mess, meal, booked, cook_for FROM v_daily_forecast "
        "WHERE meal_date = %s ORDER BY slot_id, mess_id", (meal_date,))
