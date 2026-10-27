# MUJ Mess

One annual fee and two messes (**BluDove** and **BluSpring**). Students book where they'll eat for every meal: breakfast, lunch, hi-tea and dinner. Each kitchen cooks for the people who booked, plus 30%. Each mess's face-recognition terminal records who ate, students rate their meals, and a MySQL event closes every finished meal so leftovers go to NGOs.

An RDBMS project: **MySQL 8** (14 tables, 12 triggers, 4 stored procedures, 1 function, 7 views, and a 1,200-student roster) + **Python FastAPI** + a plain HTML/CSS/JS website.

**Taking this project over? Start with [HANDOVER.md](HANDOVER.md). Presenting it in MySQL Workbench? [WORKBENCH.md](WORKBENCH.md).**

| Page | What it is |
| --- | --- |
| `index.html` | Student site: log in with a code (SMS once Firebase is set up; any number works, new ones join the roster), book meals, pause when going home |
| `dashboard.html` | Mess ledger: each mess's profit, margin, waste and no-shows over 7 days, tomorrow's shopping plan, and the live MySQL feed (every 2 seconds) |

```
 Website (GitHub Pages)  ──HTTPS──►  API (FastAPI on Render)  ──TLS──►  MySQL (Aiven)  ◄──  Workbench
      docs/                               backend/                          db/
 Offline mode: start.bat runs the API + website on one laptop against that laptop's MySQL.
```

## ▶ Start here (the whole handover)

**Everyone (on their own Windows laptop, ~10 min):**
1. Install **MySQL Server + Workbench** and **Python** (details in section A). Remember the MySQL root password.
2. Download this project (**Code → Download ZIP**) and unzip it.
3. Double-click **`setup.bat`**, press Enter 3 times, then type the MySQL root password.
4. Double-click **`start.bat`**. The site opens at http://localhost:8000. That's the full system, offline.
5. Double-click **`workbench.bat`**: MySQL Workbench opens connected to the database with the demo queries loaded.
   *(No Python on a laptop? In Workbench open and run `db\mess_complete.sql`. See [WORKBENCH.md](WORKBENCH.md).)*

**One person, once, to put it online (~10 min):**
6. Sign up at **aiven.io** → Create service → **MySQL** → **Free plan**. When it's running, copy the **Service URI** and click **CA certificate → Download**.
7. Double-click **`setup_cloud.bat`** and paste the Service URI when asked. It finds `ca.pem` in Downloads by itself, builds the cloud database, and **copies one long line to your clipboard**.
8. Sign up at **render.com** with GitHub → open https://dashboard.render.com/blueprint/new → pick this repo → paste (Ctrl+V) into **MESS_SETTINGS** → **Apply**. Wait for **Live**.
   **The Render address (`https://mess-api-….onrender.com`) is now your website**, usable from any phone.
9. Send the other two **`CLOUD_DETAILS.txt`** and **`ca.pem`**, so their Workbench connects to the same live database (section C4).

*Optional:* to make the github.io address use the cloud too, edit `docs/config.js` on github.com (pencil icon) and paste the Render address into `MESS_CLOUD_API`.

If step 6 says the cloud *"will refuse to create triggers"*, Aiven didn't allow triggers. Use the offline setup from steps 3–5 for the demo; everything, including the triggers, works there.

---

## A. Run it on a Windows laptop (offline, about 10 minutes)

**1. Install once**

- **MySQL Server 8.0 or newer + MySQL Workbench**: https://dev.mysql.com/downloads/installer/ → *MySQL Installer for Windows* → choose **Custom** → add *MySQL Server* and *MySQL Workbench*. Remember the **root password** you set during the install.
  - Already have Workbench? Check the server too: press `Win + R`, type `services.msc`, and look for **MySQL80** (or MySQL84 / MySQL). It should say *Running*.
- **Python 3.12 or 3.13**: https://www.python.org/downloads/. On the first installer screen, tick **"Add python.exe to PATH"**.

**2. Get the project.** On GitHub press **Code → Download ZIP**, then unzip it somewhere simple, like `C:\mess`. Or use `git clone`.

**3. Double-click `setup.bat`.** It installs the Python packages, then asks for the MySQL details:

```
Host [127.0.0.1]:            ← press Enter
Port [3306]:                 ← press Enter
Admin user [root]:           ← press Enter
Password for root:           ← type your MySQL root password (nothing shows while typing; that's normal)
```

It then builds the `mess` database, loads the roster and a demo week, and prints the next step.

**4. Double-click `start.bat`.** Keep that black window open. The browser opens http://localhost:8000.

| URL | |
| --- | --- |
| http://localhost:8000 | student site |
| http://localhost:8000/dashboard.html | live board |
| http://localhost:8000/docs | interactive API docs (Swagger) |

**5. (Optional) Double-click `demo.bat`.** It loads a realistic day for the roster: about 700 students' bookings, pauses, logins, attendance and donations, so every table and view has data to show.

During a presentation, run **`python demo_data.py live`** (or `python demo_data.py cloud live`). It keeps making bookings, mess switches and serves every second or two, so the dashboard and Workbench keep moving. Ctrl+C stops it.

`reset.bat` wipes the database and rebuilds it from scratch.

## B. Watch it live in MySQL Workbench

1. Open Workbench, then click **⊕** next to *MySQL Connections*.
2. Connection name: `MUJ Mess (local)` · Hostname `127.0.0.1` · Port `3306` · Username `root`. Click **OK**, then open it and enter the root password.
3. **File → Open SQL Script →** `db\demo_queries.sql`.
4. Do something on the website (log in, book, pause). Then click inside query 1 and press **Ctrl + Enter**. The new rows appear: ENROL, LOGIN, BOOK, PAUSE…

   Workbench doesn't refresh on its own. Press Ctrl + Enter again after each action, and keep `dashboard.html` open beside it for a view that refreshes by itself.
