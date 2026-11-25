/* Apex Financial Services — schema explorer.
   Renders catalog tables as cards over an SVG connector layer.

   Routing: each foreign key leaves and enters at the *row of the column it
   actually uses* (not the card centre), and travels on axis-aligned
   segments chosen to avoid every other card. Candidates are scored by
   card intersections, crossings with already-routed links, bends and
   length, so the cheapest legal path wins.

   Filtering: a domain narrows the diagram and the remaining tables are
   re-laid out, so a three-table domain fills the canvas instead of sitting
   in the gaps of the full database. */
(function () {
  "use strict";

  var CARD_W = 220;
  var HEADER_H = 30;
  var ROW_H = 17;
  var MAX_ROWS = 8;
  var COL_GAP = 300;
  var ROW_GAP = 26;
  var PAD = 40;
  var ROUTE_PAD = 12;

  var root = document.getElementById("explorer");
  if (!root || !window.AFS_DATA) return;

  var DATA = window.AFS_DATA;
  var tabsEl = document.getElementById("xp-tabs");
  var chipsEl = document.getElementById("xp-domains");
  var canvasEl = document.getElementById("xp-canvas");
  var wrapEl = document.getElementById("xp-canvas-wrap");
  var detailEl = document.getElementById("xp-detail");
  var searchEl = document.getElementById("xp-search");
  var hintEl = document.getElementById("xp-status");

  var state = { db: DATA.databases[0].name, scale: 1, tx: 0, ty: 0, selected: null, domain: null, query: "" };
  var current = null;
  var layout = { width: 0, height: 0 };
  var routes = [];

  function cardHeight(t) { return HEADER_H + Math.min(t.columns.length, MAX_ROWS) * ROW_H + 10; }
  function keyOf(t) { return t.schema + "." + t.name; }

  function dbByName(name) {
    for (var i = 0; i < DATA.databases.length; i++) if (DATA.databases[i].name === name) return DATA.databases[i];
    return DATA.databases[0];
  }
  function domainById(id) {
    for (var i = 0; i < DATA.domains.length; i++) if (DATA.domains[i].id === id) return DATA.domains[i];
    return null;
  }

  /* ---------- layout ---------- */
  function computeLayout(tables, links) {
    var byKey = {};
    tables.forEach(function (t) { byKey[keyOf(t)] = t; t.h = cardHeight(t); });

    var parents = {};
    tables.forEach(function (t) { parents[keyOf(t)] = []; });
    links.forEach(function (l) {
      if (byKey[l.from] && byKey[l.to]) parents[l.from].push(l.to);
    });

    var depth = {};
    function depthOf(key, seen) {
      if (depth[key] != null) return depth[key];
      if (seen[key]) return 0;
      seen[key] = 1;
      var d = 0;
      parents[key].forEach(function (p) {
        var next = {};
        for (var k in seen) next[k] = 1;
        d = Math.max(d, depthOf(p, next) + 1);
      });
      depth[key] = d;
      return d;
    }
    tables.forEach(function (t) { depthOf(keyOf(t), {}); });

    var columns = {};
    tables.forEach(function (t) {
      var d = depth[keyOf(t)] || 0;
      (columns[d] = columns[d] || []).push(t);
    });

    var width = 0, height = 0;
    Object.keys(columns).map(Number).sort(function (a, b) { return a - b; }).forEach(function (d) {
      var y = PAD;
      columns[d].sort(function (a, b) {
        return a.schema === b.schema ? a.name.localeCompare(b.name) : a.schema.localeCompare(b.schema);
      });
      columns[d].forEach(function (t) {
        t.x = PAD + d * COL_GAP;
        t.y = y;
        y += t.h + ROW_GAP;
        width = Math.max(width, t.x + CARD_W + PAD + 20);
        height = Math.max(height, t.y + t.h + PAD);
      });
    });

    layout = { width: Math.max(width, 420), height: Math.max(height, 320) };
  }

  /* ---------- routing ---------- */
  function portFor(t, colName, side) {
    var idx = -1;
    for (var i = 0; i < t.columns.length && i < MAX_ROWS; i++) {
      if (t.columns[i].name === colName) { idx = i; break; }
    }
    var y = idx >= 0 ? t.y + HEADER_H + (idx + 0.5) * ROW_H : t.y + t.h / 2;
    if (side === "right") return { x: t.x + CARD_W, y: y };
    if (side === "left") return { x: t.x, y: y };
    if (side === "bottom") return { x: t.x + CARD_W / 2, y: t.y + t.h };
    return { x: t.x + CARD_W / 2, y: t.y };
  }

  function hit(seg, rect, pad) {
    var x1 = seg[0], y1 = seg[1], x2 = seg[2], y2 = seg[3];
    var minx = Math.min(x1, x2), maxx = Math.max(x1, x2);
    var miny = Math.min(y1, y2), maxy = Math.max(y1, y2);
    return !(maxx < rect.x - pad || minx > rect.x + rect.w + pad ||
             maxy < rect.y - pad || miny > rect.y + rect.h + pad);
  }

  function segCross(a, b) {
    var aH = a[1] === a[3], bH = b[1] === b[3];
    if (aH === bH) return 0;
    var h = aH ? a : b, v = aH ? b : a;
    var hy = h[1], hx1 = Math.min(h[0], h[2]), hx2 = Math.max(h[0], h[2]);
    var vx = v[0], vy1 = Math.min(v[1], v[3]), vy2 = Math.max(v[1], v[3]);
    return (vx > hx1 && vx < hx2 && hy > vy1 && hy < vy2) ? 1 : 0;
  }

  function toSegments(pts) {
    var out = [];
    for (var i = 1; i < pts.length; i++) out.push([pts[i - 1][0], pts[i - 1][1], pts[i][0], pts[i][1]]);
    return out;
  }

  function pathFrom(pts) {
    var d = "M" + pts[0][0].toFixed(1) + "," + pts[0][1].toFixed(1);
    for (var i = 1; i < pts.length; i++) d += "L" + pts[i][0].toFixed(1) + "," + pts[i][1].toFixed(1);
    return d;
  }

  function route(a, b, link, obstacles, placed) {
    var rightFirst = b.x >= a.x + CARD_W;
    var leftFirst = b.x + CARD_W <= a.x;
    var aSide, bSide;
    if (rightFirst) { aSide = "right"; bSide = "left"; }
    else if (leftFirst) { aSide = "left"; bSide = "right"; }
    else if (b.y >= a.y) { aSide = "bottom"; bSide = "top"; }
    else { aSide = "top"; bSide = "bottom"; }

    var A = portFor(a, (link.fromCols || [])[0], aSide);
    var B = portFor(b, (link.toCols || [])[0], bSide);

    var candidates = [];
    if (rightFirst || leftFirst) {
      var mids = [(A.x + B.x) / 2, A.x + (rightFirst ? 26 : -26), B.x + (rightFirst ? -26 : 26)];
      // a lane above and below the pair, for when the direct elbow is blocked
      var top = Math.min(a.y, b.y) - 34, bottom = Math.max(a.y + a.h, b.y + b.h) + 34;
      mids.forEach(function (mx) {
        candidates.push([[A.x, A.y], [mx, A.y], [mx, B.y], [B.x, B.y]]);
        candidates.push([[A.x, A.y], [mx, A.y], [mx, top], [B.x, top], [B.x, B.y]]);
        candidates.push([[A.x, A.y], [mx, A.y], [mx, bottom], [B.x, bottom], [B.x, B.y]]);
      });
    } else {
      var ymids = [(A.y + B.y) / 2, A.y + 26, B.y - 26];
      var leftLane = Math.min(a.x, b.x) - 34, rightLane = Math.max(a.x + CARD_W, b.x + CARD_W) + 34;
      ymids.forEach(function (my) {
        candidates.push([[A.x, A.y], [A.x, my], [B.x, my], [B.x, B.y]]);
        candidates.push([[A.x, A.y], [leftLane, A.y], [leftLane, B.y], [B.x, B.y]]);
        candidates.push([[A.x, A.y], [rightLane, A.y], [rightLane, B.y], [B.x, B.y]]);
      });
    }

    var best = null;
    candidates.forEach(function (pts) {
      var segs = toSegments(pts);
      var score = 0;
      segs.forEach(function (s) {
        obstacles.forEach(function (r) {
          if (r.self === a || r.self === b) return;
          if (hit(s, r, ROUTE_PAD)) score += 1000;
        });
        placed.forEach(function (other) {
          if (segCross(s, other)) score += 45;
        });
        score += (Math.abs(s[2] - s[0]) + Math.abs(s[3] - s[1])) * 0.06;
      });
      score += (segs.length - 1) * 6;
      if (!best || score < best.score) best = { pts: pts, segs: segs, score: score };
    });

    return best;
  }

  /* ---------- rendering ---------- */
  function renderTabs() {
    tabsEl.innerHTML = "";
    DATA.databases.forEach(function (db) {
      var b = document.createElement("button");
      b.className = "xp-tab";
      b.type = "button";
      b.setAttribute("role", "tab");
      b.setAttribute("aria-selected", String(db.name === state.db));
      b.innerHTML = "";
      b.appendChild(document.createTextNode(db.short || db.name));
      var n = document.createElement("span");
      n.className = "n";
      n.textContent = db.tables.length;
      b.appendChild(n);
      b.title = db.name + " — " + db.tables.length + " tables, " + db.links.length + " foreign keys";
      b.addEventListener("click", function () {
        // All filters are scoped to one database. Carrying a domain or search
        // across a switch is how a filter looks "stuck" on the wrong tables.
        state.db = db.name;
        state.selected = null;
        state.domain = null;
        state.query = "";
        if (searchEl) searchEl.value = "";
        build();
      });
      tabsEl.appendChild(b);
    });
  }

  function visibleSet() {
    var dom = state.domain ? domainById(state.domain) : null;
    var set = {};
    current.tables.forEach(function (t) {
      var k = keyOf(t);
      set[k] = dom ? dom.tables.indexOf(k) !== -1 : true;
    });
    return set;
  }

  function renderScope() {
    var el = document.getElementById("xp-scope");
    if (!el) return;
    var dom = state.domain ? domainById(state.domain) : null;
    var tables = 0;
    var rows = 0;
    current.tables.forEach(function (t) {
      if (dom && dom.tables.indexOf(keyOf(t)) === -1) return;
      tables += 1;
      rows += t.rows || 0;
    });
    var parts = [current.short];
    if (dom) parts.push(dom.label + " domain");
    parts.push(tables + (tables === 1 ? " table" : " tables"));
    parts.push(rows.toLocaleString() + " rows");
    if (!dom) parts.push(current.links.length + " foreign keys");
    el.textContent = parts.join("  ·  ");
  }

  function renderDomains() {
    if (!chipsEl) return;
    chipsEl.innerHTML = "";
    var present = {};
    current.tables.forEach(function (t) { present[keyOf(t)] = true; });

    var all = document.createElement("button");
    all.className = "chip";
    all.type = "button";
    all.textContent = "All " + current.tables.length + " tables";
    all.setAttribute("aria-pressed", String(state.domain === null));
    all.addEventListener("click", function () {
      state.domain = null;
      applyLayout();
    });
    chipsEl.appendChild(all);

    DATA.domains.forEach(function (d) {
      var keys = [];
      d.tables.forEach(function (k) { if (present[k] && keys.indexOf(k) === -1) keys.push(k); });
      var count = keys.length;
      // A domain with no table in this database cannot filter anything, so it
      // is left out instead of showing an empty chip.
      if (!count) return;
      var c = document.createElement("button");
      c.className = "chip";
      c.type = "button";
      c.textContent = d.label;
      var n = document.createElement("span");
      n.className = "n";
      n.textContent = count ? count + (count === 1 ? " table" : " tables") : "not here";
      c.appendChild(n);
      c.title = count
        ? d.description + " — " + count + " table(s) in " + current.short
        : d.description + " — these tables live in another database";
      c.setAttribute("aria-pressed", String(state.domain === d.id));
      c.disabled = count === 0;
      c.addEventListener("click", function () {
        if (!count) return;
        state.domain = state.domain === d.id ? null : d.id;
        if (state.selected && d.tables.indexOf(state.selected) === -1) state.selected = null;
        applyLayout();
      });
      chipsEl.appendChild(c);
    });
    renderScope();
  }

  function build() {
    current = dbByName(state.db);
    renderTabs();
    canvasEl.innerHTML = "";
    canvasEl.style.width = "0";
    canvasEl.style.height = "0";

    var byKey = {};
    current.tables.forEach(function (t) {
      byKey[keyOf(t)] = t;
      t.h = cardHeight(t);
      t.el = cardEl(t);
      canvasEl.appendChild(t.el);
    });

    if (!document.getElementById("xp-empty")) {
      var empty = document.createElement("div");
      empty.id = "xp-empty";
      empty.className = "xp-empty";
      empty.hidden = true;
      wrapEl.appendChild(empty);
    }

    applyLayout();
  }

  function applyLayout() {
    var scope = visibleSet();
    // A selection that the new scope filters out cannot stay selected.
    if (state.selected && !scope[state.selected]) state.selected = null;
    var tables = current.tables.filter(function (t) { return scope[keyOf(t)]; });
    var links = current.links.filter(function (l) { return scope[l.from] && scope[l.to]; });

    computeLayout(tables, links);

    current.tables.forEach(function (t) {
      var on = scope[keyOf(t)];
      t.el.classList.toggle("hidden", !on);
      if (on) {
        t.el.style.left = t.x + "px";
        t.el.style.top = t.y + "px";
        t.el.style.height = t.h + "px";
      }
      delete t.el.dataset.drawn;
    });

    canvasEl.style.width = layout.width + "px";
    canvasEl.style.height = layout.height + "px";

    var old = canvasEl.querySelector("svg.xp-links");
    if (old) old.remove();
    var svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("class", "xp-links");
    svg.setAttribute("width", layout.width);
    svg.setAttribute("height", layout.height);
    svg.setAttribute("viewBox", "0 0 " + layout.width + " " + layout.height);
    canvasEl.insertBefore(svg, canvasEl.firstChild);

    var obstacles = tables.map(function (t) { return { x: t.x, y: t.y, w: CARD_W, h: t.h, self: t }; });
    var placed = [];
    routes = [];

    links.forEach(function (link) {
      var a = byKeyLookup(link.from), b = byKeyLookup(link.to);
      if (!a || !b) return;
      var best = route(a, b, link, obstacles, placed);
      if (!best) return;
      placed = placed.concat(best.segs);

      var g = document.createElementNS("http://www.w3.org/2000/svg", "g");
      var p = document.createElementNS("http://www.w3.org/2000/svg", "path");
      p.setAttribute("d", pathFrom(best.pts));
      p.dataset.from = link.from;
      p.dataset.to = link.to;
      var t = document.createElementNS("http://www.w3.org/2000/svg", "title");
      t.textContent = (link.name || "FK") + ": " + link.from + "(" + (link.fromCols || []).join(", ") +
        ") \u2192 " + link.to + "(" + (link.toCols || []).join(", ") + ")" +
        (link.optional ? " [optional]" : " [mandatory]");
      p.appendChild(t);
      g.appendChild(p);

      [best.pts[0], best.pts[best.pts.length - 1]].forEach(function (pt) {
        var c = document.createElementNS("http://www.w3.org/2000/svg", "circle");
        c.setAttribute("cx", pt[0]);
        c.setAttribute("cy", pt[1]);
        c.setAttribute("r", 2.6);
        g.appendChild(c);
      });

      svg.appendChild(g);
      link.el = p;
      routes.push(p);
    });

    renderDomains();
    resetView(false);
    readableView();
    renderDetail(state.selected ? byKeyLookup(state.selected) : null);
    applyFilter(true);
    applyTransform();
  }

  function byKeyLookup(key) {
    for (var i = 0; i < current.tables.length; i++) if (keyOf(current.tables[i]) === key) return current.tables[i];
    return null;
  }

  function cardEl(t) {
    var el = document.createElement("div");
    el.className = "table-card";
    el.style.left = t.x + "px";
    el.style.top = t.y + "px";
    el.style.height = t.h + "px";
    el.dataset.key = keyOf(t);
    el.dataset.schema = t.schema;
    el.dataset.domain = t.domain;

    var head = document.createElement("header");
    var name = document.createElement("span");
    name.className = "name";
    name.textContent = t.name;
    var rows = document.createElement("span");
    rows.className = "rows";
    rows.textContent = t.rows === null || t.rows === undefined ? "" : t.rows.toLocaleString();
    head.appendChild(name);
    head.appendChild(rows);
    head.title = t.schema + "." + t.name;
    el.appendChild(head);

    var ul = document.createElement("ul");
    t.columns.slice(0, MAX_ROWS).forEach(function (c) {
      var li = document.createElement("li");
      if (c.pk) li.className = "pk";
      else if (c.fk) li.className = "fk";
      var n = document.createElement("span");
      n.textContent = c.name;
      var ty = document.createElement("span");
      ty.className = "type";
      ty.textContent = c.type;
      li.appendChild(n);
      li.appendChild(ty);
      ul.appendChild(li);
    });
    if (t.columns.length > MAX_ROWS) {
      var more = document.createElement("li");
      more.style.color = "var(--dim)";
      more.textContent = "+ " + (t.columns.length - MAX_ROWS) + " more";
      ul.appendChild(more);
    }
    el.appendChild(ul);

    el.addEventListener("click", function (ev) {
      ev.stopPropagation();
      select(state.selected === keyOf(t) ? null : keyOf(t));
    });
    return el;
  }

  /* ---------- view transform ---------- */
  function applyTransform() {
    canvasEl.style.transform = "translate(" + state.tx + "px," + state.ty + "px) scale(" + state.scale + ")";
    var zoomOut = document.getElementById("xp-zoom-out");
    if (zoomOut) zoomOut.disabled = state.scale <= 0.25;
  }

  function resetView(animate) {
    if (animate) canvasEl.style.transition = "transform .25s ease";
    state.scale = 1;
    state.tx = 0;
    state.ty = 0;
    applyTransform();
    if (animate) setTimeout(function () { canvasEl.style.transition = ""; }, 260);
  }

  function readableView() {
    var w = wrapEl.clientWidth || 900;
    var h = wrapEl.clientHeight || 600;
    // Fit horizontally, but never below 0.42: a diagram you cannot read is not
    // an overview. Vertical overflow is expected and panning is the answer.
    var s = Math.min(1, (w - 32) / layout.width, (h - 32) / layout.height);
    state.scale = Math.max(0.42, s);
    state.tx = 16;
    state.ty = 14;
    applyTransform();
  }

  function fitView() {
    var pad = 28;
    var w = wrapEl.clientWidth, h = wrapEl.clientHeight;
    var s = Math.min((w - pad * 2) / layout.width, (h - pad * 2) / layout.height);
    s = Math.max(0.22, Math.min(s, 1.2));
    state.scale = s;
    state.tx = (w - layout.width * s) / 2;
    state.ty = (h - layout.height * s) / 2;
    canvasEl.style.transition = "transform .25s ease";
    applyTransform();
    setTimeout(function () { canvasEl.style.transition = ""; }, 260);
  }

  function zoomAt(factor, cx, cy) {
    var rect = wrapEl.getBoundingClientRect();
    if (typeof cx !== "number") cx = rect.width / 2;
    if (typeof cy !== "number") cy = rect.height / 2;
    var next = Math.max(0.22, Math.min(2.4, state.scale * factor));
    var k = next / state.scale;
    state.tx = cx - (cx - state.tx) * k;
    state.ty = cy - (cy - state.ty) * k;
    state.scale = next;
    applyTransform();
  }

  /* ---------- filtering and selection ---------- */
  function applyFilter(skipDetail) {
    if (!current) return;
    var q = state.query.trim().toLowerCase();
    var scope = visibleSet();

    var visible = {};
    current.tables.forEach(function (t) {
      var k = keyOf(t);
      var inScope = scope[k];
      var matches = !q || k.toLowerCase().indexOf(q) !== -1 ||
        t.columns.some(function (c) { return c.name.toLowerCase().indexOf(q) !== -1; });
      visible[k] = inScope && matches;
    });

    var related = null;
    if (state.selected) {
      related = {};
      related[state.selected] = true;
      current.links.forEach(function (l) {
        if (l.from === state.selected) related[l.to] = true;
        if (l.to === state.selected) related[l.from] = true;
      });
    }

    var shown = 0;
    current.tables.forEach(function (t) {
      var k = keyOf(t);
      var isSelected = state.selected === k;
      var isRelated = !!(related && related[k] && !isSelected);
      var inScope = scope[k];
      if (visible[k]) shown++;
      var show = visible[k] && (!state.selected || isSelected || isRelated);
      t.el.classList.toggle("hidden", !visible[k]);
      t.el.classList.toggle("selected", isSelected);
      t.el.classList.toggle("related", isRelated);
      t.el.classList.toggle("match", !!q && visible[k]);
      t.el.classList.toggle("muted", visible[k] && !show);
    });

    current.links.forEach(function (l) {
      if (!l.el) return;
      var both = visible[l.from] && visible[l.to];
      var hot = state.selected && (l.from === state.selected || l.to === state.selected);
      l.el.style.display = both ? "" : "none";
      l.el.classList.toggle("hot", !!hot && both);
      l.el.classList.toggle("cold", both && !hot && !!state.selected);
    });

    var empty = document.getElementById("xp-empty");
    if (empty) {
      empty.hidden = shown > 0;
      if (shown === 0) {
        var inScopeCount = 0;
        current.tables.forEach(function (t) { if (scope[keyOf(t)]) inScopeCount++; });
        empty.textContent = inScopeCount === 0
          ? "No tables in " + current.name + " belong to the " +
            (domainById(state.domain) || {}).label + " domain. Choose All domains."
          : "No table or column matches \u201c" + state.query + "\u201d in " + current.name +
            " (" + inScopeCount + " table(s) in scope).";
      }
    }

    if (hintEl) {
      var dom = state.domain ? domainById(state.domain) : null;
      hintEl.textContent = current.tables.length + " tables \u00b7 " + current.links.length +
        " foreign keys \u00b7 " + (dom ? dom.label + " domain" : "all domains") + " \u00b7 " + current.name +
        (q ? " \u00b7 filtering \u201c" + state.query + "\u201d" : "");
    }

    if (!skipDetail) {
      renderDetail(state.selected ? byKeyLookup(state.selected) : null);
    }
  }

  function select(key) {
    state.selected = key;
    applyFilter();
  }

  function renderDetail(t) {
    if (!detailEl) return;
    if (!t) {
      detailEl.innerHTML = '<h4>Select a table</h4>' +
        '<div class="sub">Click a table to see its columns, keys and foreign keys. ' +
        'Related tables stay lit; the rest dim.</div>' +
        '<dl><dt>This diagram</dt><dd>' + current.tables.length + ' tables, ' +
        current.schemas.length + ' schemas, ' + current.links.length + ' foreign keys.</dd>' +
        '<dt>Tip</dt><dd>Every connector is drawn between the referencing column and the ' +
        'referenced column, so the line lands on the right row.</dd></dl>';
      return;
    }
    var fks = current.links.filter(function (l) { return l.from === keyOf(t); });
    var refs = current.links.filter(function (l) { return l.to === keyOf(t); });
    var html = "<h4>" + t.schema + "." + t.name + "</h4>" +
      '<div class="sub">' + (t.rows !== null ? t.rows.toLocaleString() + " rows · " : "") +
      t.columns.length + " columns" + (t.indexes && t.indexes.length ? " · " + t.indexes.length + " indexes" : "") +
      "</div><dl>";

    html += '<dt>Columns</dt><dd class="cols">';
    t.columns.forEach(function (c) {
      html += "<span>" + c.name + (c.pk ? " PK" : c.fk ? " FK" : "") + "</span>";
    });
    html += "</dd>";

    if (fks.length) {
      html += "<dt>References</dt><dd>" + fks.map(function (l) {
        return '<span class="mono">' + (l.name || "FK") + "</span><br>" +
          l.fromCols.join(", ") + " \u2192 " + l.to + "(" + (l.toCols || []).join(", ") + ")" +
          ' <span class="pill">' + (l.optional ? "optional" : "mandatory") + "</span>";
      }).join("<br>") + "</dd>";
    }
    if (refs.length) {
      html += "<dt>Referenced by</dt><dd>" + refs.map(function (l) {
        return l.from + " (" + l.fromCols.join(", ") + ")" +
          ' <span class="mono" style="color:var(--dim)">' + (l.name || "FK") + "</span>";
      }).join("<br>") + "</dd>";
    }
    if (t.indexes && t.indexes.length) {
      html += "<dt>Indexes</dt><dd>" + t.indexes.map(function (i) {
        return i.name + (i.unique ? " (unique)" : "");
      }).join("<br>") + "</dd>";
    }
    html += "</dl>";
    detailEl.innerHTML = html;
  }

  /* ---------- interaction ---------- */
  var dragging = false, moved = false, startX = 0, startY = 0, originX = 0, originY = 0;

  wrapEl.addEventListener("pointerdown", function (e) {
    if (e.target.closest(".table-card")) return;
    dragging = true;
    moved = false;
    startX = e.clientX;
    startY = e.clientY;
    originX = state.tx;
    originY = state.ty;
    wrapEl.classList.add("dragging");
    wrapEl.setPointerCapture(e.pointerId);
  });
  wrapEl.addEventListener("pointermove", function (e) {
    if (!dragging) return;
    var dx = e.clientX - startX, dy = e.clientY - startY;
    if (Math.abs(dx) + Math.abs(dy) > 3) moved = true;
    state.tx = originX + dx;
    state.ty = originY + dy;
    applyTransform();
  });
  wrapEl.addEventListener("pointerup", function (e) {
    dragging = false;
    wrapEl.classList.remove("dragging");
    try { wrapEl.releasePointerCapture(e.pointerId); } catch (err) {}
    if (!moved) select(null);
  });
  wrapEl.addEventListener("wheel", function (e) {
    e.preventDefault();
    var rect = wrapEl.getBoundingClientRect();
    zoomAt(e.deltaY < 0 ? 1.12 : 0.89, e.clientX - rect.left, e.clientY - rect.top);
  }, { passive: false });
  wrapEl.addEventListener("dblclick", function (e) {
    var rect = wrapEl.getBoundingClientRect();
    zoomAt(1.45, e.clientX - rect.left, e.clientY - rect.top);
  });

  if (searchEl) {
    searchEl.addEventListener("input", function () { state.query = searchEl.value; applyFilter(); });
  }
  var bind = function (id, fn) { var el = document.getElementById(id); if (el) el.addEventListener("click", fn); };
  bind("xp-zoom-in", function () { zoomAt(1.2); });
  bind("xp-zoom-out", function () { zoomAt(0.83); });
  bind("xp-fit", fitView);
  bind("xp-reset", function () { select(null); resetView(true); readableView(); });
  bind("xp-full", function () {
    if (document.fullscreenElement) document.exitFullscreen();
    else if (root.requestFullscreen) root.requestFullscreen();
  });

  document.addEventListener("keydown", function (e) {
    if (["INPUT", "TEXTAREA"].indexOf(document.activeElement.tagName) !== -1) return;
    if (e.key === "+" || e.key === "=") zoomAt(1.2);
    else if (e.key === "-") zoomAt(0.83);
    else if (e.key === "0") { select(null); resetView(true); readableView(); }
    else if (e.key === "f") fitView();
    else if (e.key === "Escape") select(null);
  });

  document.addEventListener("fullscreenchange", function () {
    var btn = document.getElementById("xp-full");
    if (btn) btn.setAttribute("aria-pressed", String(!!document.fullscreenElement));
    setTimeout(fitView, 60);
  });

  var resizeTimer;
  window.addEventListener("resize", function () {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(function () { readableView(); }, 140);
  });

  build();
  // expose a tiny harness for the acceptance tests
  window.__afsExplorer = {
    state: state,
    get layout() { return layout; },
    routeCount: function () { return routes.length; },
    setDatabase: function (name) { state.db = name; state.selected = null; state.domain = null; state.query = ""; build(); },
    setDomain: function (id) { state.domain = id; applyLayout(); },
    select: function (key) { select(key); }
  };
})();
