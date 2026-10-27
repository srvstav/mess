"""Two-page viva cheat sheet: the minimum to learn first."""
from pathlib import Path
from playwright.sync_api import sync_playwright
import base64, pymysql
ER = "data:image/png;base64," + base64.b64encode((Path(__file__).parent / "er.png").read_bytes()).decode()
db = pymysql.connect(host="127.0.0.1", user="root", password="", database="mess"); c = db.cursor()
c.execute("SELECT table_name FROM information_schema.tables WHERE table_schema='mess' AND table_type='BASE TABLE' ORDER BY table_name")
TABLES = [r[0] for r in c.fetchall()]
c.execute("SELECT table_name, column_name FROM information_schema.columns WHERE table_schema='mess' ORDER BY table_name, ordinal_position")
COLS = {}
for t, col in c.fetchall(): COLS.setdefault(t, []).append(col)
c.execute("SELECT table_name, column_name FROM information_schema.key_column_usage WHERE table_schema='mess' AND constraint_name='PRIMARY'")
PK = set(c.fetchall())
c.execute("SELECT table_name, column_name, referenced_table_name FROM information_schema.key_column_usage WHERE table_schema='mess' AND referenced_table_name IS NOT NULL ORDER BY table_name")
FKS = c.fetchall(); FK = {(t, col) for t, col, _ in FKS}
def fmt(t, col):
    x = col
    if (t, col) in PK: x = f"<u>{x}</u>"
    if (t, col) in FK: x = f"<i>{x}</i>*"
    return x
