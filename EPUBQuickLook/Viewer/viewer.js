// EPUB Quick Look reader.
//
// One <div class="slot"> per spine document, in a single continuous scroll.
// Slots near the viewport get a sandboxed, same-origin <iframe> showing the
// ORIGINAL chapter file (its own CSS, relative paths and XHTML parsing intact);
// slots far away are unloaded again, keeping their measured height. Unloaded
// slots are sized from the chapter's byte count, using a px/byte ratio learned
// from chapters already laid out, so the scrollbar and progress stay honest.
'use strict';

(async () => {
  const BAR = 40;
  const NEAR = 2500;          // px: load chapters this close to the viewport
  const FAR = 12000;          // px: unload chapters farther than this
  const NS = { xhtml: 'http://www.w3.org/1999/xhtml', svg: 'http://www.w3.org/2000/svg',
               xlink: 'http://www.w3.org/1999/xlink' };
  const WIDTHS = ['920px', '1240px', '100%'];
  const THEMES = ['light', 'sepia', 'dark'];

  const $ = (id) => document.getElementById(id);
  const post = (msg) => { try { window.webkit.messageHandlers.reader.postMessage(msg); } catch (_) { /* not in the app */ } };
  const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
  const debounce = (fn, ms) => { let t; return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); }; };

  // ---------------------------------------------------------------- data
  let D;
  try {
    D = await (await fetch('book.json', { cache: 'no-store' })).json();
  } catch (e) {
    D = { error: 'Could not load the book.', title: '' };
  }
  document.title = D.title || 'EPUB';
  if (D.language) document.documentElement.lang = D.language;
  if (D.error) {
    const msg = $('msg');
    msg.hidden = false;
    msg.innerHTML = '<div><h2></h2><p></p></div>';
    msg.querySelector('h2').textContent = D.title || 'EPUB';
    msg.querySelector('p').textContent = D.error;
    $('bar').hidden = true;
    return;
  }

  const prefs = {
    font: clamp(parseInt(D.prefs.font, 10) || 100, 50, 250),
    theme: THEMES.includes(D.prefs.theme) ? D.prefs.theme : 'light',
    wide: clamp(parseInt(D.prefs.wide, 10) || 0, 0, WIDTHS.length - 1),
  };
  const savePrefs = () => post({ type: 'prefs', prefs: { font: String(prefs.font), theme: prefs.theme, wide: String(prefs.wide) } });

  const ROOT = new URL('/', location.href);
  const main = $('main');
  const slots = D.spine.map((s, i) => ({
    i, href: new URL(s.href, ROOT).href, bytes: s.bytes, fixed: s.fixed,
    el: null, frame: null, ready: null, h: 0, measured: false, html: false, vertical: false,
    page: null,   // fixed layout: {w, h}
  }));
  const byURL = new Map(slots.map((s) => [s.href, s.i]));
  const slotOf = new WeakMap();   // observed documentElement → slot

  // ---------------------------------------------------------------- sizing
  let pxPerByte = 0.35;            // refined from real measurements
  const samples = [];
  const contentWidth = () => Math.min(main.clientWidth, slots.length ? slots[0].el.clientWidth || main.clientWidth : main.clientWidth);

  function estimate(s) {
    if (s.fixed) {
      const aspect = fixedAspect || 1.414;
      return fixedScale(1, aspect).h;
    }
    return clamp(Math.round(s.bytes * pxPerByte), 160, 80000);
  }

  function setHeight(s, h) {
    h = Math.max(24, Math.ceil(h));
    if (Math.abs(h - s.h) < 1) return;
    const bottom = s.el.getBoundingClientRect().bottom;
    const delta = h - s.h;
    s.h = h;
    s.el.style.height = h + 'px';
    // Hold the reading position when something above it changes size.
    if (bottom <= BAR + 1) window.scrollBy(0, delta);
  }

  function learn(s) {
    if (s.fixed || s.bytes < 4096) return;
    samples.push(s.h / s.bytes);
    if (samples.length > 40) samples.shift();
    const sorted = [...samples].sort((a, b) => a - b);
    const next = sorted[sorted.length >> 1];
    if (Math.abs(next - pxPerByte) / pxPerByte > 0.1) { pxPerByte = next; reestimate(); }
  }

  // Re-size never-measured slots below the viewport (above would shift the view).
  const reestimate = debounce(() => {
    const limit = scrollY + innerHeight;
    for (const s of slots) {
      if (s.measured || s.el.offsetTop < limit) continue;
      const h = estimate(s);
      s.h = h;
      s.el.style.height = h + 'px';
    }
    track();
  }, 250);

  const verticalHeight = () => Math.max(320, innerHeight - BAR - 16);

  // ---------------------------------------------------------------- fixed layout
  let fixedAspect = 0;
  function fixedScale(w, aspect) {
    const availW = contentWidth() - 16;
    const availH = innerHeight - BAR - 24;
    const pageH = w * aspect;
    const k = Math.min(availW / w, availH / pageH);
    return { k, h: pageH * k + 16, left: (contentWidth() - w * k) / 2 };
  }

  function pageSize(doc) {
    const meta = doc.querySelector('meta[name="viewport" i]');
    if (meta) {
      const m = {};
      for (const part of (meta.getAttribute('content') || '').split(/[,;]/)) {
        const [k, v] = part.split('=').map((x) => x && x.trim().toLowerCase());
        if (k && v) m[k] = parseFloat(v);
      }
      if (m.width > 0 && m.height > 0) return { w: m.width, h: m.height };
    }
    const root = doc.documentElement;
    if (root.localName === 'svg') {
      const vb = root.viewBox && root.viewBox.baseVal;
      if (vb && vb.width > 0) return { w: vb.width, h: vb.height };
    }
    const svg = doc.querySelector('svg');
    if (svg && svg.viewBox && svg.viewBox.baseVal && svg.viewBox.baseVal.width > 0) {
      return { w: svg.viewBox.baseVal.width, h: svg.viewBox.baseVal.height };
    }
    const imgs = doc.images;
    if (imgs.length === 1 && imgs[0].naturalWidth > 0) return { w: imgs[0].naturalWidth, h: imgs[0].naturalHeight };
    return null;
  }

  function layoutFixed(s) {
    if (!s.frame || !s.page) return;
    const { w, h } = s.page;
    const f = fixedScale(w, h / w);
    s.frame.style.width = w + 'px';
    s.frame.style.height = h + 'px';
    s.frame.style.left = f.left + 'px';
    s.frame.style.transform = `scale(${f.k})`;
    setHeight(s, f.h);
  }

  // ---------------------------------------------------------------- chapter styling
  function chapterCSS(s) {
    let css = '';
    if (s.vertical) {
      // Vertical text (CJK): column length must follow a fixed frame height, or
      // auto-height feeds back into column length. The frame scrolls sideways.
      css += `
        html { height: 100% !important; overflow: auto hidden !important; padding: 28px 32px !important;
               box-sizing: border-box !important; }
        img, svg, video { max-height: 100% !important; }`;
      if (prefs.font !== 100) css += `html { font-size: ${prefs.font}% !important; }`;
    } else if (!s.fixed) {
      css += `
        html { height: auto !important; min-height: 0 !important; max-height: none !important;
               overflow: hidden !important; padding: 28px 44px !important; box-sizing: border-box !important;
               column-count: auto !important; columns: auto !important; }
        body { height: auto !important; min-height: 0 !important; overflow: visible !important; }
        img, svg, video, canvas, object, embed, iframe { max-width: 100% !important; }
        img, video { object-fit: contain; }
        pre { white-space: pre-wrap; overflow-wrap: anywhere; }
        .__ql_scroll { overflow-x: auto; max-width: 100%; }`;
      if (prefs.font !== 100) css += `html { font-size: ${prefs.font}% !important; }`;
    }
    if (prefs.theme === 'sepia') {
      css += 'html, body { background-color: #f6efdc !important; }';
    } else if (prefs.theme === 'dark') {
      css += `html { filter: invert(.9) hue-rotate(180deg); background-color: #fff !important; }
              img, image, video, picture, canvas, object, embed { filter: invert(1) hue-rotate(180deg); }
              img, video { background-color: #fff; }`;
    }
    return css;
  }

  function styleDoc(s, doc) {
    let el = doc.getElementById('__ql_style');
    if (!el) {
      const root = doc.documentElement;
      el = root.localName === 'svg' ? doc.createElementNS(NS.svg, 'style') : doc.createElementNS(NS.xhtml, 'style');
      el.id = '__ql_style';
      (doc.head || root).appendChild(el);
    }
    el.textContent = chapterCSS(s);
  }

  // Wide tables would be clipped (the frame can't scroll); give them their own scroller.
  function wrapWideTables(doc) {
    const root = doc.documentElement;
    if (root.scrollWidth <= root.clientWidth + 1) return;
    for (const t of doc.querySelectorAll('table')) {
      if (t.parentElement && t.parentElement.classList.contains('__ql_scroll')) continue;
      if (t.getBoundingClientRect().right <= root.clientWidth + 1) continue;
      const wrap = doc.createElementNS(NS.xhtml, 'div');
      wrap.className = '__ql_scroll';
      t.replaceWith(wrap);
      wrap.appendChild(t);
    }
  }

  // ---------------------------------------------------------------- loading
  const ro = new ResizeObserver((entries) => {
    for (const e of entries) {
      const s = slotOf.get(e.target);
      if (s && s.frame && !s.fixed && !s.vertical) measure(s);
    }
  });

  function measure(s) {
    const doc = s.frame && s.frame.contentDocument;
    if (!doc || !doc.documentElement) return;
    setHeight(s, doc.documentElement.getBoundingClientRect().height);
    if (!s.measured) { s.measured = true; learn(s); }
  }

  function load(s) {
    if (s.ready) return s.ready;
    const f = document.createElement('iframe');
    // Same-origin so we can measure/style; no allow-scripts: book JavaScript never runs.
    f.setAttribute('sandbox', 'allow-same-origin');
    f.setAttribute('scrolling', 'no');
    f.title = `Section ${s.i + 1}`;
    s.frame = f;
    s.ready = new Promise((resolve) => {
      f.addEventListener('load', () => setup(s).then(resolve), { once: true });
    });
    f.src = s.href;
    s.el.appendChild(f);
    return s.ready;
  }

  function unload(s) {
    if (!s.frame) return;
    const doc = s.frame.contentDocument;
    if (doc && doc.documentElement) ro.unobserve(doc.documentElement);
    s.frame.remove();
    s.frame = null;
    s.ready = null;
  }

  async function reloadAsHTML(s) {
    // XHTML that fails strict XML parsing: retry with the forgiving HTML parser.
    let text = '';
    try { text = await (await fetch(s.href)).text(); } catch (_) { return; }
    text = text.replace(/^\uFEFF?\s*<\?xml[^>]*>/, '');
    const base = `<base href="${s.href.replace(/"/g, '&quot;')}">`;
    text = /<head[^>]*>/i.test(text) ? text.replace(/<head[^>]*>/i, (m) => m + base) : base + text;
    s.html = true;
    await new Promise((resolve) => {
      s.frame.addEventListener('load', resolve, { once: true });
      s.frame.removeAttribute('src');
      s.frame.srcdoc = text;
    });
  }

  async function setup(s) {
    if (!s.frame) return;
    let doc = s.frame.contentDocument;
    if (!doc || !doc.documentElement) return;
    if (!s.html && doc.getElementsByTagName('parsererror').length) {
      await reloadAsHTML(s);
      if (!s.frame) return;
      doc = s.frame.contentDocument;
      if (!doc || !doc.documentElement) return;
    }
    styleDoc(s, doc);
    doc.addEventListener('click', (e) => onClick(e, s, doc), true);
    doc.addEventListener('keydown', onKey);

    if (s.fixed) {
      s.page = pageSize(doc);
      if (!s.page) {
        s.fixed = false;   // no usable page size: render as reflowable
        s.el.classList.remove('fixed');
        styleDoc(s, doc);
      } else {
        if (!fixedAspect) fixedAspect = s.page.h / s.page.w;
        layoutFixed(s);
        s.measured = true;
        return;
      }
    }
    const view = s.frame.contentWindow;
    const wm = view.getComputedStyle(doc.body || doc.documentElement).writingMode || '';
    if (/^(vertical|sideways|tb)/.test(wm)) {
      s.vertical = true;
      s.frame.removeAttribute('scrolling');
      s.el.classList.add('vertical');
      styleDoc(s, doc);
      setHeight(s, verticalHeight());
      s.measured = true;
      // Turn vertical wheel motion into sideways paging through the columns,
      // then hand over to the page scroll at either end.
      doc.addEventListener('wheel', (e) => {
        if (Math.abs(e.deltaX) > Math.abs(e.deltaY)) return;
        const root = doc.scrollingElement || doc.documentElement;
        const max = root.scrollWidth - root.clientWidth;
        if (max <= 0) return;
        const rtl = !/lr$/.test(wm);
        const pos = rtl ? -root.scrollLeft : root.scrollLeft;   // 0 … max in reading order
        const next = clamp(pos + e.deltaY, 0, max);
        if (next === pos) return;
        e.preventDefault();
        root.scrollLeft = rtl ? -next : next;
      }, { passive: false });
      return;
    }
    wrapWideTables(doc);
    slotOf.set(doc.documentElement, s);
    ro.observe(doc.documentElement);
    measure(s);
  }

  // ---------------------------------------------------------------- build slots
  const frag = document.createDocumentFragment();
  for (const s of slots) {
    s.el = document.createElement('div');
    s.el.className = s.fixed ? 'slot fixed' : 'slot';
    s.el.dataset.i = s.i;
    frag.appendChild(s.el);
  }
  main.appendChild(frag);
  document.documentElement.style.setProperty('--pagew', WIDTHS[prefs.wide]);
  applyTheme();
  for (const s of slots) { s.h = estimate(s); s.el.style.height = s.h + 'px'; }

  const near = new IntersectionObserver((es) => {
    for (const e of es) if (e.isIntersecting) load(slots[+e.target.dataset.i]);
  }, { rootMargin: `${NEAR}px 0px` });
  const far = new IntersectionObserver((es) => {
    for (const e of es) if (!e.isIntersecting) unload(slots[+e.target.dataset.i]);
  }, { rootMargin: `${FAR}px 0px` });
  for (const s of slots) { near.observe(s.el); far.observe(s.el); }

  // ---------------------------------------------------------------- navigation
  let anchor = null;       // pending {s, frag, frac}; cleared when the user scrolls
  const docTop = (el) => el.getBoundingClientRect().top + window.scrollY;

  function targetY(s, fragId, frac) {
    let y = docTop(s.el);
    if (fragId && s.frame && s.frame.contentDocument) {
      const doc = s.frame.contentDocument;
      const el = doc.getElementById(fragId) || doc.getElementsByName(fragId)[0];
      if (el) {
        const k = s.fixed && s.page ? fixedScale(s.page.w, s.page.h / s.page.w).k : 1;
        return y + el.getBoundingClientRect().top * k - BAR - 8;
      }
    }
    return y + frac * s.h - BAR;
  }

  async function goTo(i, fragId = '', frac = 0) {
    const s = slots[clamp(i, 0, slots.length - 1)];
    const a = anchor = { s, fragId, frac };
    window.scrollTo(0, targetY(s, fragId, frac));
    await load(s);
    if (anchor !== a) return;
    window.scrollTo(0, targetY(s, fragId, frac));
    // Neighbours above are still loading and resizing; re-anchor as they settle.
    for (const ms of [150, 400, 900]) {
      setTimeout(() => { if (anchor === a) window.scrollTo(0, targetY(s, fragId, frac)); }, ms);
    }
    setTimeout(() => { if (anchor === a) anchor = null; }, 950);
  }
  const cancelAnchor = () => { anchor = null; };
  addEventListener('wheel', cancelAnchor, { passive: true });
  addEventListener('keydown', cancelAnchor);
  addEventListener('mousedown', cancelAnchor);

  function linkOf(node) {
    for (let n = node; n && n.nodeType === 1; n = n.parentNode) {
      if (n.localName === 'a' || n.localName === 'area') {
        const href = n.getAttribute('href') || n.getAttributeNS(NS.xlink, 'href');
        if (href) return href;
      }
    }
    return null;
  }

  function onClick(e, s, doc) {
    if (e.button !== 0 || e.metaKey || e.ctrlKey) return;
    const raw = linkOf(e.target);
    if (!raw) return;
    e.preventDefault();
    e.stopPropagation();
    let u;
    try { u = new URL(raw, s.html ? s.href : doc.baseURI); } catch (_) { return; }
    if (u.protocol === 'http:' || u.protocol === 'https:' || u.protocol === 'mailto:') {
      post({ type: 'open', url: u.href });
      return;
    }
    const hash = decodeURIComponent(u.hash.slice(1));
    u.hash = '';
    const i = byURL.get(u.href);
    if (i !== undefined) goTo(i, hash);
  }

  // ---------------------------------------------------------------- TOC
  const side = $('side');
  const tocLinks = [];
  if (!D.toc.length) {
    side.innerHTML = '<div class="empty">This book has no table of contents.</div>';
  } else {
    const tf = document.createDocumentFragment();
    D.toc.forEach((t, n) => {
      const a = document.createElement('a');
      a.href = '#';
      a.textContent = t.title;
      a.className = 'd' + Math.min(t.depth, 6);
      a.style.paddingLeft = (14 + Math.min(t.depth, 6) * 16) + 'px';
      a.addEventListener('click', (e) => { e.preventDefault(); goTo(t.idx, t.frag); if (innerWidth < 700) toggleTOC(false); });
      tf.appendChild(a);
      tocLinks.push({ t, a, n });
    });
    side.appendChild(tf);
  }
  // lastTOC[i] = the last TOC entry (in reading order) that starts at or before spine item i.
  const lastTOC = new Array(slots.length).fill(null);
  {
    const ordered = [...tocLinks].sort((x, y) => x.t.idx - y.t.idx || x.n - y.n);
    let k = 0, cur = null;
    for (let i = 0; i < slots.length; i++) {
      while (k < ordered.length && ordered[k].t.idx <= i) cur = ordered[k++];
      lastTOC[i] = cur;
    }
  }
  const tocAt = new Map();
  for (const l of tocLinks) {
    if (!tocAt.has(l.t.idx)) tocAt.set(l.t.idx, []);
    tocAt.get(l.t.idx).push(l);
  }

  // Scroll only the sidebar (scrollIntoView would also scroll the page in WebKit).
  function revealInSide(link, center) {
    const top = link.offsetTop, h = link.offsetHeight, view = side.clientHeight;
    if (center) side.scrollTop = top - (view - h) / 2;
    else if (top < side.scrollTop) side.scrollTop = top;
    else if (top + h > side.scrollTop + view) side.scrollTop = top + h - view;
  }

  // ---------------------------------------------------------------- position tracking
  const where = $('where'), pct = $('pct'), progress = $('progress');
  let curLink, curIndex = -1;   // curLink starts undefined so the first track() renders the title

  function currentIndex() {
    const y = window.scrollY + BAR + 1;
    let lo = 0, hi = slots.length - 1;
    while (lo < hi) {             // binary search: O(log n) per frame
      const mid = (lo + hi + 1) >> 1;
      if (slots[mid].el.offsetTop <= y) lo = mid; else hi = mid - 1;
    }
    return lo;
  }

  function track() {
    if (!slots.length) return;
    const cur = currentIndex();
    curIndex = cur;
    // Start from the last entry of earlier chapters, then walk this chapter's
    // entries in order: the first one (or one without an anchor) starts at the
    // top; anchored ones count once their anchor has scrolled under the toolbar.
    let best = cur > 0 ? lastTOC[cur - 1] : null;
    const s = slots[cur];
    const inside = tocAt.get(cur);
    if (inside) {
      const doc = s.frame && !s.fixed ? s.frame.contentDocument : null;
      const top = s.el.getBoundingClientRect().top;
      inside.slice(0, 64).forEach((l, k) => {
        if (k === 0 || !l.t.frag || !doc) { if (k === 0 || !l.t.frag) best = l; return; }
        const el = doc.getElementById(l.t.frag);
        if (el && top + el.getBoundingClientRect().top <= BAR + 80) best = l;
      });
    }
    const link = best ? best.a : null;
    if (link !== curLink) {
      if (curLink) curLink.classList.remove('cur');
      curLink = link;
      where.textContent = '';
      const b = document.createElement('b');
      b.textContent = D.title || '';
      where.appendChild(b);
      if (best) where.appendChild(document.createTextNode((D.title ? '  ·  ' : '') + best.t.title));
      if (link) {
        link.classList.add('cur');
        if (document.body.classList.contains('toc')) revealInSide(link, false);
      }
    }
    const max = document.documentElement.scrollHeight - innerHeight;
    const p = max > 0 ? clamp(window.scrollY / max, 0, 1) : 1;
    pct.textContent = `${cur + 1}/${slots.length} · ${Math.round(p * 100)}%`;
    progress.style.width = (p * 100).toFixed(2) + '%';
  }

  const savePosition = debounce(() => {
    const s = slots[curIndex];
    if (!s) return;
    const frac = s.h > 0 ? clamp((window.scrollY + BAR - docTop(s.el)) / s.h, 0, 1) : 0;
    post({ type: 'position', i: s.i, frac });
  }, 700);

  let ticking = false;
  addEventListener('scroll', () => {
    if (ticking) return;
    ticking = true;
    requestAnimationFrame(() => { ticking = false; track(); savePosition(); });
  }, { passive: true });

  // ---------------------------------------------------------------- controls
  function restyleAll() {
    for (const s of slots) {
      const doc = s.frame && s.frame.contentDocument;
      if (doc && doc.getElementById('__ql_style')) styleDoc(s, doc);
    }
  }

  // Keep the text under the toolbar in place while everything reflows.
  function anchored(fn) {
    const s = slots[currentIndex()];
    const frac = s && s.h ? (window.scrollY + BAR - docTop(s.el)) / s.h : 0;
    fn();
    if (s) requestAnimationFrame(() => requestAnimationFrame(() => window.scrollTo(0, docTop(s.el) + frac * s.h - BAR)));
  }

  function applyTheme() {
    document.body.classList.remove('sepia', 'dark');
    if (prefs.theme !== 'light') document.body.classList.add(prefs.theme);
  }

  function toggleTOC(force) {
    const open = document.body.classList.toggle('toc', force);
    $('btoc').setAttribute('aria-expanded', String(open));
    if (open && curLink) revealInSide(curLink, true);
  }
  const font = (d) => anchored(() => {
    prefs.font = clamp(prefs.font + d, 50, 250);
    restyleAll();
    savePrefs();
  });
  const theme = () => {
    prefs.theme = THEMES[(THEMES.indexOf(prefs.theme) + 1) % THEMES.length];
    applyTheme();
    restyleAll();
    savePrefs();
  };
  const wide = () => anchored(() => {
    prefs.wide = (prefs.wide + 1) % WIDTHS.length;
    document.documentElement.style.setProperty('--pagew', WIDTHS[prefs.wide]);
    relayoutFixed();
    savePrefs();
  });
  const step = (d) => goTo(clamp(currentIndex() + d, 0, slots.length - 1));

  function relayoutFixed() {
    for (const s of slots) {
      if (s.vertical) { setHeight(s, verticalHeight()); continue; }
      if (!s.fixed) continue;
      if (s.frame && s.page) layoutFixed(s);
      else if (!s.measured) { s.h = estimate(s); s.el.style.height = s.h + 'px'; }
    }
  }

  $('btoc').addEventListener('click', () => toggleTOC());
  $('bsmall').addEventListener('click', () => font(-10));
  $('bbig').addEventListener('click', () => font(10));
  $('btheme').addEventListener('click', theme);
  $('bwide').addEventListener('click', wide);
  main.addEventListener('click', () => toggleTOC(false));

  function onKey(e) {
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    const handlers = {
      t: () => toggleTOC(), T: () => toggleTOC(),
      '+': () => font(10), '=': () => font(10), '-': () => font(-10),
      d: theme, D: theme, w: wide, W: wide,
      '[': () => step(-1), ']': () => step(1),
      Escape: () => toggleTOC(false),
    };
    const h = handlers[e.key];
    if (!h) return;
    e.preventDefault();
    h();
  }
  addEventListener('keydown', onKey);
  addEventListener('resize', debounce(() => anchored(relayoutFixed), 120));

  // ---------------------------------------------------------------- start
  track();
  if (D.position) goTo(D.position.i, '', D.position.frac);
  else load(slots[0]);

  window.__reader = { goTo, slots };   // debugging hook
})();
