// Review items: what a client shows for one component of one card — the rendered
// question/answer for that component, its schedule, and the interval previews.
// Used by POST review/session (freshly dealt) and POST review/items (restoring a session).

import { and, eq, inArray } from 'drizzle-orm';
import {
  componentIdsOf, componentStyle, defaultScheduler, MAIN_COMPONENT, renderComponent, specFromLegacy,
  type CardModules, type ComponentState, type DealtItem, type ModuleUse,
} from '@pluckk/core';
import { getDb, schema } from './db.js';
import { isoTimestamp, snake } from './serialize.js';

type Db = ReturnType<typeof getDb>;
type StateRow = typeof schema.cardReviewState.$inferSelect;

export function stateFromRow(s: StateRow): ComponentState {
  return {
    status: s.status as ComponentState['status'], dueAt: isoTimestamp(s.dueAt), intervalDays: s.intervalDays, easeFactor: s.easeFactor,
    stepIndex: s.stepIndex ?? 0, reviewCount: s.reviewCount, lapseCount: s.lapseCount, streak: s.streak,
    lastReviewedAt: s.lastReviewedAt ? isoTimestamp(s.lastReviewedAt) : null, stability: s.stability ?? null, difficulty: s.difficulty ?? null,
  };
}

/** Resolve a requested component against a spec: 'main' on a composite means its first component. */
export function resolveComponent(ids: string[], requested: string | undefined): string | null {
  const id = requested ?? MAIN_COMPONENT;
  if (ids.includes(id)) return id;
  if (id === MAIN_COMPONENT && ids.length > 0) return ids[0];
  return null;
}

export async function buildItems(db: Db, userId: string, dealt: DealtItem[]) {
  if (dealt.length === 0) return [];
  const cardIds = [...new Set(dealt.map((d) => d.cardId))];
  const rows = await db.select({ card: schema.cards, folder: schema.folders }).from(schema.cards)
    .leftJoin(schema.folders, eq(schema.cards.folderId, schema.folders.id))
    .where(and(eq(schema.cards.userId, userId), eq(schema.cards.isDeleted, false), inArray(schema.cards.id, cardIds)));
  const states = await db.select().from(schema.cardReviewState)
    .where(and(eq(schema.cardReviewState.userId, userId), inArray(schema.cardReviewState.cardId, cardIds)));
  const byCard = new Map(rows.map((r) => [r.card.id, r]));
  const stateBy = new Map(states.map((s) => [`${s.cardId}:${s.componentId}`, s]));
  const now = new Date();

  const items = [];
  for (const d of dealt) {
    const r = byCard.get(d.cardId);
    if (!r) continue;
    const spec = r.card.spec ?? specFromLegacy(r.card);
    const ids = componentIdsOf(spec);
    const componentId = resolveComponent(ids, d.componentId);
    if (!componentId) continue;
    const qa = renderComponent(spec, componentId);
    const stateRow = stateBy.get(`${d.cardId}:${componentId}`) ?? null;
    const state = stateRow ? stateFromRow(stateRow) : defaultScheduler.initial(now);
    items.push({
      ...snake<Record<string, unknown>>(r.card),
      card_id: d.cardId,
      component_id: componentId,
      component_count: ids.length,
      question: qa.question,
      answer: qa.answer,
      style: componentStyle(spec),
      // How the card is answered beyond plain recall: numeric (a range), written (typed out, checked).
      answer_mode: 'answerType' in spec ? spec.answerType ?? 'text' : 'text',
      folder: r.folder ? snake(r.folder) : null,
      is_new: !stateRow || stateRow.status === 'new',
      review_state: stateRow ? snake(stateRow) : null,
      previews: defaultScheduler.preview(state, now),
      // Verbatim, not snake_cased: module props are the module's own keys. Each use gets the
      // address its page is served from.
      modules: 'modules' in spec && spec.modules ? withSources(spec.modules, userId) : null,
    });
  }
  return items;
}

/** Where a module's page is served: built-ins under /modules, the user's own under /um. */
export function moduleSource(use: string, userId: string): string | null {
  const m = /^(me\/)?([a-z0-9-]+)@(\d+)$/.exec(use);
  if (!m) return null;
  return m[1] ? `/um/${userId}/${m[2]}/${m[3]}/index.html` : `/modules/${m[2]}/${m[3]}/index.html`;
}

function withSources(modules: CardModules, userId: string): CardModules {
  const add = (u: ModuleUse) => ({ ...u, src: moduleSource(u.use, userId) });
  return {
    ...(modules.prompt ? { prompt: modules.prompt.map(add) } : {}),
    ...(modules.respond ? { respond: add(modules.respond) } : {}),
    ...(modules.reveal ? { reveal: modules.reveal.map(add) } : {}),
  };
}
