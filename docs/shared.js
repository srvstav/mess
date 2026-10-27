// Shared by every page: which server to call, a fetch wrapper, and the toast.
// ?api=<url> points the site at another server and is remembered; ?api=reset forgets it.
window.API = (() => {
  const q = new URLSearchParams(location.search).get("api");
  try {
    if (q === "reset") localStorage.removeItem("mess_api");
    else if (q && /^https?:\/\//.test(q)) localStorage.setItem("mess_api", q.replace(/\/$/, ""));
    return localStorage.getItem("mess_api") || window.MESS_API_DEFAULT;
  } catch { return q && q !== "reset" ? q : window.MESS_API_DEFAULT; }
})();

window.store = {
  get: k => { try { return localStorage.getItem(k); } catch { return null; } },
  set: (k, v) => { try { localStorage.setItem(k, v); } catch {} },
  del: k => { try { localStorage.removeItem(k); } catch {} },
};

window.toast = msg => {
  const t = document.getElementById("toast");
  if (!t) return;
  t.textContent = msg;
  t.classList.add("show");
  clearTimeout(window.toast.timer);
  window.toast.timer = setTimeout(() => t.classList.remove("show"), 2800);
};

// The free cloud server sleeps when idle and needs up to a minute to wake.
// Requests wait up to 75 s, and a toast explains the wait after 4 s.
window.apiFetch = async (path, { method = "GET", body, headers = {}, onUnauthorized } = {}) => {
  if (!window.API) throw new Error("The cloud server isn't set up yet - see README, section C");
  const ctrl = new AbortController();
  const kill = setTimeout(() => ctrl.abort(), 75000);
  const slow = setTimeout(() => window.toast("Waking up the server (free cloud plan) - up to a minute…"), 4000);
  let res;
  try {
    res = await fetch(window.API + path, {
      method, signal: ctrl.signal,
      headers: { "Content-Type": "application/json", ...headers },
      body: body ? JSON.stringify(body) : undefined,
    });
  } catch {
    document.getElementById("live-dot")?.classList.remove("on");
    // Local runs: the usual cause is a closed start.bat window or MySQL not running.
    throw new Error(location.hostname.endsWith("github.io")
      ? "Can't reach the mess server"
      : "Can't reach the mess server - is start.bat still open? Check localhost:8000/health");
  } finally {
    clearTimeout(kill);
    clearTimeout(slow);
  }
  document.getElementById("live-dot")?.classList.add("on");
  const data = await res.json().catch(() => ({}));
  if (res.status === 401 && onUnauthorized) { onUnauthorized(); throw new Error("Session ended - log in again"); }
  if (!res.ok) {
    const d = data.detail;
    throw new Error(typeof d === "string" ? d : Array.isArray(d) && d[0]?.msg ? d[0].msg.replace(/^Value error, /, "") : "Check what you entered");
  }
  return data;
};

// Today's date in India, as YYYY-MM-DD, whatever the viewer's timezone.
window.istDay = (offsetDays = 0) => {
  const d = new Date(Date.now() + offsetDays * 86400000);
  return new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Kolkata" }).format(d);
};
window.istTime = () => new Intl.DateTimeFormat("en-GB", { timeZone: "Asia/Kolkata", hour: "2-digit", minute: "2-digit", hour12: false }).format(new Date());