5. **ER diagram:** **Database → Reverse Engineer… →** pick the connection → select schema `mess` → Next until **Finish**. Workbench draws all 14 tables and their foreign keys.

## C. Put it online for everyone (one person, once)

This makes the website work from any phone, and all three laptops' Workbench show the **same** live database.

**1. Cloud MySQL (Aiven, free)**
1. Sign up at https://console.aiven.io (the GitHub login is fine).
2. **Create service → MySQL → Free plan →** create it, and wait until it shows *Running*.
3. On the service page, copy the **Service URI**, and click **CA certificate → Download** (it saves `ca.pem` to Downloads).
4. Double-click **`setup_cloud.bat`** and paste the Service URI when asked. It:
   - builds all tables, triggers, procedures and views in the cloud,
   - copies **one line** (the Render setting) to your clipboard, and also saves it in `RENDER_VALUE.txt`,
   - writes **`CLOUD_DETAILS.txt`** (the Workbench login) and puts `ca.pem` next to it.

   If it says the server *"will refuse to create triggers"*: in Aiven, open **Service settings → Advanced configuration**, turn on `log_bin_trust_function_creators` if it's listed, and run it again. If it isn't listed, use the offline setup (section A) for the demo.

**2. Cloud API + website (Render, free)**
1. Sign up at https://render.com with GitHub, and give it access to this repository.
2. Open https://dashboard.render.com/blueprint/new → pick this repository.
3. In the **MESS_SETTINGS** box, paste (Ctrl+V) → **Apply**. The first build takes 3–5 minutes.
4. When it shows **Live**, open its address (like `https://mess-api-xxxx.onrender.com`). That address is the full website: student site and `/dashboard.html`.
5. *Optional:* so the github.io address also works, open `docs/config.js` on github.com (pencil icon), set `window.MESS_CLOUD_API = "https://mess-api-xxxx.onrender.com";` and commit. This also turns on the `keep-awake` ping, which stops the free server from sleeping during the day.

**3. Workbench → cloud database (every laptop)**
Use `CLOUD_DETAILS.txt`: new connection with that Hostname, Port, Username and Password.
On the **SSL** tab, set *Use SSL* to **Require**, and *SSL CA File* to `ca.pem`. Then **Test Connection**.

**4. Sample data in the cloud:** double-click **`demo_cloud.bat`**.

## D. Morning of the demo

- [ ] Open `<Render address>/health`. It should say ok (this also wakes the server, which can take up to a minute).
- [ ] Double-click `demo_cloud.bat` (or `demo.bat` for the offline setup) so today has data.
- [ ] Phone: the student site · Projector: `dashboard.html` · Laptop: Workbench with `demo_queries.sql`.
- [ ] Backup: if the Wi-Fi fails, use `start.bat` on one laptop (section A). Everything works offline except new logins, which need internet for the SMS. Log in on the demo phone beforehand: a logged-in session stays valid for 7 days.
- [ ] Read `viva/project.html` sections 10 and 11: who says what, and the likely viva questions. (It's kept out of the public site.)

## Troubleshooting

| Problem | Fix |
| --- | --- |
| `Python is not installed` | Install Python, tick **Add to PATH**, then run `setup.bat` again |
| `Access denied for user 'root'` | Wrong MySQL root password. Use the one from the MySQL install |
| `Can't connect to MySQL` | `services.msc` → start **MySQL80** |
| `start.bat` says *address already in use* | It's already running in another window. Close that window first |
| Website says *Can't reach the mess server* | Local: is the `start.bat` window open? Cloud: open `<API>/health` and wait up to a minute |
| Workbench shows old rows | Press **Ctrl + Enter** to run the query again |
| Want to start clean | `reset.bat` (local) or `setup_cloud.bat` (cloud) |

## How it's organised

```
db/schema.sql         tables, constraints, triggers, procedures, views
db/seed.sql           2 messes, 4 meals, menus, 12 programmes, 22 hostels (B1–B12, G1–G10), 3 NGOs
db/students.csv       the student roster (1,200 fictional students; add real ones here)
db/demo_queries.sql   open in Workbench during the demo
backend/main.py       API endpoints (controller)
backend/repo.py       every SQL statement, all parameterized (repository)
backend/auth.py       login (Firebase SMS or demo code -> session token)
backend/firebase.py   checks Firebase's signed login token with Google's public keys
backend/tests/        automated tests: run  backend\.venv\Scripts\python -m pytest -q backend\tests
docs/                 the website (student site, dashboard, photo credits); docs/food/ = plate photos
viva/project.html     how it's built: ER diagram, normalization, demo plan, viva answers (not published)
setup.py              builds the database (local or cloud), used by setup.bat
demo_data.py          loads a realistic day, used by demo.bat
```

**Design decisions**
- **Raw SQL, no ORM**, so every query, trigger and view can be seen and explained. All queries are parameterized.
- **Real SMS login through Firebase.** Firebase sends and checks the code (no DLT paperwork needed). The API verifies Firebase's signed token, then only lets in phones that are on the `students` roster.
- **The app's database user is `mess_app`**, with SELECT, INSERT, UPDATE and EXECUTE only. It has no DELETE, DROP or ALTER.
- **India time everywhere.** Cloud servers run on UTC, so the API and every database session use `+05:30`.
- **Donation rule:** leftover = unused 30% buffer + 50% of the no-shows' portions, capped at what's actually left. It's assigned to the NGO that has received the least so far.
