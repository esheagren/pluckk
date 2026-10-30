// Review-mixer selection: decides WHICH components enter a session; never touches
// scheduling. Moved from packages/api/lib/mixer.ts unchanged in its rules, plus:
//   - candidates carry a componentId (default 'main') so a card with several
//     schedules can be dealt one component at a time;
//   - at most one component per card is dealt in a session (earliest due wins);
//   - "due" honours the look-ahead mechanic (off by default).
//
// Modes (docs/roadmap/completed/review-mixer/plan.md):
//   scheduled — per-folder quotas from a mix (explicit or saved folder weights),
//               fill due → new (per-folder new/day cap), deficits redistributed
//   focus     — one folder, quota = size, same fill order
//   backlog   — one folder, every due card oldest-first, batched; no new cards

import { MAIN_COMPONENT, type ComponentId } from './entities.js';
import { DEFAULT_MECHANICS, MINUTE_MS } from './scheduler/constants.js';

export interface CandidateRow {
  cardId: string;
  componentId?: ComponentId;
  folderId: string | null;
  createdAt: string;
  status: string | null;   // review-state status, null = new
  dueAt: string | null;
}

export interface MixEntry { folderId: string | null; pct: number }

export interface FolderInfo { id: string; weight: number | null; isPaused: boolean; newPerDay: number | null }

export interface MixerInput {
  mode: 'scheduled' | 'focus' | 'backlog';
  size: number;
  folderId?: string | null;          // focus/backlog
  mix?: MixEntry[];                  // scheduled override
  folders: FolderInfo[];
  candidates: CandidateRow[];        // every non-paused candidate component
  newReviewedTodayByFolder: Map<string | null, number>;
  defaultNewPerDay: number;
  now?: Date;
  /** Hours of look-ahead when deciding what is due. Defaults to the scheduler mechanics (0 until step 7). */
  dueLookaheadHours?: number;
  /** Deterministic order when true (tests); otherwise dealt sets are shuffled. */
  noShuffle?: boolean;
}

export interface DealtItem { cardId: string; componentId: ComponentId }

export interface MixerResult {
  dealt: DealtItem[];
  /** Card ids in dealt order — what the API has always returned. */
  dealtIds: string[];
  meta: {
    mode: string;
    per_folder: Record<string, { due: number; new: number; dealt: number }>;
    due_total: number;
    backlog_remaining?: number;
  };
}

const key = (f: string | null) => f ?? 'unfiled';

function shuffle<T>(arr: T[]): T[] {
  for (let i = arr.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [arr[i], arr[j]] = [arr[j], arr[i]];
  }
  return arr;
}

/** Keep one component per card: the earliest-due one, ties by component order. */
export function onePerCard(rows: CandidateRow[]): CandidateRow[] {
  const best = new Map<string, CandidateRow>();
  for (const r of rows) {
    const cur = best.get(r.cardId);
    if (!cur) { best.set(r.cardId, r); continue; }
    const rd = r.dueAt ?? '', cd = cur.dueAt ?? '';
    if (rd < cd || (rd === cd && (r.componentId ?? MAIN_COMPONENT) < (cur.componentId ?? MAIN_COMPONENT))) best.set(r.cardId, r);
  }
  return [...best.values()];
}

export interface TodayCountsInput {
  folders: FolderInfo[];
  candidates: CandidateRow[];
  newReviewedTodayByFolder: Map<string | null, number>;
  defaultNewPerDay: number;
  now?: Date;
  dueLookaheadHours?: number;
}

/**
 * What's left for today across the Mix, by the rules selectSession deals with: paused decks are
 * out; once any deck has a Mix %, only those decks count; one component per card; new cards are
 * capped by each deck's remaining new/day budget. `review` = due now, `learn` = new cards today's
 * limits still allow. Together they equal what an uncapped session would deal.
 */
export function todayCounts(input: TodayCountsInput): { review: number; learn: number } {
  const now = input.now ?? new Date();
  const lookaheadMs = (input.dueLookaheadHours ?? DEFAULT_MECHANICS.dueLookaheadHours) * 60 * MINUTE_MS;
  const dueCutoff = now.getTime() + lookaheadMs;
  const paused = new Set(input.folders.filter((f) => f.isPaused).map((f) => f.id));
  const weighted = input.folders.filter((f) => !f.isPaused && (f.weight ?? 0) > 0).map((f) => f.id);
  const inMix = (f: string | null) =>
    weighted.length > 0 ? f !== null && weighted.includes(f) : !(f && paused.has(f));

  let review = 0;
  let learn = 0;
  const fresh = new Map<string | null, number>();
  for (const c of onePerCard(input.candidates.filter((x) => inMix(x.folderId)))) {
    if (!c.status) fresh.set(c.folderId, (fresh.get(c.folderId) ?? 0) + 1);
    else if (c.dueAt && new Date(c.dueAt).getTime() <= dueCutoff) {
      // A card with a schedule row but no reviews yet: the mixer deals it as due (uncapped), and
      // clients show it as new, so it counts as one to learn.
      if (c.status === 'new') learn++;
      else review++;
    }
  }

  for (const [f, count] of fresh) {
    const info = f ? input.folders.find((x) => x.id === f) : null;
    const cap = info?.newPerDay ?? input.defaultNewPerDay;
    learn += Math.min(count, Math.max(0, cap - (input.newReviewedTodayByFolder.get(f) ?? 0)));
  }
  return { review, learn };
}

