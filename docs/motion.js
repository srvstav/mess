// Scroll animation (GSAP + ScrollTrigger, Lenis for smooth wheel scrolling).
// The page still works if the libraries fail to load or the viewer prefers reduced motion.
(async () => {
  const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const hasGsap = typeof gsap !== "undefined" && typeof ScrollTrigger !== "undefined";
  const $ = id => document.getElementById(id);

  // Don't let a slow or dead server hold the page: fall back to the built-in menu after 2.5 s.
  const menu = await Promise.race([
    window.Mess.getMenu(),
    new Promise(r => setTimeout(() => r(window.Mess.FALLBACK_MENU), 2500)),
  ]);

  const MEAL_THEME = {
    Breakfast: { bg: "#FFC83A", dark: false, line: "sunrise, served" },
    Lunch:     { bg: "#FF4A1C", dark: true,  line: "the big one" },
    "Hi-Tea":  { bg: "#F8B7CB", dark: false, line: "chai o'clock" },
    Dinner:    { bg: "#1E2BD6", dark: true,  line: "lights low, plates full" },
  };

  /* ---------- build DOM from the menu ---------- */

  $("hero-plate").innerHTML = window.plateHTML(["A full thali"], { key: "hero", eager: true });

  const allDishes = [...new Set(menu.slots.flatMap(s => s.messes.flatMap(m => m.dishes)))];
  const marquee = $("marquee");
  for (const d of [...allDishes, ...allDishes]) {
    const s = document.createElement("span");
    s.textContent = d;
    marquee.append(s);
  }

  const track = $("meals-track");
  for (const slot of menu.slots) {
    const theme = MEAL_THEME[slot.name] || { bg: "#FFC83A", dark: false, line: "" };
    const panel = document.createElement("article");
    panel.className = "meal" + (theme.dark ? " dark" : "");
    panel.dataset.bg = theme.bg;

    const head = document.createElement("div");
    head.className = "meal-head";
    const h = document.createElement("h2");
    h.className = "meal-name";
    h.textContent = slot.name;
    const t = document.createElement("span");
    t.className = "meal-time";
    t.textContent = `${slot.starts_at}–${slot.ends_at} · ${theme.line}`;
    head.append(h, t);

    const body = document.createElement("div");
    body.className = "meal-body";
    for (const mess of slot.messes) {
      const col = document.createElement("div");
      col.className = "mess-col";
      col.dataset.mess = mess.mess_id;
      const plate = document.createElement("div");
      plate.className = "plate";
      plate.innerHTML = window.plateHTML(mess.dishes);
      const info = document.createElement("div");
      const tag = document.createElement("span");
      tag.className = "mess-tag";
      tag.textContent = mess.name;
      const ul = document.createElement("ul");
      ul.className = "dish-list";
      for (const d of mess.dishes) {
        const li = document.createElement("li");
        li.textContent = d;
        ul.append(li);
      }
      info.append(tag, ul);
      col.append(plate, info);
      body.append(col);
    }
    panel.append(head, body);
    track.append(panel);
  }
  $("meals").style.backgroundColor = track.firstElementChild?.dataset.bg || "";

  // Split statement into words, hero lines into characters.
  const words = document.querySelector(".reveal-words");
  words.innerHTML = words.innerHTML.replace(/(<em>.*?<\/em>|[^\s<]+)/g, '<span class="w">$1</span>');
  for (const h of document.querySelectorAll(".hero .split")) {
    // Wrap each word so lines only break between words, never inside one.
    h.innerHTML = h.textContent.trim().split(/\s+/)
      .map(word => `<span class="word">${[...word].map(c => `<span class="ch">${c}</span>`).join("")}</span>`)
      .join(" ");
  }

  if (reduced || !hasGsap) {
    document.documentElement.classList.add("no-motion");
    document.querySelectorAll(".reveal-words .w").forEach(w => (w.style.opacity = 1));
    document.querySelectorAll(".how-num").forEach(n => (n.textContent = (n.dataset.prefix || "") + n.dataset.count + (n.dataset.suffix || "")));
    document.documentElement.classList.add("how-static");
    // Colour each stacked meal section itself when there is no pinned scroll.
    document.querySelectorAll(".meal").forEach(p => (p.style.background = p.dataset.bg));
    return;
  }

  gsap.registerPlugin(ScrollTrigger);
  gsap.defaults({ ease: "expo.out", duration: 1 });

  /* ---------- smooth wheel scrolling; touch keeps the phone's own scrolling ---------- */
  let lenis = null;
  if (typeof Lenis !== "undefined") {
    lenis = new Lenis({ lerp: 0.1, smoothWheel: true });
    lenis.on("scroll", ScrollTrigger.update);
    gsap.ticker.add(time => lenis.raf(time * 1000));
    gsap.ticker.lagSmoothing(0);
  }

  /* ---------- hero ---------- */
  gsap.timeline()
    .from(".hero .ch", { yPercent: 115, rotate: 10, duration: 1.1, stagger: 0.022 })
    .from("#hero-plate", { scale: 0.5, rotate: -140, opacity: 0, duration: 1.6 }, 0.1)
    .from([".kicker", ".lede", ".cta"], { y: 28, opacity: 0, duration: 0.9, stagger: 0.09, ease: "power3.out" }, 0.45)
    .from(".sticker", { scale: 0, rotate: -30, duration: 0.9, ease: "elastic.out(1, 0.55)", stagger: 0.14 }, 0.9);
  // The plate turns slowly on its own, and faster as you scroll past it.
  gsap.to("#hero-plate .plate-img", { rotate: 360, duration: 90, ease: "none", repeat: -1 });
  gsap.to("#hero-plate", { rotate: 160, ease: "none", scrollTrigger: { trigger: ".hero", start: "top top", end: "bottom top", scrub: 1.2 } });
  gsap.to(".hero-copy", { yPercent: -16, opacity: 0.15, ease: "none", scrollTrigger: { trigger: ".hero", start: "top top", end: "bottom top", scrub: 0.8 } });
  gsap.to(".sticker", { y: -8, duration: 2.2, ease: "sine.inOut", yoyo: true, repeat: -1, stagger: 0.6, delay: 2 });

  /* ---------- marquee: endless, speeds up while scrolling ---------- */
  const loop = gsap.to(marquee, { xPercent: -50, duration: 40, ease: "none", repeat: -1 });
  ScrollTrigger.create({
    onUpdate: self => {
      const v = Math.min(Math.abs(self.getVelocity()) / 400, 6);
      gsap.to(loop, { timeScale: 1 + v, duration: 0.25, ease: "power2.out", overwrite: true });
      gsap.to(loop, { timeScale: 1, duration: 1.2, ease: "power2.out", delay: 0.3 });
    },
  });

  /* ---------- statement: words light up as you read ---------- */
  gsap.to(".reveal-words .w", {
    opacity: 1, stagger: 0.08, ease: "none",
    scrollTrigger: { trigger: ".statement", start: "top 75%", end: "bottom 60%", scrub: 0.6 },
  });

  /* ---------- meals: pinned, sideways, one smooth scrub ----------
     The row moves at an even pace between meals. Only after the last meal does it stop: Dinner lands
     with an elastic settle and stays pinned for a while (HOLD) so it can be read before the page moves on. */
  const panels = gsap.utils.toArray(".meal");
  const last = panels[panels.length - 1];
  const moves = Math.max(1, panels.length - 1);
  // Measured to the last meal, not scrollWidth: elements waiting off to the side would stretch scrollWidth.
  const distance = () => last.offsetLeft;
  const holdPx = () => innerHeight * 0.9;                     // reading stop at the end, in scroll pixels
  const HOLD = holdPx() / (distance() / moves || 1);           // the same stop, in timeline seconds

  const meals = gsap.timeline({
    defaults: { ease: "none" },
    scrollTrigger: {
      trigger: "#meals", start: "top top", end: () => "+=" + (distance() + holdPx()),
      pin: true, scrub: 1, anticipatePin: 1, invalidateOnRefresh: true,
      onUpdate: self => gsap.set("#meals-bar", { scaleX: Math.min(1, self.progress * (moves + HOLD) / moves) }),
    },
  });
  meals.to(track, { x: () => -distance(), duration: moves }, 0);

  panels.forEach((panel, i) => {
    const arrive = i - 1;  // timeline time when this panel starts sliding in
    if (i > 0) {
      // fromTo, not from: invalidateOnRefresh re-reads a from() tween's end state, which could be the hidden one.
      meals.to("#meals", { backgroundColor: panel.dataset.bg, duration: 0.3 }, arrive + 0.45)
        .fromTo(panel.querySelector(".meal-name"), { yPercent: 60, opacity: 0 }, { yPercent: 0, opacity: 1, duration: 0.5, ease: "power3.out" }, arrive + 0.3)
        .fromTo(panel.querySelectorAll(".dish-list li"), { x: 60, opacity: 0 }, { x: 0, opacity: 1, duration: 0.4, stagger: 0.04, ease: "power2.out" }, arrive + 0.4);
    }
    // Plates roll in as their meal arrives and roll on as it leaves; the last one comes to rest.
    panel.querySelectorAll(".plate").forEach((plate, k) => {
      const dir = k ? 1 : -1;
      if (i > 0) meals.fromTo(plate, { rotate: 90 * dir, scale: 0.75 }, { rotate: 0, scale: 1, duration: 1 }, arrive);
      if (panel !== last) meals.to(plate, { rotate: -90 * dir, scale: 0.8, duration: 1 }, i);
    });
  });

  // The one elastic moment: Dinner springs into place, then the hold keeps it still.
  const settle = () => {
    gsap.fromTo(last.querySelectorAll(".plate-img"), { scale: 0.92, rotate: i => (i ? 12 : -12) },
      { scale: 1, rotate: 0, duration: 1.4, ease: "elastic.out(1, 0.4)", overwrite: true });
    gsap.fromTo(last.querySelector(".meal-name"), { skewX: -7 },
      { skewX: 0, duration: 1.2, ease: "elastic.out(1.1, 0.38)", overwrite: "auto" });
  };
  meals.call(settle, null, moves).to({}, { duration: HOLD }, moves);

  /* ---------- numbers count up ---------- */
  document.querySelectorAll(".how-num").forEach(n => {
    const obj = { v: 0 };
    const dec = +(n.dataset.decimals || 0);
    const paint = () => (n.textContent = (n.dataset.prefix || "") + obj.v.toFixed(dec) + (n.dataset.suffix || ""));
    paint();
    const st = { trigger: n, start: "top 85%" };
    // The target is read when the count starts, so live numbers that arrived meanwhile are used.
    gsap.to(obj, { v: () => +n.dataset.count, duration: 1.6, ease: "power3.out", onUpdate: paint,
      onComplete: () => {
        n.classList.add("counted");
        // The live number may have arrived while counting: glide on to it.
        if (+n.dataset.count !== obj.v) gsap.to(obj, { v: +n.dataset.count, duration: 1, ease: "power3.out", onUpdate: paint });
      }, scrollTrigger: st });
    gsap.from(n, { yPercent: 40, opacity: 0, duration: 1.1, scrollTrigger: st });
    gsap.from(n.nextElementSibling, { y: 30, opacity: 0, duration: 1, delay: 0.1, scrollTrigger: st });
  });

  /* ---------- live + book + footer ---------- */
  gsap.from(".live-head > *", { y: 50, opacity: 0, stagger: 0.08, scrollTrigger: { trigger: ".live", start: "top 75%" } });
  ScrollTrigger.batch(".live-cell", {
    start: "top 90%", once: true,
    onEnter: cells => gsap.from(cells, { y: 40, opacity: 0, stagger: 0.07, duration: 0.9 }),
  });
  gsap.from(".book-intro > *", { y: 60, opacity: 0, stagger: 0.1, scrollTrigger: { trigger: ".book", start: "top 70%" } });
  gsap.from(".book-panel", { y: 90, rotate: 3, opacity: 0, duration: 1.2, scrollTrigger: { trigger: ".book", start: "top 70%" } });
  gsap.from(".foot-big", { yPercent: 30, opacity: 0, duration: 1.2, scrollTrigger: { trigger: ".foot", start: "top 80%" } });
  gsap.from(".foot-links a", { y: 20, opacity: 0, stagger: 0.06, duration: 0.8, scrollTrigger: { trigger: ".foot", start: "top 70%" } });

  // In-page links glide (through Lenis when it's running) and land correctly past the pinned section.
  document.querySelectorAll('a[href^="#"]').forEach(a => a.addEventListener("click", e => {
    const target = document.querySelector(a.getAttribute("href"));
    if (!target) return;
    e.preventDefault();
    if (lenis) lenis.scrollTo(target, { duration: 1.4 });
    else window.scrollTo({ top: target.getBoundingClientRect().top + scrollY, behavior: "smooth" });
  }));

  // Images change heights as they load; re-measure once everything is in.
  addEventListener("load", () => ScrollTrigger.refresh());
})();
