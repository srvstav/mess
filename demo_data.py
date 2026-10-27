"""
Fill the database with one realistic day, so every view and dashboard has numbers to show.

  python demo_data.py               use backend/.env         (this laptop's MySQL)
  python demo_data.py cloud         use backend/.env.render  (the shared cloud MySQL)
  python demo_data.py live          then keep going: a new booking, change or serve every second or two,
  python demo_data.py cloud live    so the dashboard and Workbench move while you present. Ctrl+C stops it.

About 70% of the hostel students on the roster book today's 4 meals, a few are on pause,
breakfast and lunch are served, then sp_close_meal runs for those two meals so donations appear.
Safe to run more than once.
"""
from __future__ import annotations

import random
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

import pymysql
from dotenv import dotenv_values

ROOT = Path(__file__).resolve().parent
args = set(sys.argv[1:])
env_file = ROOT / "backend" / (".env.render" if "cloud" in args else ".env")
if not env_file.exists():
    sys.exit(f"{env_file.name} not found. Run setup first.")
env = dotenv_values(env_file)

ssl = None
if env.get("DB_SSL_CA_PEM"):
    ca = ROOT / "backend" / "ca.pem"
    if not ca.exists():
        ca.write_text(env["DB_SSL_CA_PEM"].replace("\\n", "\n"), encoding="utf-8")
    ssl = {"ca": str(ca)}

conn = pymysql.connect(host=env["DB_HOST"], port=int(env["DB_PORT"]), user=env["DB_USER"],
                       password=env["DB_PASSWORD"], database=env["DB_NAME"], ssl=ssl,
                       charset="utf8mb4", autocommit=False, init_command="SET time_zone = '+05:30'")
today = datetime.now(ZoneInfo("Asia/Kolkata")).date()
rng = random.Random(str(today))  # same "day" if run twice on the same date

# Share of students picking BluDove per meal (the rest pick BluSpring), and share skipping.
TASTE = {1: (0.55, 0.12), 2: (0.40, 0.08), 3: (0.62, 0.30), 4: (0.47, 0.10)}

