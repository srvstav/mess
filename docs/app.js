// Student flow: login, book meals, pause/resume, live counters. motion.js only animates.
const $ = id => document.getElementById(id);

// Shown when the server is unreachable, so the page still reads well. Mirrors db/seed.sql.
const FALLBACK_MENU = { slots: [
  { slot_id: 1, name: "Breakfast", starts_at: "07:30", ends_at: "09:30", messes: [
    { mess_id: 1, name: "BluDove", dishes: ["Aloo Paratha", "Curd", "Masala Chai", "Banana"] },
    { mess_id: 2, name: "BluSpring", dishes: ["Berry Pancakes", "Boiled Eggs", "Bread Butter Jam", "Cold Coffee"] } ] },
  { slot_id: 2, name: "Lunch", starts_at: "12:30", ends_at: "14:30", messes: [
    { mess_id: 1, name: "BluDove", dishes: ["Rajma", "Jeera Rice", "Tawa Roti", "Boondi Raita", "Salad"] },
    { mess_id: 2, name: "BluSpring", dishes: ["Chole", "Bhature", "Veg Pulao", "Lassi"] } ] },
  { slot_id: 3, name: "Hi-Tea", starts_at: "17:00", ends_at: "18:00", messes: [
    { mess_id: 1, name: "BluDove", dishes: ["Samosa", "Green Chutney", "Masala Chai"] },
    { mess_id: 2, name: "BluSpring", dishes: ["Fresh Fruit Tart", "Veg Sandwich", "Lemon Tea"] } ] },
  { slot_id: 4, name: "Dinner", starts_at: "19:30", ends_at: "21:30", messes: [
    { mess_id: 1, name: "BluDove", dishes: ["Farmhouse Pizza", "Veg Burger", "Garlic Bread", "Gulab Jamun"] },
    { mess_id: 2, name: "BluSpring", dishes: ["Dal Baati Churma", "Gatte ki Sabzi", "Chapati", "Kheer"] } ] },
] };

const api = (path, opts = {}) => {
  const token = store.get("mess_token");
  return apiFetch(path, {
    ...opts,
    headers: token ? { Authorization: `Bearer ${token}` } : {},
    onUnauthorized: token ? logout : undefined,
  });
};

let menuPromise = null;
const getMenu = () => (menuPromise ??= api("/menu").catch(() => { menuPromise = null; return FALLBACK_MENU; }));
window.Mess = { getMenu, FALLBACK_MENU };

/* ---------- login: Firebase sends the SMS and checks the code, our API checks the roster ---------- */

const FIREBASE_SDK = "https://www.gstatic.com/firebasejs/11.0.2";
let phone = "";
let fb = null;            // { auth, mod } once the SDK has loaded
let verifier = null;      // invisible reCAPTCHA, required by Firebase before it sends an SMS
let confirmation = null;  // Firebase's handle for the code we just sent
let resendTimer = 0;

const FIREBASE_ERRORS = {
  "auth/invalid-phone-number": "That number doesn't look right",
  "auth/too-many-requests": "Too many tries from this device. Wait a while and try again",
  "auth/missing-verification-code": "Enter the 6-digit code",
  "auth/session-expired": "That code expired. Tap “Resend code”",
  "auth/billing-not-enabled": "SMS sending isn't switched on yet (Firebase needs the Blaze plan, HANDOVER.md step 3)",
  "auth/invalid-app-credential": "Couldn't verify this browser. Reload the page and try again",
  "auth/web-storage-unsupported": "Turn off private browsing to log in",
  "auth/quota-exceeded": "SMS limit reached for today. Try again tomorrow",
  "auth/invalid-verification-code": "Wrong code. Check the SMS and try again",
  "auth/code-expired": "That code expired. Tap “Resend code”",
  "auth/captcha-check-failed": "This website isn't authorized for SMS login yet (Firebase → Authorized domains)",
  "auth/operation-not-allowed": "Phone sign-in is switched off in Firebase",
  "auth/network-request-failed": "No internet connection",
};
// No Firebase config yet = demo mode: the server makes the code and the page shows it.
const firebaseReady = () => Boolean(window.MESS_FIREBASE?.apiKey && window.MESS_FIREBASE?.projectId);
let demoCode = "";

const fbError = e => new Error(FIREBASE_ERRORS[e?.code] || e?.message || "Something went wrong");

