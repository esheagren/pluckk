// Practice without the server. The Mac app keeps a snapshot of the account (cards, review states,
// deck limits) and runs these functions inside the app (JavaScriptCore), so an offline session is
// dealt, shown and scheduled exactly as the API would. Ratings made offline are queued by the app
// and sent later with the time they happened; the server replays them at that moment.

import type { CardModules, CardSpec, ComponentState, ModuleUse, Rating } from './entities.js';
import { componentIdsOf, componentStyle, MAIN_COMPONENT, renderComponent } from './entities.js';
import { selectSession, type CandidateRow, type FolderInfo } from './queue.js';
import { DEFAULT_MECHANICS } from './scheduler/constants.js';
import { defaultScheduler } from './scheduler/index.js';

export interface SnapshotCard {
  id: string;
  folderId: string | null;
  folderName: string | null;
  createdAt: string;
  spec: CardSpec;
  tags: string[];
  imageUrl: string | null;
  provenance: Record<string, unknown> | null;
  sourceUrl: string | null;
}

export interface SnapshotState extends ComponentState { cardId: string; componentId: string }

export interface Snapshot {
  takenAt: string;
  cards: SnapshotCard[];
  states: SnapshotState[];
  /** Deck limits as the server deals them today (difficulty caps already applied). */
  folders: Array<FolderInfo & { name: string | null }>;
  /** New cards already introduced today, by deck id ("null" for unfiled). */
  newToday: Record<string, number>;
  defaultNewPerDay: number;
  sessionSize: number;
  /** Where the user's own modules are served from (me/<slug>@<n> → <base>/<slug>/<n>/index.html). */
  userModuleBase: string | null;
}

const key = (cardId: string, componentId: string) => `${cardId}:${componentId}`;

function candidates(snap: Snapshot): CandidateRow[] {
  const states = new Map(snap.states.map((s) => [key(s.cardId, s.componentId), s]));
  const rows: CandidateRow[] = [];
  for (const c of snap.cards) {
    for (const componentId of componentIdsOf(c.spec)) {
      const s = states.get(key(c.id, componentId));
      rows.push({ cardId: c.id, componentId, folderId: c.folderId, createdAt: c.createdAt, status: s?.status ?? null, dueAt: s?.dueAt ?? null });
    }
  }
  return rows;
}

function moduleSource(use: string, base: string | null): string | null {
  const m = /^(me\/)?([a-z0-9-]+)@(\d+)$/.exec(use);
  if (!m) return null;
  return m[1] ? (base ? `${base}/${m[2]}/${m[3]}/index.html` : null) : `/modules/${m[2]}/${m[3]}/index.html`;
}

function withSources(modules: CardModules, base: string | null): CardModules {
  const add = (u: ModuleUse) => ({ ...u, src: moduleSource(u.use, base) });
  return {
    ...(modules.prompt ? { prompt: modules.prompt.map(add) } : {}),
    ...(modules.respond ? { respond: add(modules.respond) } : {}),
    ...(modules.reveal ? { reveal: modules.reveal.map(add) } : {}),
  };
}

/** One component as the practice screen gets it: the same shape as the API's review items. */
export function offlineItem(snap: Snapshot, cardId: string, componentId: string, now: Date) {
  const card = snap.cards.find((c) => c.id === cardId);
  if (!card) return null;
  const ids = componentIdsOf(card.spec);
  const component = ids.includes(componentId) ? componentId : componentId === MAIN_COMPONENT ? ids[0] : null;
  if (!component) return null;
  const qa = renderComponent(card.spec, component);
  const stateRow = snap.states.find((s) => s.cardId === cardId && s.componentId === component) ?? null;
  const state = stateRow ?? defaultScheduler.initial(now);
  const spec = card.spec;
  const simple = spec.style !== 'qa_bidirectional' && spec.style !== 'cloze_list';
  const numeric = simple && spec.answerType === 'numeric' ? spec.numeric ?? null : null;
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
    source_selection: (card.provenance?.selection as string | undefined) ?? null,
    answer_type: numeric ? 'numeric' : 'text',
    numeric_answer: numeric?.value ?? null,
    numeric_unit: numeric?.unit ?? null,
    answer_mode: simple ? spec.answerType ?? 'text' : 'text',
    modules: simple && spec.modules ? withSources(spec.modules, snap.userModuleBase) : null,
    folder: card.folderId ? { id: card.folderId, name: card.folderName } : null,
    is_new: !stateRow || stateRow.status === 'new',
    previews: defaultScheduler.preview(state, now),
  };
}

/** Deal a session from the snapshot, as POST review/session would. */
export function dealOffline(snap: Snapshot, opts: { mode?: 'scheduled' | 'focus' | 'ahead'; folderId?: string | null; size?: number }, now: Date = new Date()) {
  const result = selectSession({
    mode: opts.mode ?? 'scheduled',
    size: opts.size ?? snap.sessionSize,
    folderId: opts.folderId,
    folders: snap.folders,
    candidates: candidates(snap),
    newReviewedTodayByFolder: new Map(Object.entries(snap.newToday).map(([k, v]) => [k === 'null' ? null : k, v])),
    defaultNewPerDay: snap.defaultNewPerDay,
    now,
  });
  return result.dealt.map((d) => offlineItem(snap, d.cardId, d.componentId, now)).filter((x) => x !== null);
}

/** Rate a card in the snapshot (changing it in place) and return its new previews and state. */
export function rateOffline(snap: Snapshot, cardId: string, componentId: string, rating: Rating, now: Date = new Date()) {
  const card = snap.cards.find((c) => c.id === cardId);
  if (!card) throw new Error('Card not in the offline copy');
  const i = snap.states.findIndex((s) => s.cardId === cardId && s.componentId === componentId);
  const before = i >= 0 ? snap.states[i] : null;
  const next = defaultScheduler.next(before ?? defaultScheduler.initial(now), rating, now, DEFAULT_MECHANICS);
  const row: SnapshotState = { ...next, cardId, componentId };
  if (i >= 0) snap.states[i] = row; else snap.states.push(row);
  if (!before || before.status === 'new') {
    const k = card.folderId ?? 'null';
    snap.newToday[k] = (snap.newToday[k] ?? 0) + 1;
  }
  return { state: row, previews: defaultScheduler.preview(row, now) };
}

/** What's left today in the snapshot, as GET review/today would say. */
export function offlineToday(snap: Snapshot, now: Date = new Date()) {
  return dealOffline(snap, { mode: 'scheduled', size: 1000 }, now).reduce(
    (acc, item) => { if (item!.is_new) acc.learn++; else acc.review++; return acc; },
    { review: 0, learn: 0 });
}