with conn, conn.cursor() as cur:
    cur.execute("SELECT id FROM students WHERE status = 'active' ORDER BY id")
    ids = [row[0] for row in cur.fetchall()]
    if not ids:
        sys.exit("The roster is empty. Run setup first, it loads db/students.csv.")
    # Students still away from an earlier run can't book (the pause trigger would refuse), so leave them out.
    cur.execute("SELECT DISTINCT student_id FROM pauses WHERE ended_on IS NULL AND %s BETWEEN from_date AND to_date", (today,))
    on_pause = {row[0] for row in cur.fetchall()}
    ids = [i for i in ids if i not in on_pause]
    rng.shuffle(ids)
    cut = int(len(ids) * 0.7)
    away = ids[cut:cut + 12]   # a dozen students went home for a few days
    eating = ids[:cut]
    # ---------- the past 6 days: booked, served and closed, so the profit trend has a week to show ----------
    cur.execute("SELECT COUNT(*) FROM bookings WHERE meal_date = %s", (today - timedelta(days=1),))
    if cur.fetchone()[0] == 0:  # once per day is enough; re-runs leave history alone
        for back in range(6, 0, -1):
            day = today - timedelta(days=back)
            day_rng = random.Random(str(day))
            cur.execute("SELECT DISTINCT student_id FROM pauses WHERE %s BETWEEN from_date AND to_date "
                        "AND (ended_on IS NULL OR %s < ended_on)", (day, day))
            away_then = {row[0] for row in cur.fetchall()}
            pool = [i for i in ids if i not in away_then and day_rng.random() < day_rng.uniform(0.62, 0.78)]
            swing = day_rng.uniform(-0.08, 0.08)  # some days one mess is simply more popular
            rows = []
            for sid in pool:
                for slot, (dove, skip) in TASTE.items():
                    if day_rng.random() < skip:
                        rows.append((sid, day, slot, None, "skipped"))
                    else:
                        rows.append((sid, day, slot, 1 if day_rng.random() < dove + swing else 2, "booked"))
            cur.executemany("INSERT IGNORE INTO bookings (student_id, meal_date, slot_id, mess_id, status) "
                            "VALUES (%s, %s, %s, %s, %s)", rows)
            show_rate = day_rng.uniform(0.8, 0.9)
            served = [(sid, d, slot, mess) for sid, d, slot, mess, st in rows if st == "booked" and day_rng.random() < show_rate]
            cur.executemany("INSERT IGNORE INTO attendance (student_id, meal_date, slot_id, mess_id) VALUES (%s, %s, %s, %s)", served)
            conn.commit()
            for slot in TASTE:
                cur.execute("CALL sp_close_meal(%s, %s)", (day, slot))
            conn.commit()
            print(f"  {day}: {len(pool)} students, {len(served)} plates served", flush=True)

    for sid in eating:
        for slot, (dove, skip) in TASTE.items():
            r = rng.random()
            mess, status = (None, "skipped") if r < skip else ((1 if rng.random() < dove else 2), "booked")
            cur.execute(
                "INSERT INTO bookings (student_id, meal_date, slot_id, mess_id, status) VALUES (%s,%s,%s,%s,%s) AS n "
                "ON DUPLICATE KEY UPDATE mess_id = n.mess_id, status = n.status",
                (sid, today, slot, mess, status))
    conn.commit()

    for sid in away:
        cur.execute("SELECT 1 FROM pauses WHERE student_id = %s AND ended_on IS NULL AND to_date >= %s", (sid, today))
        if not cur.fetchone():
            cur.execute("CALL sp_pause_mess(%s, %s, %s)", (sid, today, today + timedelta(days=3)))

    # Breakfast and lunch are over: the face terminals saw about 85% of bookers, plus a few walk-ins.
    for slot in (1, 2):
        cur.execute("SELECT student_id, mess_id FROM bookings WHERE meal_date = %s AND slot_id = %s AND status = 'booked'",
                    (today, slot))
        for sid, mess in cur.fetchall():
            if rng.random() < 0.85:
                cur.execute("INSERT IGNORE INTO attendance (student_id, meal_date, slot_id, mess_id) VALUES (%s,%s,%s,%s)",
                            (sid, today, slot, mess))
        cur.execute("SELECT student_id FROM bookings WHERE meal_date = %s AND slot_id = %s AND status = 'skipped'",
                    (today, slot))
        for (sid,) in cur.fetchall()[:3]:  # changed their mind and walked in anyway
            cur.execute("INSERT IGNORE INTO attendance (student_id, meal_date, slot_id, mess_id) VALUES (%s,%s,%s,%s)",
                        (sid, today, slot, rng.choice((1, 2))))
        conn.commit()
        cur.execute("CALL sp_close_meal(%s, %s)", (today, slot))
    conn.commit()

    # Tomorrow: about 40% have already booked, which is what the kitchens plan their shopping from.
    tomorrow = today + timedelta(days=1)
    cur.executemany("INSERT IGNORE INTO bookings (student_id, meal_date, slot_id, mess_id, status) VALUES (%s, %s, %s, %s, 'booked')",
                    [(sid, tomorrow, slot, 1 if rng.random() < dove else 2)
                     for sid in eating if rng.random() < 0.4 for slot, (dove, _) in TASTE.items()])
    conn.commit()

    # Login rows, so v_student_directory.last_login and the LOGIN events have something to show.
    for sid in rng.sample(eating, min(40, len(eating))):
        cur.execute("INSERT INTO logins (student_id, firebase_uid) VALUES (%s, %s)", (sid, f"demo-{sid}"))
    conn.commit()

    cur.execute("SELECT meal, mess, booked, cooked, served, no_shows, walk_ins, donate FROM v_meal_summary "
                "WHERE meal_date = %s ORDER BY slot_id, mess_id", (today,))
    print(f"Demo day loaded for {today}:")
    print(f"  {'meal':<10}{'mess':<11}{'booked':>7}{'cooked':>7}{'served':>7}{'no-show':>8}{'walk-in':>8}{'donate':>7}")
    for r in cur.fetchall():
        print(f"  {r[0]:<10}{r[1]:<11}{r[2]:>7}{r[3]:>7}{r[4]:>7}{r[5]:>8}{r[6]:>8}{r[7]:>7}")

    if "live" not in args:
        sys.exit(0)

    # ---------- live: one realistic action every 1-2.5 s, through the same SQL the website uses ----------
    print("\nLive: bookings, mess switches, face-terminal serves and ratings. Watch dashboard.html or SELECT * FROM activity_log. Ctrl+C stops.", flush=True)
    live = random.Random()
    others = ids[cut + 12:]  # hadn't booked yet today

    def act() -> None:
        roll = live.random()
        if roll < 0.45 and others:  # someone logs in and books today's dinner or hi-tea
            sid, slot = others.pop(live.randrange(len(others))), live.choice((3, 4))
            cur.execute("INSERT INTO logins (student_id, firebase_uid) VALUES (%s, %s)", (sid, f"demo-{sid}"))
            cur.execute("INSERT INTO bookings (student_id, meal_date, slot_id, mess_id, status) "
                        "VALUES (%s,%s,%s,%s,'booked') AS n ON DUPLICATE KEY UPDATE mess_id = n.mess_id, status = n.status",
                        (sid, today, slot, live.choice((1, 2))))
        elif roll < 0.62:  # someone rates a meal they ate today (the trigger checks they really ate it)
            cur.execute("SELECT a.student_id, a.slot_id, a.mess_id FROM attendance a LEFT JOIN ratings r "
                        "ON r.student_id = a.student_id AND r.meal_date = a.meal_date AND r.slot_id = a.slot_id "
                        "WHERE a.meal_date = %s AND r.id IS NULL ORDER BY RAND() LIMIT 1", (today,))
            if row := cur.fetchone():
                cur.execute("INSERT INTO ratings (student_id, meal_date, slot_id, mess_id, stars) VALUES (%s,%s,%s,%s,%s)",
                            (row[0], today, row[1], row[2], live.choices((2, 3, 4, 5), (1, 2, 4, 3))[0]))
        elif roll < 0.8:  # someone switches mess for dinner
            cur.execute("UPDATE bookings SET mess_id = 3 - mess_id WHERE id = (SELECT id FROM ("
                        "SELECT id FROM bookings WHERE meal_date = %s AND slot_id = 4 AND status = 'booked' "
                        "ORDER BY RAND() LIMIT 1) x)", (today,))
        else:  # the hi-tea face terminal recognises someone who booked
            cur.execute("SELECT b.student_id, b.mess_id FROM bookings b LEFT JOIN attendance a "
                        "ON a.student_id = b.student_id AND a.meal_date = b.meal_date AND a.slot_id = b.slot_id "
                        "WHERE b.meal_date = %s AND b.slot_id = 3 AND b.status = 'booked' AND a.id IS NULL "
                        "ORDER BY RAND() LIMIT 1", (today,))
            if row := cur.fetchone():
                cur.execute("INSERT INTO attendance (student_id, meal_date, slot_id, mess_id) VALUES (%s,%s,%s,%s)",
                            (row[0], today, 3, row[1]))

    try:
        while True:
            try:
                act()
                conn.commit()
                cur.execute("SELECT DATE_FORMAT(at, '%H:%i:%s'), event, detail FROM activity_log ORDER BY id DESC LIMIT 1")
                print("  " + "  ".join(cur.fetchone()), flush=True)
            except pymysql.err.OperationalError as e:
                if e.args[0] != 1644:  # 1644 = a rule trigger said no (e.g. paused): normal, keep going
                    raise
                conn.rollback()
                print(f"  refused by the database: {e.args[1]}", flush=True)
            time.sleep(live.uniform(1.0, 2.5))
    except KeyboardInterrupt:
        print("Stopped.")
