"""Build the RDBMS project report PDF: runs every query for real against the `mess` database.

  R_NAME="AYUSH SRIVASTAVA" R_REG=2502052273 R_SEC=P3 python report/source/build_report.py
Needs: local `mess` database (root, no password), Playwright + Chromium, PyMuPDF, Pillow. Output goes to ~/Downloads.
"""
import base64
import datetime as dt
import html
import re
from decimal import Decimal
from pathlib import Path

import fitz
import pymysql
from playwright.sync_api import sync_playwright

HERE = Path(__file__).parent
REPO = Path(__file__).resolve().parents[2]
import os
NAME, REG, SECTION = os.environ.get("R_NAME", "AYUSH SRIVASTAVA"), os.environ.get("R_REG", "2502052273"), os.environ.get("R_SEC", "P3")
OUT = Path.home() / "Downloads" / f"RDBMS_Project_Report_{NAME.title().replace(' ', '_')}_{REG}.pdf"
SQL_LOG = []

conn = pymysql.connect(host="127.0.0.1", user="root", password="", database="mess", charset="utf8mb4", autocommit=True,
                       init_command="SET time_zone = '+05:30'")
cur = conn.cursor()

esc = html.escape


def img(name: str) -> str:
    return "data:image/png;base64," + base64.b64encode((HERE / name).read_bytes()).decode()


def fmt(v) -> str:
    if v is None:
        return '<span class="null">NULL</span>'
    if isinstance(v, Decimal):
        return f"{v:,.2f}" if abs(v) >= 1000 else str(v)
    if isinstance(v, (dt.datetime,)):
        return v.strftime("%Y-%m-%d %H:%M:%S")
    if isinstance(v, dt.timedelta):
        s = int(v.total_seconds()); return f"{s // 3600:02d}:{s % 3600 // 60:02d}:00"
    return esc(str(v))


FIG = [0]


def run(sql: str, title: str, *, rows: int = 8, show: bool = True) -> str:
    """Execute each statement; render the SQL and the result grid / message of the last one (or each SELECT)."""
    SQL_LOG.append((title, sql.strip()))
    stmts = [s.strip() for s in re.split(r";\s*\n", sql.strip().rstrip(";")) if s.strip()]
    blocks = []
    for st in stmts:
        try:
            n = cur.execute(st)
            if cur.description:
                cols = [d[0] for d in cur.description]
                data = cur.fetchall()
                head = "".join(f"<th>{esc(c)}</th>" for c in cols)
                body = "".join("<tr>" + "".join(f"<td>{fmt(v)}</td>" for v in r) + "</tr>" for r in data[:rows])
                more = f'<div class="more">{len(data)} row(s) returned' + (f", first {rows} shown" if len(data) > rows else "") + "</div>"
                blocks.append(f'<div class="grid"><table><thead><tr><th class="rn"></th>{head}</tr></thead><tbody>'
                              + body.replace("<tr>", '<tr><td class="rn">▸</td>', ) + f"</tbody></table>{more}</div>")
            else:
                blocks.append(f'<div class="msg ok">✔ {esc(st.split()[0].upper())} … {n} row(s) affected</div>')
        except pymysql.MySQLError as e:
            blocks.append(f'<div class="msg err">✖ Error Code: {e.args[0]}. {esc(str(e.args[1]))}</div>')
    if not show:
        return ""
    FIG[0] += 1
    return (f'<figure class="q"><pre class="sql">{esc(sql.strip())}</pre><div class="out">{"".join(blocks)}</div>'
            f'<figcaption>Figure {FIG[0]}: {esc(title)}</figcaption></figure>')


def shot(name: str, caption: str, width: str = "100%") -> str:
    FIG[0] += 1
    return f'<figure class="shot"><img src="{img(name)}" style="width:{width}"><figcaption>Figure {FIG[0]}: {esc(caption)}</figcaption></figure>'


# ---------------------------------------------------------------- ER diagram + relational schema from information_schema
cur.execute("SELECT table_name FROM information_schema.tables WHERE table_schema='mess' AND table_type='BASE TABLE' ORDER BY table_name")
TABLES = [r[0] for r in cur.fetchall()]
cur.execute("SELECT table_name, column_name, column_type, column_key, is_nullable FROM information_schema.columns "
            "WHERE table_schema='mess' ORDER BY table_name, ordinal_position")
COLS = {}
for t, c, ty, k, nl in cur.fetchall():
    COLS.setdefault(t, []).append((c, ty, k, nl))
cur.execute("SELECT table_name, column_name, referenced_table_name, referenced_column_name FROM information_schema.key_column_usage "
            "WHERE table_schema='mess' AND referenced_table_name IS NOT NULL ORDER BY table_name")
FKS = cur.fetchall()
fkcols = {(t, c) for t, c, _, _ in FKS}
PRIMARY = {}
cur.execute("SELECT table_name, column_name FROM information_schema.key_column_usage WHERE table_schema='mess' AND constraint_name='PRIMARY'")
for t, c in cur.fetchall():
    PRIMARY.setdefault(t, []).append(c)

mer = ["erDiagram"]
for t in TABLES:
    if t == "activity_log":
        continue
    mer.append(f"  {t} {{")
    for c, ty, k, nl in COLS[t]:
        base = re.sub(r"\(.*", "", ty).replace(" unsigned", "")
        keys = ",".join(x for x in ("PK" if c in PRIMARY.get(t, []) else "", "FK" if (t, c) in fkcols else "", "UK" if k == "UNI" else "") if x)
        mer.append(f"    {base} {c}{(' ' + keys) if keys else ''}")
    mer.append("  }")
for t, c, rt, rc in FKS:
    mer.append(f'  {rt} ||--o{{ {t} : "{c}"')
MERMAID = "\n".join(mer)

