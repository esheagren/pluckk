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

  let lastHeight = 0;
  function reportHeight() {
    const h = Math.ceil(document.body.getBoundingClientRect().height);
    if (h !== lastHeight) { lastHeight = h; toHost({ type: 'resize', height: h }); }
  }

  window.Pluckk = {
    on(type, fn) { handlers[type] = fn; },
    ready() {
      new ResizeObserver(reportHeight).observe(document.body);
      reportHeight();
      toHost({ type: 'ready', height: lastHeight });
    },
    respond(data, score, summary) {
      toHost({ type: 'response', data, score: Math.max(0, Math.min(1, Number(score) || 0)), summary: summary || null });
    },
    speak(text, lang) {
      if (capabilities.speak) { toHost({ type: 'speak', text, lang }); return; }
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
