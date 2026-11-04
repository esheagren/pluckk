// A step-through player for simulation modules (k-means, sorting, gradient descent…).
// A simulation precomputes its steps; the player gives Back / Next / Play / Restart, a caption
// and "Step n of N", and calls render(step, t) with t easing 0→1 as a step animates in.
//
//   PluckkStepper.mount(document.getElementById('controls'), {
//     steps: [{ caption: 'Pick 3 starting centroids', ...anything }],
//     render(step, t, index) { ...draw... },
//     duration: 450,            // ms per transition
//   });
(function () {
  const css = `
    .ps-bar { display: flex; align-items: center; gap: 6px; justify-content: center; padding-top: 8px; }
    .ps-bar button { font: 12px -apple-system, system-ui, sans-serif; color: var(--text, #333); background: transparent;
      border: 1px solid var(--rule, #ddd); border-radius: 999px; padding: 4px 12px; cursor: pointer; }
    .ps-bar button:hover:not(:disabled) { border-color: var(--accent, #c9a66b); }
    .ps-bar button:disabled { opacity: 0.35; cursor: default; }
    .ps-count { font: 11px -apple-system, system-ui, sans-serif; color: var(--muted, #999); min-width: 78px; text-align: center; }
    .ps-caption { font: 14px/1.45 -apple-system, system-ui, sans-serif; color: var(--text, #333); text-align: center;
      min-height: 42px; padding: 8px 12px 0; }`;
  const ease = (t) => 1 - Math.pow(1 - t, 3);

  function mount(root, { steps, render, duration = 450, autoplay = false, interval = 1400 }) {
    const style = document.createElement('style'); style.textContent = css; document.head.appendChild(style);
    root.innerHTML = `<div class="ps-caption"></div><div class="ps-bar">
      <button data-a="restart" title="Back to the start">⟲</button>
      <button data-a="back">◀ Back</button><span class="ps-count"></span>
      <button data-a="next">Next ▶</button><button data-a="play">Play</button></div>`;
    const caption = root.querySelector('.ps-caption'), count = root.querySelector('.ps-count');
    const btn = (a) => root.querySelector(`[data-a="${a}"]`);
    let i = 0, timer = null, frame = null;

    function show(to, animate) {
      i = Math.max(0, Math.min(steps.length - 1, to));
      caption.textContent = steps[i].caption || '';
      count.textContent = `Step ${i + 1} of ${steps.length}`;
      btn('back').disabled = btn('restart').disabled = i === 0;
      btn('next').disabled = i === steps.length - 1;
      cancelAnimationFrame(frame);
      if (!animate) { render(steps[i], 1, i); return; }
      const start = performance.now();
      const tick = (now) => {
        const t = Math.min(1, (now - start) / duration);
        render(steps[i], ease(t), i);
        if (t < 1) frame = requestAnimationFrame(tick);
      };
      frame = requestAnimationFrame(tick);
    }
    function stop() { clearInterval(timer); timer = null; btn('play').textContent = 'Play'; }
    function play() {
      if (i === steps.length - 1) show(0, false);
      btn('play').textContent = 'Pause';
      timer = setInterval(() => { if (i >= steps.length - 1) stop(); else show(i + 1, true); }, interval);
    }
    root.addEventListener('click', (e) => {
      const a = e.target.closest('button')?.dataset.a;
      if (!a) return;
      if (a !== 'play') stop();
      if (a === 'next') show(i + 1, true);
      if (a === 'back') show(i - 1, false);
      if (a === 'restart') show(0, false);
      if (a === 'play') timer ? stop() : play();
    });
    show(0, false);
    if (autoplay) play();
    return { redraw: () => render(steps[i], 1, i) };
  }

  window.PluckkStepper = { mount };
})();