def render_er() -> str:
    """Draw the ER diagram as SVG from information_schema (tables, columns, keys, FKs) with a fixed, readable layout."""
    W, ROW, HEAD, GAP = 270, 19, 26, 120
    # Columns ordered by dependency, so every foreign key links two NEIGHBOURING columns and no line crosses a table.
    COLUMNS = [["programmes", "hostels"], ["students"],
               ["bookings", "attendance", "ratings", "pauses", "logins", "donations"],
               ["messes", "meal_slots", "ngos"], ["mess_costs", "menu_items"]]
    height = lambda t: HEAD + ROW * len(COLS[t]) + 6  # noqa: E731
    POS = {}
    for ci, col in enumerate(COLUMNS):
        y = 20
        for t in col:
            POS[t] = (20 + ci * (W + GAP), y)
            y += height(t) + 34
    # Line the right-hand parents up with their children: ngos beside donations, messes and meal_slots beside the middle.
    POS["messes"] = (POS["messes"][0], POS["bookings"][1] + 60)
    POS["meal_slots"] = (POS["meal_slots"][0], POS["messes"][1] + height("messes") + 60)
    POS["ngos"] = (POS["ngos"][0], POS["donations"][1] + 40)
    POS["students"] = (POS["students"][0], POS["bookings"][1] + 120)
    colof = {t: ci for ci, col in enumerate(COLUMNS) for t in col}
    missing = [t for t in TABLES if t not in POS and t != "activity_log"]
    assert not missing, f"ER layout lacks tables: {missing}"
    nullable = {(t, c): nl == "YES" for t in COLS for c, ty, k, nl in COLS[t]}
    box, rowy = {}, {}
    parts = []
    for t, (x, y) in POS.items():
        cols = COLS[t]
        h = height(t)
        box[t] = (x, y, h)
        parts.append(f'<rect x="{x}" y="{y}" width="{W}" height="{h}" rx="5" fill="#fff" stroke="#222" stroke-width="1.6"/>'
                     f'<rect x="{x}" y="{y}" width="{W}" height="{HEAD}" rx="5" fill="#2b2b2b"/><rect x="{x}" y="{y + HEAD - 6}" width="{W}" height="6" fill="#2b2b2b"/>'
                     f'<text x="{x + 10}" y="{y + 18}" fill="#fff" font-weight="bold" font-size="14">{t}</text>')
        for i, (c, ty, k, nl) in enumerate(cols):
            cy = y + HEAD + 4 + ROW * i
            rowy[(t, c)] = cy + ROW / 2
            pk = c in PRIMARY.get(t, []); fk = (t, c) in fkcols
            tag = "PK, FK" if pk and fk else "PK" if pk else "FK" if fk else "UK" if k == "UNI" else ""
            base = re.sub(r"\(.*", "", ty).replace(" unsigned", "")
            weight = ' font-weight="bold"' if pk else ""
            deco = ' text-decoration="underline"' if pk else ""
            parts.append(f'<text x="{x + 10}" y="{cy + 14}" font-size="12.5"{weight}{deco}>{c}</text>'
                         f'<text x="{x + 160}" y="{cy + 14}" font-size="11" fill="#666">{base}</text>'
                         + (f'<text x="{x + W - 10}" y="{cy + 14}" font-size="10.5" text-anchor="end" fill="#8a1c1c" font-weight="bold">{tag}</text>' if tag else ""))
    lines = []
    STROKE = 'stroke="#2f4f8a" stroke-width="1.5"'
    for t, c, rt, rc in FKS:
        if t not in POS or rt not in POS:
            continue
        assert abs(colof[t] - colof[rt]) == 1, f"{t}.{c} -> {rt} is not between neighbouring columns"
        cx, _, _ = box[t]; px, _, _ = box[rt]
        y1, y2 = rowy[(t, c)], rowy[(rt, rc)]
        if px > cx:  # parent on the right: leave the child's right edge, enter the parent's left edge
            x1, x2, d1, d2 = cx + W, px, 1, -1
        else:        # parent on the left
            x1, x2, d1, d2 = cx, px + W, -1, 1
        mid = (x1 + x2) / 2
        lines.append(f'<path d="M{x1},{y1} C{mid},{y1} {mid},{y2} {x2},{y2}" fill="none" {STROKE}/>')
        # child end: crow's foot (many) with a circle (zero or more)
        lines.append(f'<path d="M{x1 + d1 * 14},{y1} L{x1},{y1 - 7} M{x1 + d1 * 14},{y1} L{x1},{y1 + 7}" fill="none" {STROKE}/>'
                     f'<circle cx="{x1 + d1 * 20}" cy="{y1}" r="4.5" fill="#fff" {STROKE}/>')
        # parent end: double bar = exactly one; bar + circle = zero or one (the foreign key may be NULL)
        if nullable[(t, c)]:
            lines.append(f'<path d="M{x2 + d2 * 8},{y2 - 7} L{x2 + d2 * 8},{y2 + 7}" {STROKE}/>'
                         f'<circle cx="{x2 + d2 * 17}" cy="{y2}" r="4.5" fill="#fff" {STROKE}/>')
        else:
            lines.append(f'<path d="M{x2 + d2 * 8},{y2 - 7} L{x2 + d2 * 8},{y2 + 7} M{x2 + d2 * 14},{y2 - 7} L{x2 + d2 * 14},{y2 + 7}" {STROKE}/>')
    Wt = max(x for x, _ in POS.values()) + W + 20
    Ht = max(y + h for x, y, h in box.values()) + 20
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{Wt}" height="{Ht}" viewBox="0 0 {Wt} {Ht}" font-family="Arial, Helvetica, sans-serif">'
           f'<rect width="100%" height="100%" fill="#fff"/>{"".join(lines)}{"".join(parts)}</svg>')
    from PIL import Image
    with sync_playwright() as pw:
        b = pw.chromium.launch(); pg = b.new_page(viewport={"width": Wt, "height": Ht}, device_scale_factor=3)
        pg.set_content(f"<html><body style='margin:0'>{svg}</body></html>")
        pg.locator("svg").screenshot(path=str(HERE / "er.png")); b.close()
    im = Image.open(HERE / "er.png")
    if im.width > im.height:
        im = im.rotate(90, expand=True)  # landscape diagram turned to fill a portrait page
    im.save(HERE / "er_rot.png")
    return img("er_rot.png")


ER_IMG = render_er()

schema_rows = []
for t in TABLES:
    cols = []
    for c, ty, k, nl in COLS[t]:
        s = esc(c)
        if c in PRIMARY.get(t, []): s = f"<u>{s}</u>"
        if (t, c) in fkcols: s = f"<i>{s}</i>*"
        cols.append(s)
    schema_rows.append(f"<p class='rel'><b>{t}</b>({', '.join(cols)})</p>")
fk_rows = "".join(f"<tr><td>{t}.{c}</td><td>{rt}.{rc}</td></tr>" for t, c, rt, rc in FKS)

cur.execute("SELECT trigger_name, action_timing, event_manipulation, event_object_table FROM information_schema.triggers WHERE trigger_schema='mess' ORDER BY event_object_table, trigger_name")
TRIGGERS = cur.fetchall()
cur.execute("SELECT routine_name, routine_type FROM information_schema.routines WHERE routine_schema='mess' ORDER BY routine_type, routine_name")
ROUTINES = cur.fetchall()
cur.execute("SELECT table_name FROM information_schema.views WHERE table_schema='mess' ORDER BY table_name")
VIEWS = [r[0] for r in cur.fetchall()]
cur.execute("SELECT COUNT(*) FROM information_schema.events WHERE event_schema='mess'")
N_EVENTS = cur.fetchone()[0]
WORDS = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty".split()
N_TABLES = len(TABLES); N_TRIG = len(TRIGGERS); N_PROC = sum(1 for _, t in ROUTINES if t == "PROCEDURE"); N_FUNC = sum(1 for _, t in ROUTINES if t == "FUNCTION")
N_VIEWS = len(VIEWS); N_FK = len(FKS)
cur.execute("SELECT VERSION()")
VERSION = cur.fetchone()[0]

counts = {}
for t in ("students", "bookings", "attendance", "donations", "activity_log", "menu_items", "programmes", "hostels", "ratings"):
    cur.execute(f"SELECT COUNT(*) FROM {t}")
    counts[t] = cur.fetchone()[0]

schema_sql = (REPO / "db" / "schema.sql").read_text()


def ddl(name: str) -> str:
    m = re.search(rf"CREATE TABLE {name} \(.*?\n\);", schema_sql, re.S)
    return esc(m.group(0))


def block(start: str, end: str) -> str:
    a = schema_sql.index(start); b = schema_sql.index(end, a) + len(end)
    return esc(schema_sql[a:b])


# ---------------------------------------------------------------- queries (run now, in this order)
Q = {}
Q["show"] = run("SHOW FULL TABLES", "List of tables and views in the database", rows=21)
Q["desc"] = run("DESCRIBE students", "Structure of the table students", rows=13)
Q["alter"] = run("""ALTER TABLE students ADD COLUMN blood_group VARCHAR(3) NULL AFTER gender;
SELECT column_name, column_type, is_nullable FROM information_schema.columns
WHERE table_schema = 'mess' AND table_name = 'students' AND column_name = 'blood_group';
ALTER TABLE students DROP COLUMN blood_group""", "DDL: addition and removal of a column with ALTER TABLE")
Q["count"] = run("""SELECT (SELECT COUNT(*) FROM students) AS students,
       (SELECT COUNT(*) FROM bookings) AS bookings,
       (SELECT COUNT(*) FROM attendance) AS meals_served,
       (SELECT COUNT(*) FROM donations) AS donations,
       (SELECT COUNT(*) FROM activity_log) AS log_rows""", "Number of rows in the principal tables")

for child in ("ratings", "attendance", "bookings", "pauses", "logins"):  # children first: foreign keys
    cur.execute(f"DELETE FROM {child} WHERE student_id IN (SELECT id FROM students WHERE phone = '9876500001')")
cur.execute("DELETE FROM students WHERE phone = '9876500001'")
Q["insert"] = run("""INSERT INTO students (reg_no, full_name, gender, phone, email, programme_id,
                      year_of_study, hostel_id, room_no, joined_on)
VALUES ('250105227', 'Rohan Mehta', 'M', '9876500001',
        'rohan.250105227@muj.manipal.edu', 1, 2, 4, '412', '2025-07-21');
SELECT reg_no, full_name, programme, year_of_study, hostel, room_no
FROM v_student_directory WHERE phone = '9876500001'""", "Insertion of a student record and its retrieval through a view")
Q["update"] = run("""UPDATE students SET room_no = '415' WHERE phone = '9876500001';
SELECT event, detail FROM activity_log
WHERE student_id = (SELECT id FROM students WHERE phone = '9876500001')""", "Updation of a record and the corresponding audit entry generated by a trigger")
cur.execute("SELECT a.student_id, a.slot_id, a.mess_id FROM attendance a WHERE a.meal_date = CURDATE() "
            "AND NOT EXISTS (SELECT 1 FROM ratings r WHERE r.student_id = a.student_id AND r.meal_date = a.meal_date "
            "AND r.slot_id = a.slot_id) ORDER BY a.student_id LIMIT 1")