async function firebaseAuth() {
  if (fb) return fb;
  const cfg = window.MESS_FIREBASE;
  if (!cfg?.apiKey || !cfg?.projectId) throw new Error("SMS login isn't set up yet (HANDOVER.md, step 3)");
  // Loaded only when someone logs in, so the page itself stays light.
  const [{ initializeApp }, mod] = await Promise.all([
    import(`${FIREBASE_SDK}/firebase-app.js`),
    import(`${FIREBASE_SDK}/firebase-auth.js`),
  ]);
  const auth = mod.getAuth(initializeApp(cfg));
  auth.languageCode = "en";
  return (fb = { auth, mod });
}

async function sendCode() {
  const { auth, mod } = await firebaseAuth();
  verifier ??= new mod.RecaptchaVerifier(auth, "recaptcha", { size: "invisible" });
  try {
    confirmation = await mod.signInWithPhoneNumber(auth, `+91${phone}`, verifier);
  } catch (e) {
    verifier.clear();  // a used or failed reCAPTCHA can't be reused
    verifier = null;
    $("recaptcha").replaceChildren();
    throw fbError(e);
  }
  startResendCountdown();
}

function startResendCountdown(seconds = 30) {
  clearInterval(resendTimer);
  const btn = $("resend");
  btn.disabled = true;
  const tick = () => {
    btn.textContent = seconds > 0 ? `Resend code in ${seconds}s` : "Resend code";
    if (seconds-- <= 0) { btn.disabled = false; clearInterval(resendTimer); }
  };
  tick();
  resendTimer = setInterval(tick, 1000);
}

function show(step) {
  const next = $(step);
  for (const id of ["step-phone", "step-otp", "step-book"]) $(id).hidden = id !== step;
  next.classList.remove("enter"); void next.offsetWidth; next.classList.add("enter");
}

// Errors on the login steps appear inside the panel (not a toast), right where the person is looking.
function say(id, msg) {
  $(id).textContent = msg || "";
  $(id).hidden = !msg;
}

async function withBusy(btn, fn, msgId) {
  btn.disabled = true;
  btn.classList.add("busy");
  if (msgId) say(msgId, "");
  try { await fn(); }
  catch (e) { msgId ? say(msgId, e.message) : toast(e.message); }
  finally { btn.disabled = false; btn.classList.remove("busy"); }
}

const pretty = p => `+91 ${p.slice(0, 5)} ${p.slice(5)}`;

/* ---------- the six boxes ---------- */

const boxes = [...document.querySelectorAll(".otp-boxes span")];
boxes.forEach((b, i) => b.style.setProperty("--i", i));
function paintBoxes() {
  const v = $("otp").value;
  boxes.forEach((b, i) => {
    b.textContent = v[i] || "";
    b.classList.toggle("filled", i < v.length);
    b.classList.toggle("next", i === Math.min(v.length, 5) && v.length < 6);
  });
}
function otpState(state) {  // "" | "wrong" | "right"
  const wrap = $("otp-wrap");
  wrap.classList.remove("wrong", "right"); void wrap.offsetWidth;
  if (state) wrap.classList.add(state);
}

$("phone").addEventListener("input", e => {
  e.target.value = e.target.value.replace(/\D/g, "").replace(/^(91|0)(?=\d{10}$)/, "").slice(0, 10);
  say("phone-msg", "");
});
$("otp").addEventListener("input", e => {
  e.target.value = e.target.value.replace(/\D/g, "").slice(0, 6);
  otpState("");
  say("otp-msg", "");
  paintBoxes();
  if (e.target.value.length === 6) $("otp-form").requestSubmit();  // typing the last digit, paste or SMS autofill logs straight in
});
$("otp").addEventListener("focus", () => $("otp-wrap").classList.add("focus"));
$("otp").addEventListener("blur", () => $("otp-wrap").classList.remove("focus"));

/* ---------- step 1: number ---------- */

$("phone-form").addEventListener("submit", e => {
  e.preventDefault();
  const value = $("phone").value.trim();
  if (!/^[6-9]\d{9}$/.test(value)) return say("phone-msg", "Enter your 10-digit mobile number");
  withBusy(e.target.querySelector("button[type=submit]"), async () => {
    // Ask our server first, so no SMS is spent on a number that can't log in anyway.
    const res = await api("/auth/check", { method: "POST", body: { phone: value } });
    phone = value;
    if (firebaseReady()) await sendCode();
    else showDemoCode(res.demo_code);
    $("otp-phone").textContent = pretty(phone);
    $("otp").value = "";
    otpState("");
    paintBoxes();
    say("otp-msg", "");
    show("step-otp");
    $("otp").focus();
  }, "phone-msg");
});

/* ---------- step 2: code ---------- */

