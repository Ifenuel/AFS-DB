/* Apex Financial Services — site chrome and motion.
   No framework: a drawer menu, a header state, and GSAP for the entrance and
   scroll reveals. If GSAP fails to load, the CSS reveal classes still work. */
(function () {
  "use strict";

  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var hasGsap = typeof window.gsap !== "undefined";

  if (!reduced) document.documentElement.classList.add("js-motion");

  /* ---------------- mobile drawer ---------------- */
  var body = document.body;
  var openBtn = document.querySelector(".menu-btn");
  var closeBtn = document.querySelector(".drawer-close");
  var drawer = document.getElementById("drawer");
  var lastFocus = null;

  function openMenu() {
    if (!drawer) return;
    lastFocus = document.activeElement;
    body.classList.add("menu-open");
    if (openBtn) openBtn.setAttribute("aria-expanded", "true");
    drawer.removeAttribute("aria-hidden");
    var first = drawer.querySelector("a, button");
    if (first) setTimeout(function () { first.focus(); }, 60);
    if (hasGsap && !reduced) {
      window.gsap.fromTo(".drawer-nav a",
        { opacity: 0, y: 14 },
        { opacity: 1, y: 0, duration: .4, stagger: .035, ease: "power2.out", overwrite: true });
    }
  }

  function closeMenu(restoreFocus) {
    body.classList.remove("menu-open");
    if (openBtn) openBtn.setAttribute("aria-expanded", "false");
    if (drawer) drawer.setAttribute("aria-hidden", "true");
    if (restoreFocus && lastFocus && lastFocus.focus) lastFocus.focus();
  }

  if (openBtn) openBtn.addEventListener("click", function () {
    if (body.classList.contains("menu-open")) closeMenu(true); else openMenu();
  });
  if (closeBtn) closeBtn.addEventListener("click", function () { closeMenu(true); });
  if (drawer) {
    drawer.addEventListener("click", function (e) {
      if (e.target === drawer) closeMenu(true);
      var link = e.target.closest && e.target.closest("a");
      if (link) closeMenu(false);
    });
  }
  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape" && body.classList.contains("menu-open")) closeMenu(true);
  });
  window.addEventListener("resize", function () {
    if (window.innerWidth > 1180 && body.classList.contains("menu-open")) closeMenu(false);
  });

  /* ---------------- header on scroll ---------------- */
  var topbar = document.querySelector(".topbar");
  var onScroll = function () {
    if (!topbar) return;
    topbar.classList.toggle("scrolled", window.scrollY > 8);
  };
  onScroll();
  window.addEventListener("scroll", onScroll, { passive: true });

  /* ---------------- reveals ---------------- */
  var revealables = [].slice.call(document.querySelectorAll("[data-reveal]"));
  if ("IntersectionObserver" in window && !reduced) {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting) return;
        entry.target.classList.add("is-in");
        io.unobserve(entry.target);
        countUp(entry.target);
      });
    }, { rootMargin: "0px 0px -8% 0px", threshold: 0.08 });
    revealables.forEach(function (el) { io.observe(el); });
  } else {
    revealables.forEach(function (el) { el.classList.add("is-in"); });
  }

  /* ---------------- numbers that count up ---------------- */
  function countUp(scope) {
    if (reduced || !hasGsap) return;
    var nodes = [].slice.call(scope.querySelectorAll(".stat strong"));
    nodes.forEach(function (node) {
      var raw = node.textContent.trim();
      if (!/^[0-9][0-9,]*(\.[0-9]+)?$/.test(raw)) return;
      var target = parseFloat(raw.replace(/,/g, ""));
      if (!isFinite(target) || target <= 0) return;
      var decimals = (raw.split(".")[1] || "").length;
      var obj = { v: 0 };
      window.gsap.to(obj, {
        v: target, duration: 1.1, ease: "power2.out",
        onUpdate: function () {
          node.textContent = obj.v.toLocaleString("en-US", {
            minimumFractionDigits: decimals, maximumFractionDigits: decimals
          });
        }
      });
    });
  }

  /* ---------------- hero entrance ---------------- */
  if (hasGsap && !reduced) {
    var heroBits = [].slice.call(document.querySelectorAll("[data-hero]"));
    if (heroBits.length) {
      // A backgrounded tab pauses requestAnimationFrame, which would leave the
      // hero half-faded. The timer and visibility hook force the end state.
      var settle = function () {
        window.gsap.set(heroBits, { clearProps: "opacity,transform" });
      };
      window.gsap.fromTo(heroBits,
        { opacity: 0, y: 24 },
        { opacity: 1, y: 0, duration: .85, stagger: .09, ease: "power3.out", onComplete: settle });
      setTimeout(settle, 1400);
      document.addEventListener("visibilitychange", function () {
        if (!document.hidden) setTimeout(settle, 120);
      });
    }
    var chart = document.querySelector(".chart");
    if (chart) {
      window.gsap.fromTo(chart.querySelectorAll("rect.c-bar, rect.c-bar-alt"),
        { scaleY: 0, transformOrigin: "bottom" },
        { scaleY: 1, duration: .7, stagger: .04, ease: "power2.out", delay: .15 });
    }
  }
  /* ---------------- pointer-reactive portrait ---------------- */
  (function () {
    if (reduced) return;
    var tilts = [].slice.call(document.querySelectorAll("[data-tilt]"));
    tilts.forEach(function (el) {
      var raf = null;
      var move = function (e) {
        var r = el.getBoundingClientRect();
        var px = (e.clientX - r.left) / r.width - 0.5;
        var py = (e.clientY - r.top) / r.height - 0.5;
        if (raf) cancelAnimationFrame(raf);
        raf = requestAnimationFrame(function () {
          el.style.setProperty("--mx", px.toFixed(3));
          el.style.setProperty("--my", py.toFixed(3));
        });
      };
      var reset = function () {
        el.style.setProperty("--mx", "0");
        el.style.setProperty("--my", "0");
      };
      el.addEventListener("pointermove", move);
      el.addEventListener("pointerleave", reset);
    });
  })();
})();