R_SID, R_SLOT, R_MESS = cur.fetchone()
Q["rate_ok"] = run(f"""INSERT INTO ratings (student_id, meal_date, slot_id, mess_id, stars)
VALUES ({R_SID}, CURDATE(), {R_SLOT}, {R_MESS}, 4);
SELECT r.stars, ms.name AS meal, m.name AS mess, a.served_at
FROM ratings r
JOIN attendance a  ON a.student_id = r.student_id AND a.meal_date = r.meal_date AND a.slot_id = r.slot_id
JOIN meal_slots ms ON ms.id = r.slot_id
JOIN messes m      ON m.id = r.mess_id
WHERE r.student_id = {R_SID} AND r.meal_date = CURDATE()""", "Insertion of a rating for a meal that the student has eaten")
Q["delete"] = run(f"""DELETE FROM ratings
WHERE student_id = {R_SID} AND meal_date = CURDATE() AND slot_id = {R_SLOT};
SELECT COUNT(*) AS remaining FROM ratings
WHERE student_id = {R_SID} AND meal_date = CURDATE()""", "DML: deletion of a record with DELETE")
cur.execute("SELECT s.id FROM students s WHERE NOT EXISTS (SELECT 1 FROM attendance a WHERE a.student_id = s.id AND a.meal_date = CURDATE() AND a.slot_id = 4) ORDER BY s.id LIMIT 1")
NOEAT = cur.fetchone()[0]
Q["rate_no"] = run(f"""INSERT INTO ratings (student_id, meal_date, slot_id, mess_id, stars)
VALUES ({NOEAT}, CURDATE(), 4, 1, 5)""", "Rejection by the trigger trg_rating_check_ins: rating of a meal not eaten")
Q["v_ratings"] = run("""SELECT meal, mess,
       ROUND(SUM(avg_stars * ratings) / SUM(ratings), 2) AS avg_stars,
       SUM(ratings) AS ratings, SUM(unhappy) AS one_or_two_stars
FROM v_mess_ratings
WHERE meal_date >= CURDATE() - INTERVAL 6 DAY
GROUP BY slot_id, meal, mess_id, mess
ORDER BY slot_id, mess_id""", "View v_mess_ratings: average rating of each mess for each meal over seven days")
Q["select"] = run("""SELECT reg_no, full_name, year_of_study, room_no
FROM students
WHERE hostel_id = (SELECT id FROM hostels WHERE name = 'G1') AND year_of_study = 2
ORDER BY full_name
LIMIT 6""", "Selection with WHERE, ORDER BY and LIMIT clauses")
Q["join"] = run("""SELECT b.meal_date, ms.name AS meal, COALESCE(m.name, '-') AS mess, b.status
FROM bookings b
JOIN students s     ON s.id = b.student_id
JOIN meal_slots ms  ON ms.id = b.slot_id
LEFT JOIN messes m  ON m.id = b.mess_id
WHERE s.phone = '7000000001'
ORDER BY b.meal_date DESC, ms.id
LIMIT 8""", "Inner and left outer joins across four tables: bookings of a student")
Q["group"] = run("""SELECT ms.name AS meal,
       SUM(b.mess_id = 1)          AS bludove,
       SUM(b.mess_id = 2)          AS bluspring,
       SUM(b.status = 'skipped')   AS skipped,
       ROUND(100 * SUM(b.mess_id = 1) / SUM(b.status = 'booked'), 1) AS bludove_pct
FROM bookings b JOIN meal_slots ms ON ms.id = b.slot_id
WHERE b.meal_date = CURDATE() - INTERVAL 1 DAY
GROUP BY ms.id, ms.name
ORDER BY ms.id""", "Grouping with conditional aggregation: distribution of the previous day's bookings between the messes")
Q["having"] = run("""SELECT h.name AS hostel, COUNT(*) AS plates_booked
FROM bookings b
JOIN students s ON s.id = b.student_id
JOIN hostels h  ON h.id = s.hostel_id
WHERE b.status = 'booked'
GROUP BY h.id, h.name
HAVING COUNT(*) > (SELECT AVG(n) FROM (SELECT COUNT(*) AS n FROM bookings b2
                   JOIN students s2 ON s2.id = b2.student_id
                   WHERE b2.status = 'booked' GROUP BY s2.hostel_id) x)
ORDER BY plates_booked DESC""", "HAVING clause with a nested subquery: hostels with bookings above the average")
Q["rollup"] = run("""SELECT p.code AS programme, s.year_of_study AS yr, COUNT(*) AS students
FROM students s JOIN programmes p ON p.id = s.programme_id
WHERE p.code IN ('BTECH-CSE', 'BBA')
GROUP BY p.code, s.year_of_study WITH ROLLUP""", "GROUP BY with ROLLUP: subtotals by programme and the grand total", rows=12)
Q["corr"] = run("""SELECT s.reg_no, fn_short_name(s.full_name) AS student, ms.name AS meal, m.name AS ate_at
FROM attendance a
JOIN students s    ON s.id = a.student_id
JOIN meal_slots ms ON ms.id = a.slot_id
JOIN messes m      ON m.id = a.mess_id
WHERE NOT EXISTS (SELECT 1 FROM bookings b
                  WHERE b.student_id = a.student_id AND b.meal_date = a.meal_date
                    AND b.slot_id = a.slot_id AND b.mess_id = a.mess_id AND b.status = 'booked')
LIMIT 6""", "Correlated subquery (NOT EXISTS): students served without a booking at that mess")
Q["func"] = run("""SELECT full_name,
       fn_short_name(full_name)               AS public_name,
       UPPER(LEFT(full_name, 1))              AS initial,
       CONCAT('+91 ', LEFT(phone, 5), ' ', RIGHT(phone, 5)) AS phone_pretty,
       TIMESTAMPDIFF(MONTH, joined_on, CURDATE()) AS months_at_muj,
       DATE_FORMAT(joined_on, '%d %b %Y')     AS joined
FROM students ORDER BY id LIMIT 5""", "Built-in string and date functions and the user-defined function fn_short_name")
Q["view1"] = run("""SELECT meal, mess, booked, cook_for
FROM v_daily_forecast
WHERE meal_date = CURDATE()
ORDER BY slot_id, mess_id""", "View v_daily_forecast: quantity to be prepared by each mess for the current day")
Q["view2"] = run("""SELECT meal, mess, booked, cooked, served, no_shows, walk_ins, donate
FROM v_meal_summary
WHERE meal_date = CURDATE() - INTERVAL 1 DAY
ORDER BY slot_id, mess_id""", "View v_meal_summary: meals served, absentees, walk-ins and surplus for donation")
Q["view3"] = run("""SELECT mess,
       SUM(served)    AS plates_served,
       SUM(revenue)   AS revenue,
       SUM(food_cost) AS food_cost,
       SUM(profit)    AS profit,
       ROUND(100 * SUM(profit) / SUM(revenue), 1) AS margin_pct
FROM v_mess_earnings
WHERE meal_date BETWEEN CURDATE() - INTERVAL 6 DAY AND CURDATE() - INTERVAL 1 DAY
GROUP BY mess_id, mess""", "View v_mess_earnings: revenue, cost and profit of each mess over six days")
Q["view4"] = run("""SELECT hostel, mess, SUM(booked) AS plates
FROM v_hostel_split
WHERE meal_date = CURDATE() AND hostel IN ('B1', 'B2', 'G1', 'G2')
GROUP BY hostel_id, hostel, mess
ORDER BY hostel_id, mess""", "View v_hostel_split: distribution of hostels between the two messes")