$("otp-form").addEventListener("submit", e => {
  e.preventDefault();
  const otp = $("otp").value.trim();
  if (!/^\d{6}$/.test(otp)) return say("otp-msg", "The code is 6 digits");
  const btn = e.target.querySelector("button[type=submit]");
  if (btn.disabled) return;  // autofill and a tap can both submit
  withBusy(btn, async () => {
    const wrong = err => {
      otpState("wrong");
      $("otp").value = "";
      paintBoxes();
      $("otp").focus();
      return err;
    };
    let res;
    if (firebaseReady()) {
      let idToken;
      try {
        const cred = await confirmation.confirm(otp);
        idToken = await cred.user.getIdToken();
      } catch (err) {
        throw wrong(fbError(err));
      }
      otpState("right");
      res = await api("/auth/login", { method: "POST", body: { id_token: idToken } });
      fb.mod.signOut(fb.auth).catch(() => {});  // our own token is the session from here on
    } else {
      try {
        res = await api("/auth/demo-verify", { method: "POST", body: { phone, otp } });
      } catch (err) {
        throw wrong(err);
      }
      otpState("right");
    }
    clearInterval(resendTimer);
    store.set("mess_token", res.token);
    store.set("mess_me", JSON.stringify(res.student));
    await new Promise(r => setTimeout(r, 450));  // let the green tick register before the page changes
    await openBooking(res.student);
    toast(`Welcome, ${res.student.full_name.split(" ")[0]}. Pick your meals.`);
  }, "otp-msg");
});

$("resend").addEventListener("click", e => withBusy(e.currentTarget, async () => {
  if (firebaseReady()) await sendCode();
  else showDemoCode((await api("/auth/check", { method: "POST", body: { phone } })).demo_code);
  $("otp").value = "";
  otpState("");
  paintBoxes();
  $("otp").focus();
  toast(`New code sent to ${pretty(phone)}`);
}, "otp-msg"));

function showDemoCode(code) {
  demoCode = code || "";
  $("demo-code").hidden = !demoCode;
  $("demo-code").innerHTML = "";
  if (!demoCode) return;
  const b = document.createElement("b");
  b.textContent = demoCode;
  $("demo-code").append("Demo mode (no SMS set up yet). Your code: ", b);
  startResendCountdown();
}

const backToPhone = () => { clearInterval(resendTimer); show("step-phone"); $("phone").focus(); };
$("back").addEventListener("click", backToPhone);
$("edit-phone").addEventListener("click", backToPhone);
$("logout").addEventListener("click", logout);

function logout() {
  store.del("mess_token");
  store.del("mess_me");
  show("step-phone");
}

function renderMe(me) {
  if (!me) return;
  $("me-name").textContent = me.full_name;
  $("me-meta").textContent = [me.reg_no, `${me.programme} · year ${me.year_of_study}`,
    `${me.hostel}, room ${me.room_no}`].join(" · ");
}

/* ---------- booking ---------- */

let selectedDate = null;

function renderDays() {
  const root = $("days");
  root.replaceChildren();
  for (let i = 0; i <= 7; i++) {
    const iso = istDay(i);
    const d = new Date(iso + "T00:00");
    const b = document.createElement("button");
    b.className = "day";
    b.setAttribute("role", "tab");
    b.setAttribute("aria-selected", String(iso === selectedDate));
    const top = document.createElement("span");
    top.textContent = i === 0 ? "Today" : i === 1 ? "Tmrw" : d.toLocaleDateString("en-IN", { weekday: "short" });
    const small = document.createElement("small");
    small.textContent = d.toLocaleDateString("en-IN", { day: "numeric", month: "short" });
    b.append(top, small);
    b.addEventListener("click", () => {
      selectedDate = iso;
      renderDays();
      renderSlots().catch(err => toast(err.message));
    });
    root.append(b);
  }
}

async function openBooking(me) {
  selectedDate ??= istDay(0);
  renderMe(me);
  $("pause-from").min = $("pause-to").min = istDay(0);
  $("pause-from").value ||= istDay(1);
  $("pause-to").value ||= istDay(3);
  show("step-book");
  renderDays();
  await Promise.all([renderSlots(), renderPauses()]);
}