SCHEMA = "".join(f"<p class='rel'><b>{t}</b>({', '.join(fmt(t, col) for col in COLS[t])})</p>" for t in TABLES)
REFS = " · ".join(f"{t}.{col} → {rt}" for t, col, rt in FKS)
OUT = Path.home() / "Downloads" / "Viva_Sheet_All_You_Need.pdf"
QA = [
 ("What is your project?", "Students pick BluDove, BluSpring or skip for every meal; MySQL counts bookings so each mess cooks bookings + 30%, rates meals, and donates leftovers automatically."),
 ("Why a database, not files?", "Integrity (rules), many users at once, crash safety, security, and SQL queries."),
 ("Primary vs foreign key?", "Primary key identifies a row (students.id). Foreign key points to another table's primary key (bookings.student_id → students.id)."),
 ("Candidate / composite key?", "Candidate: any minimal unique key (id, reg_no, phone, email). Composite: made of 2+ columns: (mess_id, slot_id) in mess_costs."),
 ("Which normal form?", "3NF. 1NF: one value per cell (dishes are rows). 2NF: no partial dependency (mess_costs). 3NF: no non-key → non-key (hostel gender lives in hostels)."),
 ("Why are totals in views, not columns?", "They are derived; storing them would go out of date (update anomaly). Views recalculate every time."),
 ("WHERE vs HAVING?", "WHERE filters rows before GROUP BY; HAVING filters groups after (can use COUNT, SUM)."),
 ("INNER vs LEFT JOIN?", "INNER: only matches. LEFT: all left rows; skipped meals still appear with NULL mess."),
 ("What is a view?", "A saved SELECT used like a table. v_daily_forecast = booked × 1.3, per mess and meal."),
 ("What is a transaction / ACID?", "All-or-nothing group of statements. Atomic, Consistent, Isolated, Durable. sp_pause_mess: pause + release meals together or not at all."),
 ("Trigger vs procedure?", "Trigger runs by itself on INSERT/UPDATE/DELETE. Procedure runs when you CALL it, takes parameters, can hold a transaction."),
 ("BEFORE vs AFTER trigger?", "BEFORE can refuse the row (SIGNAL '45000' → error 1644). AFTER runs only if it succeeded, so it logs to activity_log."),
 ("Why a trigger instead of CHECK for hostel gender?", "CHECK can only see its own row; the gender of a hostel is in another table."),
 ("What is the event?", "ev_close_meals runs every 10 minutes and calls sp_close_finished_meals, which closes ended meals and donates leftovers."),
 ("How is it secure?", "Parameterised queries (%s) stop SQL injection; app user mess_app has only SELECT, INSERT, UPDATE, EXECUTE (no DELETE/DROP)."),
]
rows = "".join(f"<tr><td class='n'>{i}</td><td class='q'>{q}</td><td>{a}</td></tr>" for i, (q, a) in enumerate(QA, 1))
HTML = f"""<!doctype html><html><head><meta charset="utf-8"><style>
@page {{ size: A4; margin: 0.6in; }}
body {{ font: 10.5pt/1.35 "Times New Roman", serif; margin: 0; }}
h1 {{ font-size: 15pt; margin: 0 0 4pt; text-align: center; }} h2 {{ font-size: 12pt; margin: 10pt 0 4pt; border-bottom: 1.5px solid #000; }}
.sub {{ text-align: center; margin: 0 0 6pt; font-style: italic; }}
table {{ width: 100%; border-collapse: collapse; }} td, th {{ border: 1px solid #666; padding: 3pt 5pt; vertical-align: top; }}
td.n {{ width: 14pt; text-align: center; font-weight: bold; }} td.q {{ width: 32%; font-weight: bold; }}
.grid {{ display: grid; grid-template-columns: 1fr 1fr; gap: 6pt 14pt; }}
.box {{ border: 1.5px solid #000; padding: 6pt 8pt; }} ol {{ margin: 0; padding-left: 16pt; }} li {{ margin-bottom: 2pt; }}
code {{ font: 9.5pt "Courier New", monospace; }}
p.rel {{ margin: 0 0 1pt; font-size: 9.5pt; line-height: 1.25; }} p.refs {{ font-size: 9pt; margin-top: 4pt; line-height: 1.25; }}
</style></head><body>
<h1>VIVA SHEET · Hostel Mess Management System (MySQL)</h1>
<p class="sub">This is everything you need to learn for the viva and the demonstration.</p>
<h2>1. Say this when asked "explain your project" (30 seconds)</h2>
<p class="box">"Students choose a mess, BluDove or BluSpring, or skip, for each of four daily meals, up to a week ahead. Every choice is a row in MySQL.
A view tells each kitchen to cook bookings plus 30%. Face terminals record who ate; students can rate only what they ate; a scheduled event
closes each meal and donates leftovers to NGOs. All rules are inside the database: keys, CHECK constraints, triggers, stored procedures and transactions."</p>
<h2>2. Numbers (memory hook: <b>15-15-8-7-1-1</b>)</h2>
<p><b>15</b> tables · <b>15</b> triggers · <b>8</b> views · <b>7</b> procedures · <b>1</b> function · <b>1</b> event · 20 foreign keys · 10 CHECKs · 1,200 students · 22 hostels · 4 meals · 30% buffer.</p>
<h2>3. The questions and their answers</h2>
<table>{rows}</table>
<h2>4. Error codes (if one appears, it is our rule working)</h2>
<p><b>1644</b> = our trigger said no (SIGNAL) · <b>3819</b> = CHECK constraint failed · <b>1451</b> = foreign key protects a row · <b>1062</b> = duplicate UNIQUE key.</p>
<h2>5. Demo in 6 steps</h2>
<div class="grid"><div class="box"><ol>
<li>Start: <code>start_all.bat</code> (Windows) / <code>./spin.sh</code> (Mac). In Workbench: <code>CALL sp_demo_week();</code></li>
<li>Workbench → Schemas → mess: show tables, views, procedures. Database → Reverse Engineer = ER diagram.</li>
<li>Website: log in with any number, book dinner. Workbench: <code>SELECT * FROM activity_log ORDER BY id DESC LIMIT 10;</code> → BOOK row came from a trigger.</li></ol></div>
<div class="box"><ol start="4">
<li>Run the "a2" inserts: boy in girls' hostel → 1644; phone 12345 → 3819.</li>
<li><code>SELECT * FROM v_daily_forecast WHERE meal_date = CURDATE();</code> → cook = booked × 1.3.</li>
<li><code>SHOW EVENTS;</code> then <code>CALL sp_close_finished_meals();</code> → donations appear.</li></ol></div></div>
<h2>6. Three one-line definitions to be exact about</h2>
<p><b>Normalisation</b> = splitting tables so each fact is stored once, to avoid insert, update and delete anomalies. ·
<b>Index</b> = a B+ tree that finds rows without scanning the table (we made idx_forecast). ·
<b>Cursor</b> = reads a result one row at a time inside a procedure (sp_close_meal loops over each mess's leftover).</p>
<div style="page-break-before: always"></div>
<h2>7. ER diagram (all 14 entities; every line is a FOREIGN KEY; crow's foot = "many", double bar = "one")</h2>
<img src="{ER}" style="width:78%; display:block; margin:0 auto; border:1px solid #999">
<p><b>How to read the lines:</b> each line joins a foreign-key column to the primary key it references. Crow's foot = many; double bar = exactly one; bar with circle = zero or one (the foreign key may be NULL, e.g. a skipped booking has no mess).</p><p><b>Relationships to say aloud:</b> one programme → many students · one hostel → many students · one student → many bookings, pauses, attendance rows,
ratings and logins · one mess / one meal slot → many menu items, bookings, attendance rows, ratings and donations · one NGO → many donations ·
<b>mess_costs</b> resolves the many-to-many between messes and meal slots (composite key mess_id + slot_id). activity_log (the 15th table) is not drawn: it is an audit table with no foreign keys.</p>
<h2>8. Relational schema (<u>primary key</u> underlined, <i>foreign key</i>* in italics)</h2>
{SCHEMA}
<p class="refs"><b>Foreign keys (20):</b> {REFS}</p>
</body></html>"""
with sync_playwright() as p:
    b = p.chromium.launch(); pg = b.new_page(); pg.set_content(HTML)
    pg.pdf(path=str(OUT), format="A4", margin={"top": "0.6in", "bottom": "0.6in", "left": "0.6in", "right": "0.6in"}, print_background=True)
    b.close()
import fitz
print("wrote", OUT, len(fitz.open(OUT)), "pages")