# advanced
Q["tx"] = run("""START TRANSACTION;
UPDATE mess_costs SET cost_per_plate = cost_per_plate * 1.10 WHERE mess_id = 1;
SELECT slot_id, cost_per_plate FROM mess_costs WHERE mess_id = 1;
ROLLBACK;
SELECT slot_id, cost_per_plate FROM mess_costs WHERE mess_id = 1""", "Transaction control: modification followed by ROLLBACK")
# a student with bookings today and no pause, so the procedure has meals to release
cur.execute("SELECT b.student_id FROM bookings b WHERE b.meal_date = CURDATE() AND b.status = 'booked' "
            "AND NOT EXISTS (SELECT 1 FROM pauses p WHERE p.student_id = b.student_id) "
            "GROUP BY b.student_id HAVING COUNT(*) >= 3 ORDER BY b.student_id LIMIT 1")
sid5 = cur.fetchone()[0]
cur.execute("CALL sp_resume_mess(%s, CURDATE())", (sid5,))
Q["savepoint"] = run("""START TRANSACTION;
UPDATE meal_slots SET paid_per_plate = paid_per_plate + 5 WHERE id = 1;
SAVEPOINT after_breakfast;
UPDATE meal_slots SET paid_per_plate = paid_per_plate + 5 WHERE id = 2;
ROLLBACK TO SAVEPOINT after_breakfast;
SELECT id, name, paid_per_plate FROM meal_slots WHERE id IN (1, 2);
ROLLBACK""", "Partial rollback with SAVEPOINT: only the second update is undone")
Q["events"] = run("""SELECT event_name, interval_value, interval_field, status, event_definition
FROM information_schema.events WHERE event_schema = 'mess';
CALL sp_close_finished_meals();
SELECT ms.name AS meal, m.name AS mess, n.name AS ngo, d.portions
FROM donations d JOIN meal_slots ms ON ms.id = d.slot_id
JOIN messes m ON m.id = d.mess_id JOIN ngos n ON n.id = d.ngo_id
WHERE d.meal_date = CURDATE() ORDER BY d.slot_id, d.mess_id""", "Scheduled event ev_close_meals and the procedure it executes")
Q["trg_list"] = run("""SELECT trigger_name, action_timing AS timing, event_manipulation AS event, event_object_table AS on_table
FROM information_schema.triggers
WHERE trigger_schema = 'mess'
ORDER BY event_object_table, trigger_name""", "Triggers defined in the database", rows=20)
Q["trg_gender"] = run("""INSERT INTO students (reg_no, full_name, gender, phone, email, programme_id,
                      year_of_study, hostel_id, room_no, joined_on)
VALUES ('230100998', 'Wrong Hostel', 'M', '9876501235',
        'w@muj.manipal.edu', 1, 1, 13, '101', '2023-07-24')""", "Rejection by a BEFORE INSERT trigger: allotment of a female hostel to a male student")
Q["chk"] = run("""INSERT INTO students (reg_no, full_name, gender, phone, email, programme_id,
                      year_of_study, hostel_id, room_no, joined_on)
VALUES ('230100996', 'Bad Phone', 'M', '12345',
        'p@muj.manipal.edu', 1, 1, 1, '101', '2023-07-24')""", "Rejection by the CHECK constraint chk_phone: invalid mobile number")
Q["proc_before"] = run(f"""SELECT meal_date, slot_id, mess_id, status FROM bookings
WHERE student_id = {sid5} AND meal_date = CURDATE() ORDER BY slot_id""", "Bookings of a student before the declaration of leave")
Q["proc_pause"] = run(f"""CALL sp_pause_mess({sid5}, CURDATE(), CURDATE() + INTERVAL 1 DAY);
SELECT meal_date, slot_id, mess_id, status FROM bookings
WHERE student_id = {sid5} AND meal_date = CURDATE() ORDER BY slot_id""", "Execution of the stored procedure sp_pause_mess")
Q["proc_block"] = run(f"""INSERT INTO bookings (student_id, meal_date, slot_id, mess_id, status)
VALUES ({sid5}, CURDATE(), 4, 1, 'booked')
ON DUPLICATE KEY UPDATE mess_id = 1, status = 'booked'""", "Rejection of a booking during leave by a trigger (SIGNAL SQLSTATE '45000')")
Q["proc_resume"] = run(f"""CALL sp_resume_mess({sid5}, CURDATE());
SELECT event, detail FROM activity_log WHERE student_id = {sid5} ORDER BY id DESC LIMIT 4""", "Execution of sp_resume_mess and the resulting audit entries")
Q["proc_close"] = run("""CALL sp_close_meal(CURDATE() - INTERVAL 1 DAY, 2);
SELECT n.name AS ngo, n.area, d.portions, m.name AS mess
FROM donations d JOIN ngos n ON n.id = d.ngo_id JOIN messes m ON m.id = d.mess_id
WHERE d.meal_date = CURDATE() - INTERVAL 1 DAY AND d.slot_id = 2""", "Execution of the stored procedure sp_close_meal: allocation of surplus to NGOs")
Q["routines"] = run("""SELECT routine_name, routine_type, is_deterministic
FROM information_schema.routines WHERE routine_schema = 'mess'
ORDER BY routine_type, routine_name""", "Stored procedures and function defined in the database")
Q["grants"] = run("""SHOW GRANTS FOR 'mess_app'@'localhost'""", "Privileges granted to the application user mess_app")
Q["viewer"] = run("""DROP USER IF EXISTS 'mess_viewer'@'localhost';
CREATE USER 'mess_viewer'@'localhost' IDENTIFIED BY 'Viewer#2026';
GRANT SELECT ON mess.v_daily_forecast TO 'mess_viewer'@'localhost';
GRANT SELECT ON mess.v_mess_earnings TO 'mess_viewer'@'localhost';
GRANT SELECT ON mess.v_mess_ratings TO 'mess_viewer'@'localhost';
REVOKE SELECT ON mess.v_mess_earnings FROM 'mess_viewer'@'localhost';
SHOW GRANTS FOR 'mess_viewer'@'localhost'""", "Creation of a read-only user, GRANT of privileges on views and REVOKE of one privilege")
Q["live"] = run("""SELECT id, DATE_FORMAT(at, '%H:%i:%s') AS time, event, detail
FROM activity_log ORDER BY id DESC LIMIT 8""", "Audit log maintained by triggers")
FIG_AFTER_QUERIES = FIG[0]

# ---------------------------------------------------------------- the document
TODAY = dt.date.today().strftime("%d %B %Y")
sec = lambda n, t: f'<h1 id="s{n}">{n}. {t}</h1>'  # noqa: E731