async function renderSlots() {
  const [menu, mine] = await Promise.all([
    getMenu(),
    api(`/bookings/me?meal_date=${encodeURIComponent(selectedDate)}`),
  ]);
  const chosen = Object.fromEntries(mine.bookings.map(b => [b.slot_id, b]));
  const eaten = Object.fromEntries((mine.eaten || []).map(e => [e.slot_id, e]));  // recorded by the mess's face terminal
  $("paused-banner").hidden = !mine.paused;
  const root = $("slots");
  root.replaceChildren();
  // Cards fly in when the day changes, not on every re-render after a booking.
  root.classList.toggle("fresh", root.dataset.day !== selectedDate);
  root.dataset.day = selectedDate;

  for (const [i, slot] of menu.slots.entries()) {
    const current = chosen[slot.slot_id];
    const el = document.createElement("div");
    el.className = "slot" + (mine.paused ? " is-paused" : "");
    el.style.setProperty("--i", i);

    const head = document.createElement("div");
    head.className = "slot-head";
    const h3 = document.createElement("h3");
    h3.textContent = slot.name;
    const time = document.createElement("span");
    time.className = "time";
    time.textContent = `${slot.starts_at}–${slot.ends_at}`;
    head.append(h3, time);

    const choices = document.createElement("div");
    choices.className = "choices";
    for (const mess of slot.messes) {
      const b = document.createElement("button");
      b.className = "choice";
      b.dataset.mess = mess.mess_id;
      b.disabled = mine.paused;
      b.setAttribute("aria-pressed", String(current?.mess_id === mess.mess_id));
      const mini = document.createElement("span");
      mini.className = "mini";
      mini.innerHTML = window.plateHTML(mess.dishes, { small: true }); // dish names are escaped inside
      const text = document.createElement("span");
      const name = document.createElement("span");
      name.className = "name";
      name.textContent = mess.name;
      const dishes = document.createElement("span");
      dishes.className = "dishes";
      dishes.textContent = mess.dishes.join(" · ");
      text.append(name, document.createElement("br"), dishes);
      b.append(mini, text);
      b.addEventListener("click", () => book(slot, mess.mess_id));
      choices.append(b);
    }

    const skip = document.createElement("button");
    skip.className = "skip";
    skip.disabled = mine.paused;
    const status = current?.status;
    skip.setAttribute("aria-pressed", String(status === "skipped" || status === "paused"));
    skip.textContent = status === "paused" ? "Paused - you're away"
      : status === "skipped" ? "Skipping - not counted" : "Skip this meal";
    skip.addEventListener("click", () => book(slot, null));

    el.append(head, choices, skip);
    const ate = eaten[slot.slot_id];
    if (ate) el.append(ratingRow(slot, ate));
    // Once a meal is closed (by the database's scheduled event), show where its leftovers went.
    const given = (mine.donations || []).filter(x => x.slot_id === slot.slot_id);
    if (given.length) {
      const note = document.createElement("p");
      note.className = "donated";
      note.textContent = "Leftovers donated: " + given.map(x => `${x.mess} ${x.portions} portions → ${x.ngo}`).join(" · ");
      el.append(note);
    }
    root.append(el);
  }
}

// After eating, a student can rate the meal 1-5 stars (the database only accepts it for a meal actually eaten).
function ratingRow(slot, ate) {
  const mess = slot.messes.find(m => m.mess_id === ate.mess_id);
  const row = document.createElement("div");
  row.className = "rate";
  const label = document.createElement("span");
  label.textContent = ate.stars ? `You rated ${mess?.name || "this meal"}` : `Ate at ${mess?.name || "the mess"}. How was it?`;
  const stars = document.createElement("div");
  stars.className = "stars";
  stars.setAttribute("role", "radiogroup");
  stars.setAttribute("aria-label", `Rate ${slot.name}`);
  for (let n = 1; n <= 5; n++) {
    const b = document.createElement("button");
    b.type = "button";
    b.textContent = "★";
    b.className = n <= (ate.stars || 0) ? "on" : "";
    b.setAttribute("aria-label", `${n} star${n > 1 ? "s" : ""}`);
    b.addEventListener("click", async () => {
      try {
        await api("/ratings", { method: "POST", body: { meal_date: selectedDate, slot_id: slot.slot_id, stars: n } });
        toast(`Thanks! ${slot.name} rated ${n}★`);
        await renderSlots();
      } catch (e) { toast(e.message); }
    });
    stars.append(b);
  }
  row.append(label, stars);
  return row;
}

async function book(slot, messId) {
  try {
    await api("/bookings", { method: "POST", body: { meal_date: selectedDate, slot_id: slot.slot_id, mess_id: messId } });
    const mess = slot.messes.find(m => m.mess_id === messId);
    toast(mess ? `${slot.name} → ${mess.name}. Saved.` : `${slot.name} skipped. You won't be counted.`);
    await renderSlots();
    refreshLive();
  } catch (e) {
    toast(e.message);
  }
}

/* ---------- pause / resume ---------- */