export function selectSession(input: MixerInput): MixerResult {
  const now = input.now ?? new Date();
  const lookaheadMs = (input.dueLookaheadHours ?? DEFAULT_MECHANICS.dueLookaheadHours) * 60 * MINUTE_MS;
  const dueCutoff = now.getTime() + lookaheadMs;
  const order = <T>(arr: T[]) => (input.noShuffle ? arr : shuffle(arr));
  const paused = new Set(input.folders.filter((f) => f.isPaused).map((f) => f.id));
  // Pause guards the Mix only: explicitly focusing/backlogging a paused deck is deliberate.
  const target = input.mode !== 'scheduled' ? input.folderId ?? null : undefined;
  const candidates = onePerCard(input.candidates.filter((c) => !(c.folderId && paused.has(c.folderId) && c.folderId !== target)));

  // Partition per folder into due (state exists, due_at <= cutoff) and new (no state).
  const byFolder = new Map<string | null, { due: CandidateRow[]; fresh: CandidateRow[] }>();
  for (const c of candidates) {
    let b = byFolder.get(c.folderId);
    if (!b) { b = { due: [], fresh: [] }; byFolder.set(c.folderId, b); }
    if (!c.status) b.fresh.push(c);
    else if (c.dueAt && new Date(c.dueAt).getTime() <= dueCutoff) b.due.push(c);
  }
  for (const b of byFolder.values()) {
    b.due.sort((a, z) => (a.dueAt! < z.dueAt! ? -1 : 1));            // oldest due first
    b.fresh.sort((a, z) => (a.createdAt < z.createdAt ? -1 : 1));    // oldest created first
  }
  const dueTotal = [...byFolder.values()].reduce((s, b) => s + b.due.length, 0);

  const perFolderMeta: MixerResult['meta']['per_folder'] = {};
  const noteMeta = (f: string | null, dealt: number) => {
    const b = byFolder.get(f) ?? { due: [], fresh: [] };
    perFolderMeta[key(f)] = { due: b.due.length, new: b.fresh.length, dealt };
  };

  const newBudget = (f: string | null): number => {
    const info = f ? input.folders.find((x) => x.id === f) : null;
    const cap = info?.newPerDay ?? input.defaultNewPerDay;
    return Math.max(0, cap - (input.newReviewedTodayByFolder.get(f) ?? 0));
  };

  const takeFromFolder = (f: string | null, quota: number): CandidateRow[] => {
    const b = byFolder.get(f);
    if (!b) return [];
    const take: CandidateRow[] = b.due.slice(0, quota);
    if (take.length < quota) take.push(...b.fresh.slice(0, Math.min(quota - take.length, newBudget(f))));
    // remove taken so redistribution passes don't re-take
    b.due = b.due.slice(Math.min(quota, take.length));
    const newTaken = take.filter((c) => !c.status).length;
    b.fresh = b.fresh.slice(newTaken);
    input.newReviewedTodayByFolder.set(f, (input.newReviewedTodayByFolder.get(f) ?? 0) + newTaken);
    return take;
  };

  const finish = (mode: string, rows: CandidateRow[], extra?: { backlog_remaining: number }): MixerResult => {
    const dealt = rows.map((c) => ({ cardId: c.cardId, componentId: c.componentId ?? MAIN_COMPONENT }));
    return { dealt, dealtIds: dealt.map((d) => d.cardId), meta: { mode, per_folder: perFolderMeta, due_total: dueTotal, ...extra } };
  };

  if (input.mode === 'backlog') {
    const f = input.folderId ?? null;
    const b = byFolder.get(f) ?? { due: [], fresh: [] };
    const dealt = b.due.slice(0, input.size);
    noteMeta(f, dealt.length);
    // oldest-first, not shuffled: burn-down order
    return finish('backlog', dealt, { backlog_remaining: b.due.length - dealt.length });
  }

  if (input.mode === 'focus') {
    const f = input.folderId ?? null;
    const dealt = takeFromFolder(f, input.size);
    noteMeta(f, dealt.length);
    return finish('focus', order(dealt));
  }

  // scheduled: explicit mix > saved weights > every non-paused folder equally (incl. unfiled)
  let mix: MixEntry[] = input.mix ?? [];
  if (mix.length === 0) {
    const weighted = input.folders.filter((f) => !f.isPaused && (f.weight ?? 0) > 0);
    mix = weighted.length > 0
      ? weighted.map((f) => ({ folderId: f.id, pct: f.weight! }))
      : [...byFolder.keys()].map((f) => ({ folderId: f, pct: 1 }));
  }
  mix = mix.filter((m) => !(m.folderId && paused.has(m.folderId)) && m.pct > 0);
  const pctTotal = mix.reduce((s, m) => s + m.pct, 0) || 1;

  const dealt: CandidateRow[] = [];
  const dealtPerFolder = new Map<string | null, number>();
  // pass 1: quotas; pass 2+: redistribute remaining slots to folders that still have supply
  let remaining = input.size;
  let active = mix.map((m) => m.folderId);
  const weights = new Map(mix.map((m) => [m.folderId, m.pct / pctTotal] as const));
  for (let pass = 0; pass < 4 && remaining > 0 && active.length > 0; pass++) {
    const wTotal = active.reduce((s, f) => s + (weights.get(f) ?? 0), 0) || 1;
    const stillActive: (string | null)[] = [];
    const slots = remaining;
    for (const f of active) {
      const quota = Math.max(pass === 0 ? 0 : 1, Math.round((slots * (weights.get(f) ?? 0)) / wTotal));
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
  return finish('scheduled', order(dealt));
}