body = f"""
<section class="cover">
  <p class="a">A</p>
  <p class="pr">PROJECT REPORT</p>
  <p class="on">On</p>
  <p class="title">Design and Implementation of a Hostel Mess Management System using MySQL</p>
  <p class="sub">Submitted in partial fulfillment of the requirements for the award of the degree of</p>
  <p class="deg">BACHELOR OF TECHNOLOGY</p>
  <p class="in">in</p>
  <p class="br">Computer Science &amp; Engineering</p>
  <p class="sb">Submitted By:</p>
  <p class="nm">{NAME}</p>
  <p class="nm">Registration Number: {REG}</p>
  <p class="nm">Section: {SECTION}</p>
  <p class="subj">Subject Name: Relational Database Management Systems</p>
  <img class="logo" src="{img('logo_16.png')}">
  <p class="sch">School of Computer Science and Engineering</p>
  <p class="dep">Department of Computer Science and Engineering</p>
  <p class="dep">Manipal University Jaipur</p>
  <p class="plain">Jaipur, Rajasthan</p>
  <p class="plain">July–December 2026</p>
</section>

<section class="toc">
  <h1 class="nonum">Table of Contents</h1>
  <table class="toct">{{TOC}}</table>
</section>

{sec(1, "Introduction")}
<p>Manipal University Jaipur operates two hostel messes, namely BluDove and BluSpring. Under the existing arrangement, every resident student pays a common annual mess fee and is required to register with one of the two messes for a fixed period of two months. During this period the student may take meals only at the registered mess. This arrangement restricts the choice available to students and, since neither mess has advance information about the number of students who will actually attend a given meal, the quantity of food prepared is estimated rather than planned. A considerable portion of the prepared food is consequently wasted.</p>
<p>The present project, titled <b>Design and Implementation of a Hostel Mess Management System using MySQL</b>, addresses these limitations through a relational database application. The annual fee remains unchanged; however, for each of the four daily meals (breakfast, lunch, hi-tea and dinner) a student may select either mess, or indicate that the meal will be skipped, up to seven days in advance. Since every selection is recorded in the database, each mess is able to determine precisely how many meals are to be prepared. The quantity prepared is computed as the number of confirmed bookings together with a buffer of thirty percent for students who arrive without a booking. Attendance at each meal is recorded by the face-recognition terminals already installed at both messes, students rate the meals they have eaten, and the surplus food remaining after each meal is allocated automatically to non-governmental organisations (NGOs) operating near the campus.</p>
<p>The core of the system is a MySQL 8 database consisting of {WORDS[N_TABLES]} tables in the Third Normal Form, {WORDS[N_TRIG]} triggers, {WORDS[N_PROC]} stored procedures, {WORDS[N_FUNC]} stored function, {WORDS[N_VIEWS]} views and {WORDS[N_EVENTS]} scheduled event. All significant business rules, such as the restriction of one selection per student per meal, the prohibition of bookings during a declared leave period and the requirement that a student be allotted a hostel corresponding to the student's gender, are enforced within the database itself. A web-based interface for students and an analytical dashboard for the management of both messes have been developed over the database by means of a Python (FastAPI) service; nevertheless, the logic of the application resides in SQL and can be demonstrated entirely through MySQL Workbench.</p>

{sec(2, "Objectives")}
<p>The principal objectives of the project are as follows:</p>
<ol>
<li>To design a normalised relational database that records students, hostels, academic programmes, messes, meals, bookings, attendance and donations without redundancy.</li>
<li>To permit every student to select a mess independently for each meal of the day, in place of a fixed two-month registration.</li>
<li>To provide each mess with an accurate forecast of the quantity of food to be prepared, derived from bookings through a database view.</li>
<li>To enforce data integrity through primary keys, foreign keys, unique keys, CHECK constraints and triggers, so that invalid data cannot be stored by any application.</li>
<li>To implement multi-step operations, such as suspending a student's meals during leave, as stored procedures executed within transactions, thereby guaranteeing atomicity.</li>
<li>To close every meal automatically at the end of its serving period by means of a scheduled database event, and to allocate the surplus food equitably among partner NGOs.</li>
<li>To collect students' ratings of the meals they have eaten, admitting a rating only for a meal actually served, so that each mess can monitor the quality of its food.</li>
<li>To furnish the management of each mess with information on revenue, food cost, profit, wastage and absenteeism.</li>
<li>To secure the database by means of parameterised queries and a database user granted only the minimum necessary privileges.</li>
</ol>
<p><b>Expected outcome:</b> a fully functional, normalised database integrated with a web application, in which every transaction performed by a user is reflected immediately in the database and every business rule is demonstrably enforced by the database management system.</p>

{sec(3, "Features and Functionality")}
<h2>3.1 Student Module</h2>
<ul>
<li><b>Authentication:</b> the student logs in with a mobile number and a six-digit one-time password. A mobile number not yet present in the database is registered automatically at the first login, which in turn invokes the enrolment trigger.</li>
<li><b>Menu display:</b> the menu of both messes is displayed for each meal of the day.</li>
<li><b>Meal booking:</b> for each meal the student selects BluDove, BluSpring or Skip, for the current day and the following seven days. A change of selection updates the existing record by means of <code>INSERT … ON DUPLICATE KEY UPDATE</code>, since a unique key permits only one record per student per meal.</li>
<li><b>Leave management:</b> the student may suspend meals for a period of leave through the stored procedure <code>sp_pause_mess</code> and may resume them early through <code>sp_resume_mess</code>.</li>
</ul>
<h2>3.2 Attendance and Automatic Closure of Meals</h2>
<ul>
<li><b>Recording of attendance:</b> both messes have face-recognition terminals at the serving counter. On recognising a student, the terminal inserts a record into the <code>attendance</code> table; a student served without a booking at that mess is identified as a walk-in.</li>
<li><b>Automatic closure of a meal:</b> the scheduled event <code>ev_close_meals</code> runs every ten minutes and invokes <code>sp_close_finished_meals</code>, which closes every meal whose serving period has ended by calling <code>sp_close_meal</code>. The latter computes the surplus and records its donation to an NGO. No manual action is required.</li>
</ul>
<h2>3.3 Meal Rating Module</h2>
<ul>
<li>After a meal recorded by the face-recognition terminal, the student may rate it from one to five stars on the booking page.</li>
<li>The rating is stored in the table <code>ratings</code>. A BEFORE trigger admits the rating only if a corresponding attendance record exists, and a CHECK constraint restricts the value to the range one to five.</li>
<li>The view <code>v_mess_ratings</code> provides the average rating of each mess for each meal, which the management dashboard presents as a ratings board.</li>
</ul>
<h2>3.4 Management Module</h2>
<ul>
<li>Revenue, food cost, profit, profit margin, wastage and absenteeism of each mess over the preceding seven days, obtained from the view <code>v_mess_earnings</code>.</li>
<li>Bookings received for the following day and the corresponding quantity to be prepared, obtained from the view <code>v_daily_forecast</code>, for the planning of procurement.</li>
<li>The average rating of each mess for each meal over the preceding seven days, obtained from the view <code>v_mess_ratings</code>.</li>
<li>A meal-wise summary of the current day, the distribution of hostels between the two messes, the record of donations, and an activity log maintained exclusively by triggers.</li>
</ul>
<h2>3.5 Database Operations Employed</h2>
<table class="plain">
<tr><th>Category of operation</th><th>Application in the project</th></tr>
<tr><td>DDL: CREATE TABLE, VIEW, TRIGGER, PROCEDURE, FUNCTION; CREATE USER; GRANT</td><td>Definition of the schema (db/schema.sql) and of database users</td></tr>
<tr><td>DDL: ALTER TABLE, DROP; DML: INSERT, UPDATE, DELETE, INSERT … ON DUPLICATE KEY UPDATE</td><td>Login, booking, attendance, ratings, leave management</td></tr>
<tr><td>Joins, subqueries, correlated subqueries, UNION, GROUP BY, HAVING, WITH ROLLUP</td><td>Views and reports</td></tr>
<tr><td>Transactions with rollback on error and savepoints; cursors; loops</td><td>sp_pause_mess, sp_resume_mess, sp_close_meal, sp_close_finished_meals, sp_demo_week</td></tr>
<tr><td>Scheduled events (CREATE EVENT)</td><td>ev_close_meals: automatic closure of finished meals</td></tr>
<tr><td>CREATE USER, GRANT, REVOKE</td><td>Least-privilege application user; read-only management user</td></tr>
<tr><td>BEFORE and AFTER triggers; SIGNAL SQLSTATE</td><td>Enforcement of business rules and maintenance of the audit log</td></tr>
</table>

{sec(4, "Tools and Technologies Used")}
<table class="plain">
<tr><th>Tool / Technology</th><th>Purpose</th></tr>
<tr><td><b>MySQL Server 8</b> (InnoDB storage engine)</td><td>Relational database management system used for tables, constraints, triggers, stored procedures, functions, views and users. The system has been tested on MySQL 8.0 (Windows) and {esc(VERSION)} (macOS).</td></tr>
<tr><td><b>MySQL Workbench</b></td><td>Development and execution of SQL statements, inspection of result sets, generation of the ER diagram by reverse engineering, and demonstration of the project.</td></tr>
<tr><td><b>Structured Query Language</b> (MySQL dialect)</td><td>Definition of the complete schema and business logic.</td></tr>
<tr><td><b>Python 3.12, FastAPI and PyMySQL</b></td><td>Application programming interface between the web pages and the database. All queries are parameterised and no object-relational mapper is employed, so that the SQL remains explicit.</td></tr>
<tr><td><b>HTML, CSS and JavaScript</b></td><td>User interfaces for students (booking and rating) and for the management of the messes (dashboard).</td></tr>
<tr><td><b>Git and GitHub</b></td><td>Version control and automated verification of the installation procedure on Windows.</td></tr>
<tr><td><b>pytest</b></td><td>Automated tests (twenty-three in number) verifying the rules enforced by the database.</td></tr>
</table>

{sec(5, "ER Diagram and Relational Model")}
<h2>5.1 Entities and Attributes</h2>
<table class="plain">
<tr><th>Entity (table)</th><th>Description</th><th>Principal attributes</th></tr>
<tr><td>programmes</td><td>Academic programme of study</td><td>id (PK), code (UNIQUE), name, school, years</td></tr>
<tr><td>hostels</td><td>Hostel block; B1–B12 for male and G1–G10 for female students</td><td>id (PK), name (UNIQUE), for_gender, rooms</td></tr>
<tr><td>students</td><td>Student enrolled with the university</td><td>id (PK), reg_no, phone, email (UNIQUE), programme_id (FK), hostel_id (FK), room_no</td></tr>
<tr><td>logins</td><td>Successful login of a student</td><td>id (PK), student_id (FK), firebase_uid, at</td></tr>
<tr><td>messes</td><td>Mess (BluDove or BluSpring)</td><td>id (PK), name (UNIQUE)</td></tr>
<tr><td>meal_slots</td><td>Meal of the day with its timing</td><td>id (PK), starts_at, ends_at, paid_per_plate</td></tr>
<tr><td>mess_costs</td><td>Cost of preparing one plate at a mess for a meal</td><td>(mess_id, slot_id) composite PK; both FK</td></tr>
<tr><td>menu_items</td><td>Dish offered by a mess at a meal</td><td>id (PK), mess_id (FK), slot_id (FK), dish</td></tr>
<tr><td>bookings</td><td>Selection made by a student for a meal on a date</td><td>id (PK), UNIQUE (student_id, meal_date, slot_id), status</td></tr>
<tr><td>pauses</td><td>Period of leave of a student</td><td>id (PK), student_id (FK), from_date, to_date, ended_on</td></tr>
<tr><td>attendance</td><td>Meal actually served to a student</td><td>id (PK), UNIQUE (student_id, meal_date, slot_id), mess_id (FK)</td></tr>
<tr><td>ratings</td><td>Rating of a meal by a student who ate it</td><td>id (PK), UNIQUE (student_id, meal_date, slot_id), mess_id (FK), stars (CHECK 1–5)</td></tr>
<tr><td>ngos</td><td>Partner non-governmental organisation</td><td>id (PK), name (UNIQUE), area</td></tr>
<tr><td>donations</td><td>Surplus of a mess for a meal, donated to an NGO</td><td>id (PK), UNIQUE (meal_date, slot_id, mess_id), ngo_id (FK)</td></tr>
<tr><td>activity_log</td><td>Audit record, written exclusively by triggers</td><td>id (PK), at, event, student_id, detail</td></tr>
</table>
<h2>5.2 Relationships</h2>
<p>All relationships in the model are of the one-to-many type. A programme and a hostel are each associated with many students. A student is associated with many bookings, periods of leave, attendance records, ratings and logins. A mess and a meal slot each participate in many menu items, bookings, attendance records, ratings and donations, and an NGO receives many donations. The relationship between messes and meal slots is many-to-many with respect to cost; it is resolved by the associative entity <code>mess_costs</code>, whose primary key is the composite of the two foreign keys. Each connector in the following diagram corresponds to a FOREIGN KEY constraint defined in the database.</p>
<figure class="shot er"><img src="{ER_IMG}"><figcaption>Figure {{ERFIG}}: Entity-Relationship diagram of the database (PK: primary key, FK: foreign key, UK: unique key). The table activity_log is omitted, as it is an audit table without foreign keys.</figcaption></figure>
<h2>5.3 Relational Schema</h2>
<p>In the following schema, primary keys are underlined and foreign keys are shown in italics and marked with an asterisk (*).</p>
{''.join(schema_rows)}
<h2>5.4 Foreign Keys</h2>
<table class="plain small"><tr><th>Foreign key</th><th>References</th></tr>{fk_rows}</table>
<h2>5.5 Normalisation</h2>
<p><b>First Normal Form (1NF):</b> every attribute holds an atomic value. The dishes of a meal are stored as separate rows of <code>menu_items</code> rather than as a list, and the four meals of a student are stored as four rows of <code>bookings</code> rather than as four columns. <b>Second Normal Form (2NF):</b> no non-key attribute depends on a part of a composite key. In <code>mess_costs</code>, whose key is (mess_id, slot_id), the attribute cost_per_plate depends on the complete key. <b>Third Normal Form (3NF):</b> no non-key attribute depends transitively on the key. The gender of a hostel is stored only in <code>hostels</code> and is not repeated in <code>students</code>. Derived quantities, such as the quantity to be prepared, the profit and the last login of a student, are computed through views and are not stored, which eliminates the possibility of inconsistency.</p>

{sec(6, "Database Implementation")}
<h2>6.1 Table Creation, Data Types and Constraints</h2>
<p>All tables employ the InnoDB storage engine, which supports foreign keys and transactions, and the <code>utf8mb4</code> character set. Data types have been selected according to the nature of the data: <code>TINYINT UNSIGNED</code> for small reference tables, <code>INT UNSIGNED</code> for students and bookings, <code>BIGINT</code> for the audit log, <code>CHAR(10)</code> for mobile numbers, <code>DECIMAL(6,2)</code> for monetary values, <code>DATE</code>, <code>TIME</code> and <code>DATETIME(3)</code> for temporal values, and <code>ENUM</code> for attributes with a fixed set of values. The definitions of the two principal tables are reproduced below.</p>
<pre class="code">{ddl('students')}</pre>
<pre class="code">{ddl('bookings')}</pre>
<table class="plain">
<tr><th>Constraint</th><th>Instance in the database</th><th>Purpose</th></tr>
<tr><td>PRIMARY KEY</td><td>Every table; composite key in mess_costs</td><td>Unique identification of each row</td></tr>
<tr><td>FOREIGN KEY</td><td>bookings.student_id → students.id ({WORDS[N_FK]} in total)</td><td>Referential integrity</td></tr>
<tr><td>UNIQUE</td><td>bookings (student_id, meal_date, slot_id)</td><td>Only one selection per student per meal</td></tr>
<tr><td>CHECK</td><td>chk_phone, chk_status_mess, chk_pause_range, chk_slot_time, chk_stars</td><td>Validity of mobile numbers, consistency of status, valid date ranges and timings, ratings from one to five</td></tr>
<tr><td>NOT NULL / DEFAULT</td><td>students.hostel_id NOT NULL; created_at DEFAULT CURRENT_TIMESTAMP(3)</td><td>Completeness of data</td></tr>
<tr><td>Triggers</td><td>trg_student_check_ins, trg_booking_paused_ins, trg_rating_check_ins</td><td>Rules involving more than one table, which cannot be expressed as CHECK constraints</td></tr>
</table>
<h2>6.2 Population of the Database</h2>
<p>The installation script loads the reference data, namely two messes, four meals, {counts['menu_items']} dishes, {counts['programmes']} academic programmes, {counts['hostels']} hostels and three NGOs, together with a roster of {counts['students']:,} students. The stored procedure <code>sp_demo_week</code> subsequently generates the activity of one week entirely in SQL. At the time of preparation of this report, the database contains {counts['bookings']:,} bookings, {counts['attendance']:,} records of meals served, {counts['ratings']:,} ratings, {counts['donations']} donations and {counts['activity_log']:,} audit records.</p>
<h2>6.3 Data Manipulation Performed by the Application</h2>
<pre class="code">-- Booking or modification of a meal (one row per student per meal, maintained by the UNIQUE key)
INSERT INTO bookings (student_id, meal_date, slot_id, mess_id, status)
VALUES (%s, %s, %s, %s, %s) AS new
ON DUPLICATE KEY UPDATE mess_id = new.mess_id, status = new.status;

-- Recording of a meal served (performed by the face-recognition terminal)
INSERT INTO attendance (student_id, meal_date, slot_id, mess_id) VALUES (%s, %s, %s, %s);

-- Rating of a meal eaten (admitted only if the attendance record exists)
INSERT INTO ratings (student_id, meal_date, slot_id, mess_id, stars, comment) VALUES (%s, %s, %s, %s, %s, %s) AS new
ON DUPLICATE KEY UPDATE stars = new.stars, comment = new.comment;

-- Recording of a login (invokes the LOGIN trigger)
INSERT INTO logins (student_id, firebase_uid) VALUES (%s, %s);</pre>
<p>The placeholders (<code>%s</code>) are bound by the database driver and are never concatenated into the SQL text; the application is therefore not susceptible to SQL injection.</p>

{sec(7, "SQL Queries and Outputs")}
<p>Each query presented in this section was executed on the project database, and the result shown is the output obtained.</p>
<h2>7.1 Data Definition and Database Structure</h2>
{Q['show']}{Q['desc']}{Q['alter']}{Q['count']}
<h2>7.2 Data Manipulation: Insertion, Updation and Deletion</h2>
{Q['insert']}{Q['update']}{Q['rate_ok']}{Q['delete']}
<h2>7.3 Selection and Joins</h2>
{Q['select']}{Q['join']}
<h2>7.4 Grouping, Aggregation and Subqueries</h2>
{Q['group']}{Q['having']}{Q['rollup']}{Q['corr']}
<h2>7.5 Functions</h2>
{Q['func']}
<h2>7.6 Views</h2>
<p>The database defines {WORDS[N_VIEWS]} views: {', '.join(f'<code>{v}</code>' for v in VIEWS)}. All computations are encapsulated in these views, so that the web application and MySQL Workbench obtain identical and current results.</p>
{Q['view1']}{Q['view2']}{Q['view3']}{Q['v_ratings']}{Q['view4']}

{sec(8, "Advanced Database Operations")}
<h2>8.1 Transactions</h2>
<p>A transaction groups a set of statements into a single atomic unit of work. In the example below, the costs of BluDove are increased within a transaction, which is then rolled back; the database is consequently restored to its previous state. Every stored procedure that modifies data (<code>sp_pause_mess</code>, <code>sp_resume_mess</code> and <code>sp_close_meal</code>) begins with <code>START TRANSACTION</code> and declares an <code>EXIT HANDLER</code> that executes <code>ROLLBACK</code> in the event of an error.</p>
{Q['tx']}
<p>A savepoint marks a point within a transaction to which the transaction may be partially rolled back:</p>
{Q['savepoint']}
<h2>8.2 Triggers</h2>
<p>A trigger is executed automatically when a row of its table is modified. Triggers serve two purposes in this project. BEFORE triggers enforce business rules and reject invalid data by raising <code>SIGNAL SQLSTATE '45000'</code>. AFTER triggers maintain an audit trail by recording every enrolment, login, booking, modification, leave, meal served, rating and donation in the table <code>activity_log</code>.</p>
<pre class="code">{block('CREATE TRIGGER trg_booking_paused_ins', 'END$$')}</pre>
{Q['trg_list']}{Q['trg_gender']}{Q['chk']}{Q['rate_no']}
<h2>8.3 Stored Procedures and Function</h2>
<pre class="code">{block('CREATE PROCEDURE sp_pause_mess', 'END$$')}</pre>
{Q['routines']}{Q['proc_before']}{Q['proc_pause']}{Q['proc_block']}{Q['proc_resume']}
<p>The procedure <code>sp_close_meal</code> employs a cursor to iterate over the surplus of each mess for a meal and assigns it, within a single transaction, to the NGO that has received the least quantity so far:</p>
{Q['proc_close']}
<h2>8.4 User Privileges</h2>
<p>The application does not connect to the database as the root user. The installation script creates the user <code>mess_app</code> with only those privileges that the application requires; consequently, the application is unable to delete records or to alter or drop any object. In addition, a read-only user is created for the management of the messes, with access restricted to selected views; the REVOKE statement withdraws a privilege previously granted.</p>
{Q['grants']}{Q['viewer']}
<h2>8.5 Scheduled Events</h2>
<p>An event is a task executed by the MySQL event scheduler at defined intervals. The event <code>ev_close_meals</code> runs every ten minutes and invokes <code>sp_close_finished_meals</code>, which uses a cursor to select every meal of the current day whose serving period has ended and that has not yet been closed, and calls <code>sp_close_meal</code> for each. The surplus food is thereby allocated to NGOs without any manual intervention.</p>
<pre class="code">{block('CREATE EVENT ev_close_meals', 'sp_close_finished_meals()$$')}</pre>
{Q['events']}

{sec(9, "Screenshots")}
<p>The following screenshots depict the system in operation. The student interface and the management dashboard operate on the MySQL database described in the preceding sections.</p>
{shot('web_home.png', 'Home page of the student interface')}
{shot('web_meal.png', 'Menu of both messes for a meal (hi-tea)')}
<div class="pair">{shot('web_otp.png', 'Login by one-time password', 'auto')}{shot('web_booked.png', 'Meal booking screen with the student profile', 'auto')}</div>
{shot('web_rate_pair.png', 'Rating of meals eaten (a rated breakfast, an unrated lunch) and the donation of leftovers recorded by the scheduled event', '88%')}
{shot('web_ratings.png', 'Ratings board of the management dashboard, obtained from v_mess_ratings')}
{shot('web_dashboard_full.png', 'Management dashboard: profit of each mess (v_mess_earnings), forecast for the following day (v_daily_forecast) and the activity log')}
{Q['live']}

{sec(10, "Conclusion")}
<p>The project has replaced a fixed two-month mess registration with a per-meal choice and has substituted estimation in the kitchens with an exact forecast derived from bookings. The implementation demonstrates that a well-designed relational database can support the entire application: the web interface and the application programming interface constitute thin layers, while the rules, the computations and the history of all operations are maintained within MySQL.</p>
<p>Several lessons were learnt in the course of the implementation. Normalisation to the Third Normal Form eliminated the possibility of inconsistent data, and the use of views for derived quantities ensured correct results without additional program code. Constraints and triggers proved to be the most reliable means of enforcing business rules, since no client application can bypass them. Stored procedures executed within transactions ensured that multi-step operations remain consistent even in the event of failure. The principle of least privilege and the use of parameterised queries made the system secure by design. The project further afforded practical experience with features such as <code>ON DUPLICATE KEY UPDATE</code>, correlated subqueries, <code>WITH ROLLUP</code> and cursors.</p>
<p>The system may be extended in future by introducing a date-dependent weekly menu, a direct interface for the face-recognition terminals, and menu planning informed by the ratings collected from students.</p>

{sec(11, "References")}
<ol>
<li>Oracle Corporation, <i>MySQL 8.0 Reference Manual</i>. Available: https://dev.mysql.com/doc/refman/8.0/en/</li>
<li>Oracle Corporation, <i>MySQL Workbench Manual</i>. Available: https://dev.mysql.com/doc/workbench/en/</li>
<li>A. Silberschatz, H. F. Korth and S. Sudarshan, <i>Database System Concepts</i>, 7th ed. New York: McGraw-Hill, 2019.</li>
<li>R. Elmasri and S. B. Navathe, <i>Fundamentals of Database Systems</i>, 7th ed. Boston: Pearson, 2016.</li>
<li>C. J. Date, <i>An Introduction to Database Systems</i>, 8th ed. Boston: Addison-Wesley, 2003.</li>
<li>FastAPI Documentation. Available: https://fastapi.tiangolo.com/</li>
<li>PyMySQL Documentation. Available: https://pymysql.readthedocs.io/</li>
</ol>
"""

