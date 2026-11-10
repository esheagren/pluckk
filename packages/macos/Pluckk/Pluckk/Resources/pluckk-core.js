"use strict";
(() => {
  // src/entities.ts
  var MAIN_COMPONENT = "main";
  function componentIdsOf(spec) {
    switch (spec.style) {
      case "qa_bidirectional":
        return ["forward", "reverse"];
      case "cloze_list":
        return spec.prompts.map((_, i) => `p${i}`);
      default:
        return [MAIN_COMPONENT];
    }
  }
  function renderComponent(spec, id) {
    switch (spec.style) {
      case "qa_bidirectional":
        if (id === "forward") return spec.forward;
        if (id === "reverse") return spec.reverse;
        break;
      case "cloze_list": {
        const m = /^p(\d+)$/.exec(id);
        const p = m ? spec.prompts[Number(m[1])] : void 0;
        if (p) return p;
        break;
      }
      default:
        if (id === MAIN_COMPONENT) return { question: spec.question, answer: spec.answer };
    }
    throw new Error(`Component ${id} does not exist on a ${spec.style} card`);
  }
  function componentStyle(spec) {
    if (spec.style === "qa_bidirectional") return "qa";
    if (spec.style === "cloze_list") return "cloze";
    return spec.style;
  }

  // src/scheduler/constants.ts
  var DEFAULT_CONFIG = {
    initialEase: 2.5,
    minimumEase: 1.3,
    easeBonus: { trivial: 0.25, easy: 0.15, good: 0, hard: -0.15, again: -0.2 },
    intervalMultiplier: { hard: 1.2, easy: 1.3, trivial: 2.6 },
    // Intervals for new/first-time cards (days)
    newCardIntervals: { again: 694e-5, hard: 1, good: 3, easy: 7, trivial: 21 },
    // A card in learning or relearning got Again earlier: however easy the retry minutes later
    // feels, it comes back tomorrow (days). Erik, 2026-11-05.
    graduationIntervals: { again: 694e-5, hard: 1, good: 1, easy: 1, trivial: 1 },
    maxIntervalDays: 365
  };
  var MECHANICS_ORBIT = {
    growFromElapsed: true,
    retryDelayMinutes: 10,
    jitterMaxMinutes: 10,
    dueLookaheadHours: 16
  };
  var DEFAULT_MECHANICS = MECHANICS_ORBIT;
  var RATINGS = { AGAIN: "again", HARD: "hard", GOOD: "good", EASY: "easy", TRIVIAL: "trivial" };
  var STATUS = { NEW: "new", LEARNING: "learning", REVIEW: "review", RELEARNING: "relearning", SUSPENDED: "suspended" };
  var SCHEDULER_ID = "sm2-v2";
  var DAY_MS = 24 * 60 * 60 * 1e3;
  var MINUTE_MS = 60 * 1e3;

  // src/queue.ts
  var key = (f) => f ?? "unfiled";
  function shuffle(arr) {
    for (let i = arr.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      [arr[i], arr[j]] = [arr[j], arr[i]];
    }
    return arr;
  }
  function aheadQuotas(folders, size, supply, limit) {
    const quotas = new Map(folders.map((f) => [f, 0]));
    const weighted = folders.filter((f) => limit(f) > 0 && supply(f) > 0);
    const weight = (f) => weighted.length > 0 ? limit(f) : 1;
    let open = weighted.length > 0 ? weighted : folders.filter((f) => supply(f) > 0);
    let left = size;
    while (left > 0 && open.length > 0) {
      const total = open.reduce((s, f) => s + weight(f), 0);
      const shares = open.map((f) => {
        const exact = left * weight(f) / total;
        const room = supply(f) - quotas.get(f);
        return { f, whole: Math.min(Math.floor(exact), room), fraction: exact - Math.floor(exact), room };
      });
      let given = 0;
      for (const s of shares) {
        quotas.set(s.f, quotas.get(s.f) + s.whole);
        given += s.whole;
      }
      for (const s of [...shares].sort((a, b) => b.fraction - a.fraction || weight(b.f) - weight(a.f))) {
        if (given >= left) break;
        if (quotas.get(s.f) < supply(s.f)) {
          quotas.set(s.f, quotas.get(s.f) + 1);
          given++;
        }
      }
      if (given === 0) break;
      left -= given;
      open = open.filter((f) => quotas.get(f) < supply(f));
    }
    return quotas;
  }
  var isUnseen = (c) => !c.status || c.status === "new";
  function onePerCard(rows) {
    const best = /* @__PURE__ */ new Map();
    for (const r of rows) {
      const cur = best.get(r.cardId);
      if (!cur) {
        best.set(r.cardId, r);
        continue;
      }
      const rd = r.dueAt ?? "", cd = cur.dueAt ?? "";
      if (rd < cd || rd === cd && (r.componentId ?? MAIN_COMPONENT) < (cur.componentId ?? MAIN_COMPONENT)) best.set(r.cardId, r);
    }
    return [...best.values()];
  }
  function selectSession(input) {
    const now = input.now ?? /* @__PURE__ */ new Date();
    const lookaheadMs = (input.dueLookaheadHours ?? DEFAULT_MECHANICS.dueLookaheadHours) * 60 * MINUTE_MS;
    const dueCutoff = now.getTime() + lookaheadMs;
    const order = (arr) => input.noShuffle ? arr : shuffle(arr);
    const paused = new Set(input.folders.filter((f) => f.isPaused).map((f) => f.id));
    const target = input.mode !== "scheduled" ? input.folderId ?? null : void 0;
    const candidates2 = onePerCard(input.candidates.filter((c) => !(c.folderId && paused.has(c.folderId) && c.folderId !== target)));
    const byFolder = /* @__PURE__ */ new Map();
    for (const c of candidates2) {
      let b = byFolder.get(c.folderId);
      if (!b) {
        b = { due: [], fresh: [] };
        byFolder.set(c.folderId, b);
      }
      if (isUnseen(c)) b.fresh.push(c);
      else if (c.dueAt && new Date(c.dueAt).getTime() <= dueCutoff) b.due.push(c);
    }
    for (const b of byFolder.values()) {
      b.due.sort((a, z) => a.dueAt < z.dueAt ? -1 : 1);
      b.fresh.sort((a, z) => a.createdAt < z.createdAt ? -1 : 1);
    }
    const dueTotal = [...byFolder.values()].reduce((s, b) => s + b.due.length, 0);
    const perFolderMeta = {};
    const noteMeta = (f, dealt2) => {
      const b = byFolder.get(f) ?? { due: [], fresh: [] };
      perFolderMeta[key(f)] = { due: b.due.length, new: b.fresh.length, dealt: dealt2 };
    };
    const newBudget = (f) => {
      const info = f ? input.folders.find((x) => x.id === f) : null;
      const cap = info?.newPerDay ?? input.defaultNewPerDay;
      return Math.max(0, cap - (input.newReviewedTodayByFolder.get(f) ?? 0));
    };
    const takeFromFolder = (f, quota) => {
      const b = byFolder.get(f);
      if (!b) return [];
      const take = b.due.slice(0, quota);
      if (take.length < quota) take.push(...b.fresh.slice(0, Math.min(quota - take.length, newBudget(f))));
      b.due = b.due.slice(Math.min(quota, take.length));
      const newTaken = take.filter(isUnseen).length;
      b.fresh = b.fresh.slice(newTaken);
      input.newReviewedTodayByFolder.set(f, (input.newReviewedTodayByFolder.get(f) ?? 0) + newTaken);
      return take;
    };
    const finish = (mode, rows, extra) => {
      const dealt2 = rows.map((c) => ({ cardId: c.cardId, componentId: c.componentId ?? MAIN_COMPONENT }));
      return { dealt: dealt2, dealtIds: dealt2.map((d) => d.cardId), meta: { mode, per_folder: perFolderMeta, due_total: dueTotal, ...extra } };
    };
    if (input.mode === "backlog") {
      const f = input.folderId ?? null;
      const b = byFolder.get(f) ?? { due: [], fresh: [] };
      const dealt2 = b.due.slice(0, input.size);
      noteMeta(f, dealt2.length);
      return finish("backlog", dealt2, { backlog_remaining: b.due.length - dealt2.length });
    }
    if (input.mode === "ahead") {
      const folders = input.folderId !== void 0 ? [input.folderId] : [...byFolder.keys()];
      const quotas = aheadQuotas(folders, input.size, (f) => byFolder.get(f)?.fresh.length ?? 0, (f) => {
        const info = f ? input.folders.find((x) => x.id === f) : null;
        return info?.newPerDay ?? input.defaultNewPerDay;
      });
      const dealt2 = folders.flatMap((f) => (byFolder.get(f)?.fresh ?? []).slice(0, quotas.get(f) ?? 0));
      for (const f of folders) noteMeta(f, quotas.get(f) ?? 0);
      return finish("ahead", order(dealt2));
    }
    if (input.mode === "focus") {
      const f = input.folderId ?? null;
      const dealt2 = takeFromFolder(f, input.size);
      noteMeta(f, dealt2.length);
      return finish("focus", order(dealt2));
    }
    let mix = input.mix ?? [];
    if (mix.length === 0) {
      const weighted = input.folders.filter((f) => !f.isPaused && (f.weight ?? 0) > 0);
      mix = weighted.length > 0 ? weighted.map((f) => ({ folderId: f.id, pct: f.weight })) : [...byFolder.keys()].map((f) => ({ folderId: f, pct: 1 }));
    }
    mix = mix.filter((m) => !(m.folderId && paused.has(m.folderId)) && m.pct > 0);
    const pctTotal = mix.reduce((s, m) => s + m.pct, 0) || 1;
    const dealt = [];
    const dealtPerFolder = /* @__PURE__ */ new Map();
    let remaining = input.size;
    let active = mix.map((m) => m.folderId);
    const weights = new Map(mix.map((m) => [m.folderId, m.pct / pctTotal]));
    for (let pass = 0; pass < 4 && remaining > 0 && active.length > 0; pass++) {
      const wTotal = active.reduce((s, f) => s + (weights.get(f) ?? 0), 0) || 1;
      const stillActive = [];
      const slots = remaining;
      for (const f of active) {
        const quota = Math.max(pass === 0 ? 0 : 1, Math.round(slots * (weights.get(f) ?? 0) / wTotal));
        const take = takeFromFolder(f, Math.min(quota, remaining));
        dealt.push(...take);
        dealtPerFolder.set(f, (dealtPerFolder.get(f) ?? 0) + take.length);
        remaining -= take.length;
        if (take.length >= quota && quota > 0) stillActive.push(f);
        if (remaining <= 0) break;
      }
      active = stillActive;
    }
    for (const m of mix) noteMeta(m.folderId, dealtPerFolder.get(m.folderId) ?? 0);
    return finish("scheduled", order(dealt));
  }

  // src/scheduler/sm2.ts
  function initialComponentState(now, config = DEFAULT_CONFIG) {
    return {
      status: STATUS.NEW,
      dueAt: now.toISOString(),
      intervalDays: 0,
      easeFactor: config.initialEase,
      stepIndex: 0,
      reviewCount: 0,
      lapseCount: 0,
      streak: 0,
      lastReviewedAt: null
    };
  }
  function jitterMinutes(now, maxMinutes) {
    if (maxMinutes <= 0) return 0;
    return now.getTime() % 1e3 / 1e3 * maxMinutes;
  }
  function computeNext(state, rating, now, config = DEFAULT_CONFIG, mechanics = DEFAULT_MECHANICS) {
    const currentInterval = state.intervalDays;
    const currentEase = state.easeFactor;
    const currentStatus = state.status;
    let newInterval;
    let newEase = currentEase;
    let newStatus;
    const isNewCard = currentStatus === STATUS.NEW || currentInterval === 0;
    const isLearningPhase = currentStatus === STATUS.LEARNING || currentStatus === STATUS.RELEARNING;
    if (isNewCard) {
      newInterval = config.newCardIntervals[rating];
      newStatus = rating === RATINGS.AGAIN ? STATUS.LEARNING : STATUS.REVIEW;
      if (rating === RATINGS.AGAIN) newEase = Math.max(config.minimumEase, currentEase + config.easeBonus.again);
    } else if (isLearningPhase) {
      newInterval = config.graduationIntervals[rating];
      newStatus = rating === RATINGS.AGAIN ? currentStatus : STATUS.REVIEW;
    } else {
      newEase = Math.max(config.minimumEase, currentEase + (config.easeBonus[rating] || 0));
      let base = currentInterval;
      if (mechanics.growFromElapsed && state.lastReviewedAt) {
        const elapsedDays = (now.getTime() - new Date(state.lastReviewedAt).getTime()) / DAY_MS;
        if (elapsedDays > base) base = elapsedDays;
      }
      switch (rating) {
        case RATINGS.AGAIN:
          newInterval = config.newCardIntervals.again;
          newStatus = STATUS.RELEARNING;
          break;
        case RATINGS.HARD:
          newInterval = Math.max(base * config.intervalMultiplier.hard, 1);
          newStatus = STATUS.REVIEW;
          break;
        case RATINGS.GOOD:
          newInterval = Math.max(base * newEase, 1);
          newStatus = STATUS.REVIEW;
          break;
        case RATINGS.EASY:
          newInterval = Math.max(base * newEase * config.intervalMultiplier.easy, 1);
          newStatus = STATUS.REVIEW;
          break;
        case RATINGS.TRIVIAL:
          newInterval = Math.max(base * newEase * config.intervalMultiplier.trivial, 1);
          newStatus = STATUS.REVIEW;
          break;
        default:
          throw new Error(`Unknown rating: ${rating}`);
      }
    }
    newInterval = Math.min(newInterval, config.maxIntervalDays);
    if (rating === RATINGS.AGAIN && mechanics.retryDelayMinutes != null) {
      newInterval = mechanics.retryDelayMinutes * MINUTE_MS / DAY_MS;
    }
    let dueMs = now.getTime() + newInterval * DAY_MS;
    if (newInterval >= 1) dueMs += jitterMinutes(now, mechanics.jitterMaxMinutes) * MINUTE_MS;
    const isAgain = rating === RATINGS.AGAIN;
    return {
      ...state,
      status: newStatus,
      dueAt: new Date(dueMs).toISOString(),
      intervalDays: newInterval,
      easeFactor: newEase,
      reviewCount: state.reviewCount + 1,
      lapseCount: state.lapseCount + (isAgain ? 1 : 0),
      streak: isAgain ? 0 : state.streak + 1,
      lastReviewedAt: now.toISOString()
    };
  }
  function isDue(state, now, mechanics = DEFAULT_MECHANICS) {
    return new Date(state.dueAt).getTime() <= now.getTime() + mechanics.dueLookaheadHours * 60 * MINUTE_MS;
  }
  function getIntervalDisplay(days) {
    if (days < 7e-4) return "<1m";
    const minutes = days * 24 * 60;
    if (minutes < 60) return `${Math.round(minutes)}m`;
    const hours = minutes / 60;
    if (hours < 24) return `${Math.round(hours)}h`;
    if (days < 7) return `${Math.round(days)}d`;
    const weeks = days / 7;
    if (weeks < 4) return `${Math.round(weeks)}w`;
    const months = days / 30;
    if (months < 12) return `${Math.round(months)}mo`;
    return `${(days / 365).toFixed(1)}y`;
  }
  function previewComponent(state, now, config = DEFAULT_CONFIG, mechanics = DEFAULT_MECHANICS) {
    const out = { again: "", hard: "", good: "", easy: "", trivial: "" };
    for (const rating of Object.values(RATINGS)) {
      out[rating] = getIntervalDisplay(computeNext(state, rating, now, config, mechanics).intervalDays);
    }
    return out;
  }

  // src/scheduler/index.ts
  function sm2Scheduler(config = DEFAULT_CONFIG, mechanics = DEFAULT_MECHANICS) {
    return {
      id: SCHEDULER_ID,
      mechanics,
      initial: (now) => initialComponentState(now, config),
      next: (state, rating, now, m) => computeNext(state, rating, now, config, m ?? mechanics),
      preview: (state, now) => previewComponent(state, now, config, mechanics),
      isDue: (state, now) => isDue(state, now, mechanics)
    };
  }
  var defaultScheduler = sm2Scheduler();

  // src/offline.ts
  var key2 = (cardId, componentId) => `${cardId}:${componentId}`;
  function candidates(snap2) {
    const states = new Map(snap2.states.map((s) => [key2(s.cardId, s.componentId), s]));
    const rows = [];
    for (const c of snap2.cards) {
      for (const componentId of componentIdsOf(c.spec)) {
        const s = states.get(key2(c.id, componentId));
        rows.push({ cardId: c.id, componentId, folderId: c.folderId, createdAt: c.createdAt, status: s?.status ?? null, dueAt: s?.dueAt ?? null });
      }
    }
    return rows;
  }
  function moduleSource(use, base) {
    const m = /^(me\/)?([a-z0-9-]+)@(\d+)$/.exec(use);
    if (!m) return null;
    return m[1] ? base ? `${base}/${m[2]}/${m[3]}/index.html` : null : `/modules/${m[2]}/${m[3]}/index.html`;
  }
  function withSources(modules, base) {
    const add = (u) => ({ ...u, src: moduleSource(u.use, base) });
    return {
      ...modules.prompt ? { prompt: modules.prompt.map(add) } : {},
      ...modules.respond ? { respond: add(modules.respond) } : {},
      ...modules.reveal ? { reveal: modules.reveal.map(add) } : {}
    };
  }
  function offlineItem(snap2, cardId, componentId, now) {
    const card = snap2.cards.find((c) => c.id === cardId);
    if (!card) return null;
    const ids = componentIdsOf(card.spec);
    const component = ids.includes(componentId) ? componentId : componentId === MAIN_COMPONENT ? ids[0] : null;
    if (!component) return null;
    const qa = renderComponent(card.spec, component);
    const stateRow = snap2.states.find((s) => s.cardId === cardId && s.componentId === component) ?? null;
    const state = stateRow ?? defaultScheduler.initial(now);
    const spec = card.spec;
    const simple = spec.style !== "qa_bidirectional" && spec.style !== "cloze_list";
    const numeric = simple && spec.answerType === "numeric" ? spec.numeric ?? null : null;
    return {
      card_id: cardId,
      component_id: component,
      component_count: ids.length,
      question: qa.question,
      answer: qa.answer,
      style: componentStyle(spec),
      tags: card.tags,
      image_url: card.imageUrl,
      source_url: card.sourceUrl,
      provenance: card.provenance,
      source_selection: card.provenance?.selection ?? null,
      answer_type: numeric ? "numeric" : "text",
      numeric_answer: numeric?.value ?? null,
      numeric_unit: numeric?.unit ?? null,
      answer_mode: simple ? spec.answerType ?? "text" : "text",
      modules: simple && spec.modules ? withSources(spec.modules, snap2.userModuleBase) : null,
      folder: card.folderId ? { id: card.folderId, name: card.folderName } : null,
      is_new: !stateRow || stateRow.status === "new",
      previews: defaultScheduler.preview(state, now)
    };
  }
  function dealOffline(snap2, opts, now = /* @__PURE__ */ new Date()) {
    const result = selectSession({
      mode: opts.mode ?? "scheduled",
      size: opts.size ?? snap2.sessionSize,
      folderId: opts.folderId,
      folders: snap2.folders,
      candidates: candidates(snap2),
      newReviewedTodayByFolder: new Map(Object.entries(snap2.newToday).map(([k, v]) => [k === "null" ? null : k, v])),
      defaultNewPerDay: snap2.defaultNewPerDay,
      now
    });
    return result.dealt.map((d) => offlineItem(snap2, d.cardId, d.componentId, now)).filter((x) => x !== null);
  }
  function rateOffline(snap2, cardId, componentId, rating, now = /* @__PURE__ */ new Date()) {
    const card = snap2.cards.find((c) => c.id === cardId);
    if (!card) throw new Error("Card not in the offline copy");
    const i = snap2.states.findIndex((s) => s.cardId === cardId && s.componentId === componentId);
    const before = i >= 0 ? snap2.states[i] : null;
    const next = defaultScheduler.next(before ?? defaultScheduler.initial(now), rating, now, DEFAULT_MECHANICS);
    const row = { ...next, cardId, componentId };
    if (i >= 0) snap2.states[i] = row;
    else snap2.states.push(row);
    if (!before || before.status === "new") {
      const k = card.folderId ?? "null";
      snap2.newToday[k] = (snap2.newToday[k] ?? 0) + 1;
    }
    return { state: row, previews: defaultScheduler.preview(row, now) };
  }
  function offlineToday(snap2, now = /* @__PURE__ */ new Date()) {
    return dealOffline(snap2, { mode: "scheduled", size: 1e3 }, now).reduce(
      (acc, item) => {
        if (item.is_new) acc.learn++;
        else acc.review++;
        return acc;
      },
      { review: 0, learn: 0 }
    );
  }

  // src/offline-bundle.ts
  var snap = null;
  var need = () => {
    if (!snap) throw new Error("No offline copy loaded");
    return snap;
  };
  var api = {
    load(json) {
      snap = JSON.parse(json);
      return snap.cards.length;
    },
    deal(opts, now) {
      return JSON.stringify(dealOffline(need(), JSON.parse(opts), new Date(now)));
    },
    rate(cardId, componentId, rating, now) {
      return JSON.stringify(rateOffline(need(), cardId, componentId, rating, new Date(now)));
    },
    today(now) {
      return JSON.stringify(offlineToday(need(), new Date(now)));
    }
  };
  globalThis.PluckkCore = api;
})();
