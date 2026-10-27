# Handover: making this project yours

This project is built so that one person can hand it to another. Nothing in the code belongs to
the person who wrote it: every account (GitHub, Firebase, Aiven, Render) is created by **you**, under your
own name, and every secret is made fresh on your machine by `setup.py`. No password or key is in the repository.

Work through these steps in order. Steps 1–4 take about 30 minutes.

---

## 1. Take over the repository

The current owner does this on github.com:

1. Open the repository → **Settings** → scroll to **Danger Zone** → **Transfer ownership**.
2. Type your GitHub username and confirm. You get an email; accept it.

Then you:

3. Open your copy → **Settings → Pages** → *Source*: **Deploy from a branch** → Branch **main**, folder **/docs** → **Save**.
   The site appears at `https://<your-username>.github.io/mess/` within a few minutes.
4. Download it to your laptop: **Code → Download ZIP** (or `git clone`).

> A transfer keeps the full history. Past commits still show who made them; new commits will show you.

## 2. Run it on your laptop

Follow **README section A** (install MySQL + Python, double-click `setup.bat`, then `start.bat`).
`setup.bat` creates a new database password and session secret just for you.

## 3. Turn on real SMS login (Firebase)

Firebase sends the 6-digit code by SMS and checks it. No Indian DLT registration is needed.
Any number can log in: a number that isn't on the roster joins it on first login as "Guest 1234" (hostel B1), so a demo never stops at the door.

1. Go to https://console.firebase.google.com → **Create a project** (any name, e.g. `muj-mess`). Google Analytics is not needed.
2. **Build → Authentication → Get started → Sign-in method → Phone → Enable → Save.**
3. **Upgrade to the Blaze plan** (bottom-left: *Spark* → **Upgrade**, add a card). Real SMS to real numbers is
   **not available on the free Spark plan**: Firebase's pricing page lists phone auth as "Not applicable" there, and
   "Billed per SMS sent" on Blaze. Check the current price per SMS to India on Google's Identity Platform pricing page.
   Then set a **budget alert** (Google Cloud console → Billing → Budgets & alerts), e.g. ₹500, so nothing runs away.
4. **Authentication → Settings → SMS region policy → Allow** only **India**. This blocks SMS fraud to other countries.
5. **Authentication → Settings → Authorized domains → Add domain**, and add:
   - `<your-username>.github.io`
   - your Render address from step 5 (e.g. `mess-api-xxxx.onrender.com`), once you have it
   - `localhost` is already there. On your laptop, open the site as **http://localhost:8000** (not 127.0.0.1) to log in.
6. **Project settings (gear icon) → General → Your apps → Web (`</>`)** → register an app (any nickname, no hosting).
   Firebase shows a `firebaseConfig` block. Copy four values into **`docs/config.js`**:

   ```js
   window.MESS_FIREBASE = {
     apiKey: "AIza...",
     authDomain: "muj-mess.firebaseapp.com",
     projectId: "muj-mess",
     appId: "1:1234567890:web:abc123",
   };
   ```

   These values are public by design; Firebase only accepts them from the authorized domains.
   The API reads `projectId` from this same file, so this is the only place you set it.
7. Commit the change (on github.com: open `docs/config.js` → pencil icon → paste → **Commit changes**).

**Test numbers (free, no SMS).** Authentication → Sign-in method → Phone → *Phone numbers for testing*:
add `+91 70000 00001` with code `123456`. That phone is roster row 1 in `db/students.csv`
(Anvi Das, a fictional student). Test numbers work even on the free plan, so the viva never
depends on an SMS arriving. Up to 10 test numbers are allowed.

**Handing over a Firebase project that already exists.** Instead of creating a new one: Project settings →
**Users and permissions → Add member** → the new owner's Google email, role **Owner**. They then move billing to
their own account (Project settings → Usage and billing) and the old owner removes themselves.

## 4. Put yourself (and your team) on the roster

Any number can log in (new ones become "Guest" students). To log in under your real name and hostel, either:

- **Before setup:** add a line to `db/students.csv` (same columns as the others), then run `reset.bat`; or
- **Live, in Workbench** (a good thing to show in the viva): run query **a** at the bottom of `db/demo_queries.sql`
  with your own name and number. The ENROL row appears in the live feed straight away.

Programme codes are in `db/seed.sql` (`BTECH-CSE`, `BBA`, …). Hostels are `B1`–`B12` (boys) and `G1`–`G10` (girls); a trigger checks the gender matches.
The 1,200 students already in the CSV are fictional; their phones `70000 00001`–`70000 01200` are placeholders.
Don't try to log in with them unless you've added them as Firebase test numbers.

## 5. Put it online (Aiven + Render, free)

Follow **README section C** with your own Aiven and Render accounts. At the end:

- paste your Render address into `window.MESS_CLOUD_API` in `docs/config.js` and commit, and
- add the Render address to Firebase's authorized domains (step 3.3).

Share `CLOUD_DETAILS.txt` and `ca.pem` only with your team. They are not in git, and must never be.

## 6. Check everything works

- [ ] `https://<your-username>.github.io/mess/` loads, and the green dot in the top-right lights up.
- [ ] Log in with your own number: the SMS arrives, and the site greets you by your roster name.
- [ ] Book a meal: it shows up in `dashboard.html` and in Workbench query 1.
- [ ] After a meal you ate, the booking page lets you rate it, and the dashboard's ratings board updates.
- [ ] Run `python demo_data.py cloud live` and watch the dashboard move.

## What lives where

| Thing | Where | Who owns it after handover |
| --- | --- | --- |
| Code and website | GitHub repository (`docs/` is the site) | you |
| SMS login | Firebase project, config in `docs/config.js` | you |
| Cloud database | Aiven MySQL | you |
| API server | Render web service (`render.yaml`) | you |
| Passwords, PIN, session secret | `backend/.env`, `CLOUD_DETAILS.txt`, Render's `MESS_SETTINGS` (made by setup; never committed) | you |
| How it's built / viva answers | `viva/project.html` (not published on the site) | you |
| Food photos | `docs/food/`, credits in `docs/credits.html` (keep the credits page: the licences require it) | their photographers |