CSS = """
@page { size: A4; margin: 1in; }
body { font-family: "Times New Roman", Times, serif; font-size: 12pt; line-height: 1.5; text-align: justify; color: #000; margin: 0; }
h1 { font-size: 16pt; font-weight: bold; margin: 0 0 10pt; page-break-before: always; text-align: left; }
h2 { font-size: 14pt; font-weight: bold; margin: 14pt 0 6pt; text-align: left; page-break-after: avoid; }
p { margin: 0 0 8pt; }
ul, ol { margin: 0 0 8pt; padding-left: 22pt; } li { margin-bottom: 3pt; }
code { font-family: "Courier New", monospace; font-size: 10.5pt; }
.cover { text-align: center; line-height: 1.3; page-break-after: always; padding-top: 30pt; }
.cover p { margin: 0 0 10pt; text-align: center; }
.cover .a { font-size: 14pt; } .cover .pr { font-size: 16pt; font-weight: bold; } .cover .on { font-size: 12pt; }
.cover .title { font-size: 22pt; font-weight: bold; margin: 8pt 40pt 18pt; line-height: 1.25; } .cover .subtitle { font-size: 13pt; font-style: italic; margin-bottom: 18pt; }
.cover .sub { font-size: 12pt; } .cover .deg { font-size: 14pt; font-weight: bold; } .cover .br { font-size: 14pt; font-weight: bold; }
.cover .sb { font-size: 14pt; font-weight: bold; margin-top: 14pt; } .cover .nm { font-size: 13pt; margin-bottom: 4pt; }
.cover .subj { font-size: 13pt; font-weight: bold; margin-top: 12pt; }
.cover .logo { width: 62%; margin: 26pt auto 14pt; display: block; }
.cover .sch, .cover .dep { font-weight: bold; font-size: 12.5pt; margin-bottom: 4pt; } .cover .plain { font-size: 12pt; margin-bottom: 4pt; }
.toc { page-break-after: always; }
.toc h1 { page-break-before: avoid; text-align: center; }
.toct { width: 100%; border-collapse: collapse; font-size: 12pt; }
.toct td { padding: 1.5pt 0; line-height: 1.25; } .toct { font-size: 11.5pt; } .toct td.pg { text-align: right; width: 50pt; } .toct tr.l2 td.t { padding-left: 22pt; font-size: 11.5pt; }
.toct td.t span { background: #fff; padding-right: 4pt; }
.toct td.t { border-bottom: 1px dotted #888; }
table.plain { width: 100%; border-collapse: collapse; margin: 6pt 0 12pt; font-size: 11pt; line-height: 1.35; text-align: left; page-break-inside: auto; }
table.plain th, table.plain td { border: 1px solid #555; padding: 4pt 6pt; vertical-align: top; }
table.plain th { background: #e8e8e8; } table.plain.small { font-size: 10pt; width: 70%; }
p.rel { font-size: 11pt; line-height: 1.4; margin-bottom: 4pt; text-align: left; }
pre.code { font-family: "Courier New", monospace; font-size: 9pt; line-height: 1.3; background: #f5f5f5; border: 1px solid #ccc; padding: 8pt; white-space: pre-wrap; text-align: left; page-break-inside: avoid; margin: 6pt 0 12pt; }
figure { margin: 10pt 0 16pt; page-break-inside: avoid; }
figcaption { text-align: center; font-size: 11pt; font-style: italic; margin-top: 5pt; }
figure.shot img { display: block; margin: 0 auto; border: 1px solid #999; max-width: 100%; max-height: 7.6in; width: auto; object-fit: contain; }
.pair figure.shot img { max-height: 6.2in; }
.pair { display: flex; gap: 12pt; align-items: flex-start; page-break-inside: avoid; } .pair figure { flex: 1; margin: 0; }
/* query figures: the SQL editor and the result grid, Workbench-style */
figure.q { border: 1px solid #9a9a9a; }
figure.q pre.sql { margin: 0; font: 9.5pt/1.35 "Courier New", monospace; background: #fff; color: #1a1a8c; padding: 8pt 10pt; white-space: pre-wrap; border-bottom: 1px solid #b5b5b5; text-align: left; }
figure.q .out { background: #f3f3f3; padding: 6pt 8pt; }
figure.q figcaption { background: #fff; margin: 0; padding: 4pt; border-top: 1px solid #b5b5b5; }
.grid { overflow: hidden; }
.grid table { border-collapse: collapse; font: 8.5pt/1.3 Arial, Helvetica, sans-serif; background: #fff; width: auto; max-width: 100%; text-align: left; }
.grid th { background: #e4e4e4; font-weight: bold; border: 1px solid #c4c4c4; padding: 2pt 6pt; white-space: nowrap; }
.grid td { border: 1px solid #dcdcdc; padding: 2pt 6pt; white-space: nowrap; max-width: 260pt; overflow: hidden; text-overflow: ellipsis; }
.grid tr:nth-child(even) td { background: #f7f9fc; }
.grid td.rn, .grid th.rn { background: #ececec; color: #777; width: 10pt; padding: 2pt 3pt; }
.grid .null { color: #888; font-style: italic; }
.more { font: 8pt Arial, sans-serif; color: #555; margin-top: 3pt; }
.msg { font: 9pt/1.4 Arial, Helvetica, sans-serif; padding: 3pt 6pt; margin: 2pt 0; border-radius: 2pt; text-align: left; }
.msg.ok { color: #1d5e20; background: #e3f3e3; } .msg.err { color: #9b1c1c; background: #fbe4e4; }
.out .grid + .grid, .out .msg + .grid, .out .grid + .msg { margin-top: 6pt; }
figure.er { page-break-before: always; page-break-after: always; } figure.er img { max-width: 100%; max-height: 8.6in; width: auto; border: 0; }
"""

