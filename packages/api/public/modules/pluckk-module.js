// The Pluckk module runtime: everything a card module needs from its host, and nothing else.
// A module is a page under /modules/<id>/<major>/index.html. It includes this file, then:
//
//   Pluckk.on('init', ({ slot, props, theme, revealed }) => { ...draw... ; Pluckk.ready(); });
//   Pluckk.on('reveal', () => { ...show the right answer... });
//   Pluckk.respond(data, score, summary);   // respond slot only; score 0–1
//   Pluckk.speak(text, lang);                // uses the host's voices when it has them
//
// The host is the Mac app (WKWebView, messages through webkit.messageHandlers.pluckk) or a web
// page (sandboxed iframe, messages through postMessage). See docs/roadmap/planned/card-modules/plan.md.
(function () {
  // A module never scrolls: the host sizes it to its content. A scroll bar appearing would
  // narrow the page, change its height and loop with the host's resizing.
  const noScroll = document.createElement('style');
  noScroll.textContent = 'html, body { overflow: hidden !important; }';
  document.head.appendChild(noScroll);
  const handlers = {};
  let capabilities = {};
  const toHost = (msg) => {
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.pluckk) {
      window.webkit.messageHandlers.pluckk.postMessage(msg);
    } else if (window.parent !== window) {
      window.parent.postMessage({ pluckk: msg }, '*');
    }
  };
  window.addEventListener('message', (e) => {
    const msg = e.data && e.data.pluckk;
    if (!msg || typeof msg.type !== 'string') return;
    if (msg.type === 'init') {
      capabilities = msg.capabilities || {};
      applyTheme(msg.theme || {});
    }
    if (msg.type === 'theme') applyTheme(msg.theme || {});
    const fn = handlers[msg.type];
    if (fn) fn(msg);
  });

  function applyTheme(theme) {
    const root = document.documentElement.style;
    for (const [k, v] of Object.entries(theme)) {
      if (typeof v === 'string') root.setProperty(`--${k}`, v);
    }
    document.documentElement.dataset.theme = theme.dark ? 'dark' : 'light';
  }

  let lastHeight = 0, pending = false;
  function reportHeight() {
    if (pending) return;
    pending = true;
    requestAnimationFrame(() => {   // at most once a frame, and only real changes
      pending = false;
      const h = Math.ceil(document.body.getBoundingClientRect().height);
      if (Math.abs(h - lastHeight) > 1) { lastHeight = h; toHost({ type: 'resize', height: h }); }
    });
  }

  window.Pluckk = {
    on(type, fn) { handlers[type] = fn; },
    ready() {
      lastHeight = Math.ceil(document.body.getBoundingClientRect().height);
      toHost({ type: 'ready', height: lastHeight });
      new ResizeObserver(reportHeight).observe(document.body);
    },
    respond(data, score, summary) {
      toHost({ type: 'response', data, score: Math.max(0, Math.min(1, Number(score) || 0)), summary: summary || null });
    },
    /** Play an audio file (a recorded pronunciation), through the host when it can. */
    // opts.auto: played on its own when shown (the host plays the same sound on its own only once).
    play(src, opts) {
      if (capabilities.play) { toHost({ type: 'play', src, auto: !!(opts && opts.auto) }); return; }
      try { new Audio(src).play(); } catch (e) {}
    },
    speak(text, lang, opts) {
      if (capabilities.speak) { toHost({ type: 'speak', text, lang, auto: !!(opts && opts.auto) }); return; }
      if (!('speechSynthesis' in window)) return;
      const u = new SpeechSynthesisUtterance(text);
      u.lang = lang || 'en-US';
      speechSynthesis.cancel();
      speechSynthesis.speak(u);
    },
    /** Read a CSS colour token set by the host's theme, with a fallback. */
    color(name, fallback) {
      const v = getComputedStyle(document.documentElement).getPropertyValue(`--${name}`).trim();
      return v || fallback;
    },
  };
})();