const fmt = iso => new Date(iso + "T00:00").toLocaleDateString("en-IN", { day: "numeric", month: "short" });

async function renderPauses() {
  const { pauses } = await api("/pause/me");
  const list = $("pause-list");
  list.replaceChildren();
  for (const p of pauses) {
    const li = document.createElement("li");
    li.textContent = `Away ${fmt(p.from_date)} → ${fmt(p.to_date)}`;
    list.append(li);
  }
  $("resume").hidden = pauses.length === 0;
}

$("pause-form").addEventListener("submit", e => {
  e.preventDefault();
  const from_date = $("pause-from").value, to_date = $("pause-to").value;
  if (!from_date || !to_date) return toast("Pick both dates");
  withBusy(e.target.querySelector("button[type=submit]"), async () => {
    await api("/pause", { method: "POST", body: { from_date, to_date } });
    toast(`Paused ${fmt(from_date)} → ${fmt(to_date)}. Those meals won't be cooked for you.`);
    await Promise.all([renderPauses(), renderSlots()]);
    refreshLive();
  });
});

$("resume").addEventListener("click", e => withBusy(e.currentTarget, async () => {
  await api("/resume", { method: "POST" });
  toast("Welcome back! Book your meals again.");
  await Promise.all([renderPauses(), renderSlots()]);
}));

/* ---------- live forecast from v_daily_forecast ---------- */

const lastCounts = {};

async function refreshLive() {
  try {
    const [menu, { forecast, headline }] = await Promise.all([getMenu(), apiFetch("/stats/today")]);
    // Live counters in the "how" section: set the target, or the text once the count-up has run.
    for (const n of document.querySelectorAll(".how-num[data-key]")) {
      const v = Number(headline?.[n.dataset.key] ?? 0);
      if (Number(n.dataset.count) === v) continue;
      n.dataset.count = v;
      const dec = +(n.dataset.decimals || 0);
      const show = x => (n.textContent = (n.dataset.prefix || "") + x.toFixed(dec) + (n.dataset.suffix || ""));
      if (document.documentElement.classList.contains("how-static")) show(v);
      else if (n.classList.contains("counted") && window.gsap) {  // already counted to an older value: glide to the new one
        const o = { v: parseFloat(n.textContent) || 0 };
        gsap.to(o, { v, duration: 1.2, ease: "power3.out", onUpdate: () => show(o.v) });
      }
    }
    const by = Object.fromEntries(forecast.map(f => [`${f.meal}|${f.mess}`, f]));
    const total = forecast.reduce((s, f) => s + f.booked, 0);
    $("live-note").textContent = total
      ? `${total} plates booked for today. Refreshes every 5 seconds.`
      : "No bookings for today yet. Be the first. Refreshes every 5 seconds.";

    const grid = $("live-grid");
    if (!grid.children.length) {
      for (const slot of menu.slots) {
        const cell = document.createElement("div");
        cell.className = "live-cell";
        const h3 = document.createElement("h3");
        h3.textContent = slot.name;
        cell.append(h3);
        for (const mess of slot.messes) {
          const row = document.createElement("div");
          row.className = "live-mess";
          row.dataset.mess = mess.mess_id;
          row.dataset.key = `${slot.name}|${mess.name}`;
          row.innerHTML = `<span class="name"></span><span><span class="n">0</span> <span class="cook"></span></span>`;
          row.querySelector(".name").textContent = mess.name;
          cell.append(row);
        }
        grid.append(cell);
      }
    }
    for (const row of grid.querySelectorAll(".live-mess")) {
      const f = by[row.dataset.key];
      const n = f ? f.booked : 0;
      const el = row.querySelector(".n");
      if (lastCounts[row.dataset.key] !== undefined && lastCounts[row.dataset.key] !== n) {
        el.classList.remove("bump"); void el.offsetWidth; el.classList.add("bump");
      }
      lastCounts[row.dataset.key] = n;
      el.textContent = n;
      row.querySelector(".cook").textContent = `cook ${f ? f.cook_for : 0}`;
    }
  } catch {
    $("live-note").textContent = "Mess server offline right now. If you're running it locally, start it with start.bat.";
  }
}

refreshLive();
setInterval(refreshLive, 5000);

// Resume a saved session: show the saved profile at once, then refresh it from the roster.
if (store.get("mess_token")) {
  let saved = null;
  try { saved = JSON.parse(store.get("mess_me")); } catch {}
  openBooking(saved).catch(() => show("step-phone"));
  api("/me").then(r => { store.set("mess_me", JSON.stringify(r.student)); renderMe(r.student); }).catch(() => {});
}