doc = f"""<!doctype html><html><head><meta charset="utf-8"><style>{CSS}</style>
</head><body>{body}<script>document.body.dataset.ready = "1";</script></body></html>"""

ER_FIG = FIG_AFTER_QUERIES  # placeholder replaced below
# Figure numbers: the ER figure appears before the query figures in reading order, so renumber in document order.
order = re.findall(r"Figure (\d+|\{ERFIG\}):", doc)
mapping, n = {}, 0
def renum(m):
    global n
    n += 1
    return f"Figure {n}:"
doc = re.sub(r"Figure (?:\d+|\{ERFIG\}):", renum, doc)

HEADS = [(f"s{i}", t) for i, t in [(1, "Introduction"), (2, "Objectives"), (3, "Features and Functionality"), (4, "Tools and Technologies Used"),
                                    (5, "ER Diagram and Relational Model"), (6, "Database Implementation"), (7, "SQL Queries and Outputs"),
                                    (8, "Advanced Database Operations"), (9, "Screenshots"), (10, "Conclusion"), (11, "References")]]
SUBS = re.findall(r"<h2>(\d+\.\d+ [^<]+)</h2>", doc)


def render(html_doc: str, path: Path) -> None:
    with sync_playwright() as p:
        b = p.chromium.launch()
        pg = b.new_page()
        pg.set_content(html_doc, wait_until="networkidle")
        pg.wait_for_function("document.body.dataset.ready === '1'", timeout=30000)
        pg.pdf(path=str(path), format="A4", margin={"top": "1in", "bottom": "1in", "left": "1in", "right": "1in"},
               display_header_footer=True, header_template="<span></span>",
               footer_template='<div style="width:100%;text-align:center;font:10pt \'Times New Roman\',serif;"><span class="pageNumber"></span></div>',
               print_background=True)
        b.close()


def toc_rows(pages: dict) -> str:
    rows = [f'<tr><td class="t"><span>Table of Contents</span></td><td class="pg">2</td></tr>']
    for i, (_, t) in enumerate(HEADS, 1):
        rows.append(f'<tr><td class="t"><span><b>{i}. {t}</b></span></td><td class="pg">{pages.get(f"{i}. {t}", "")}</td></tr>')
        for s in SUBS:
            if s.startswith(f"{i}."):
                rows.append(f'<tr class="l2"><td class="t"><span>{s}</span></td><td class="pg">{pages.get(s, "")}</td></tr>')
    return "".join(rows)


def find_pages(pdf: Path) -> dict:
    d = fitz.open(pdf)
    found = {}
    keys = [f"{i}. {t}" for i, (_, t) in enumerate(HEADS, 1)] + SUBS
    for pno in range(1, len(d)):  # skip the cover
        text = d[pno].get_text()
        if "Table of Contents" in text:
            continue
        for k in keys:
            if k not in found and k in text:
                found[k] = pno + 1
    return found


tmp = HERE / "draft.pdf"
render(doc.replace("{TOC}", toc_rows({})), tmp)
pages = find_pages(tmp)
render(doc.replace("{TOC}", toc_rows(pages)), OUT)
assert find_pages(OUT) == pages, "page numbers moved between passes"
sqlfile = REPO / "db" / "report_queries.sql"
sqlfile.write_text("-- Every SQL statement shown in the project report, in the same order, with its figure caption.\n"
                   "-- MySQL Workbench: put the cursor in a statement and press Ctrl+Enter (Cmd+Enter on Mac).\n"
                   "USE mess;\nSET time_zone = '+05:30';\n\n"
                   + "\n\n".join(f"-- {t}\n{q.rstrip(';')};" for t, q in SQL_LOG) + "\n", encoding="utf-8")
print("wrote", OUT, len(fitz.open(OUT)), "pages;", n, "figures")
