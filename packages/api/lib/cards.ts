// Card writes, core-engine style: every change is an event appended to the diary
// (lib/store.ts) and the snapshot rows are rebuilt from it. Handlers in api/v1.ts
// parse the request and call these; nothing here touches the wire shape.

import { and, eq } from 'drizzle-orm';
import {
  captureKey as makeCaptureKey, componentIdsOf, defaultScheduler, legacyFromSpec, MAIN_COMPONENT,
  provenanceFromLegacy, rebuild, specFromLegacy,
  type Card, type CardSpec, type ComponentState, type CreateCardBody, type PatchCardBody, type Provenance, type Rating,
} from '@pluckk/core';
import { getDb, schema } from './db.js';
import { isoTimestamp } from './serialize.js';
import { commit, loadEvents, type NewEvent } from './store.js';

type Db = ReturnType<typeof getDb>;
export type CardRow = typeof schema.cards.$inferSelect;

export class CardError extends Error {
  constructor(public readonly status: number, message: string) { super(message); }
}

// ---------------------------------------------------------------- request → core values

export function specFromBody(b: CreateCardBody | PatchCardBody, current?: CardSpec | null): CardSpec | null {
  if (b.spec) return b.spec;
  if (!b.question && !b.answer && !b.style && !('answer_type' in b) && !('numeric_answer' in b) && !('numeric_unit' in b)) return null;
  if (current && (current.style === 'qa_bidirectional' || current.style === 'cloze_list')) {
    throw new CardError(400, 'This card has several components; edit it with a full spec');
  }
  const base = current ?? null;  // narrowed to a simple spec by the guard above
  return specFromLegacy({
    question: b.question ?? base?.question ?? '',
    answer: b.answer ?? base?.answer ?? '',
    style: b.style ?? base?.style ?? 'qa',
    answerType: 'answer_type' in b ? b.answer_type : base?.answerType,
    numericAnswer: 'numeric_answer' in b ? b.numeric_answer : base?.numeric?.value,
    numericLower: 'numeric_lower' in b ? b.numeric_lower : base?.numeric?.lower,
    numericUpper: 'numeric_upper' in b ? b.numeric_upper : base?.numeric?.upper,
    numericUnit: 'numeric_unit' in b ? b.numeric_unit : base?.numeric?.unit,
    numericPrecision: 'numeric_precision' in b ? b.numeric_precision : base?.numeric?.precision,
  });
}

export function provenanceFromBody(b: CreateCardBody | PatchCardBody, current?: Provenance | null): Provenance | null {
  if (b.provenance !== undefined) return b.provenance ?? null;
  const legacy = provenanceFromLegacy({
    sourceUrl: b.source_url ?? current?.url,
    sourceTitle: b.source_title ?? current?.title,
    sourceSelection: 'source_selection' in b ? b.source_selection : current?.selection,
    sourceContext: 'source_context' in b ? b.source_context : current?.context,
  });
  if (!legacy) return current ?? null;
  return current ? { ...current, ...legacy, selector: legacy.selector ?? current.selector ?? null } : legacy;
}

export function captureKeyFor(b: CreateCardBody, provenance: Provenance | null): string | null {
  if (b.capture_key) return b.capture_key;
  const selection = b.source_selection ?? provenance?.selection;
  return provenance && selection ? makeCaptureKey(selection, provenance.identifier) : null;
}

// ---------------------------------------------------------------- reads

export async function getCardRow(db: Db, userId: string, id: string): Promise<CardRow> {
  const [row] = await db.select().from(schema.cards).where(and(eq(schema.cards.id, id), eq(schema.cards.userId, userId)));
  if (!row || row.isDeleted) throw new CardError(404, 'Card not found');
  return row;
}

/** The spec of a stored card. Cards written before the diary existed only have the flat columns. */
export function specOf(row: CardRow): CardSpec {
  return row.spec ?? specFromLegacy(row);
}

/**
 * Cards saved by the pre-diary API between the backfill and step 3 have no events.
 * Give them an ingest (and a reschedule carrying their current state) before touching them.
 */
export async function ensureDiary(db: Db, row: CardRow): Promise<void> {
  if (row.snapshotSeq != null) return;
  const events = await loadEvents(db, row.id);
  if (events.some((e) => e.type === 'card.ingest')) return;
  const spec = specOf(row);
  const provenance = row.provenance ?? provenanceFromLegacy(row);
  const toWrite: NewEvent[] = [{
    type: 'card.ingest', userId: row.userId!, cardId: row.id, at: isoTimestamp(row.createdAt),
    spec, provenance, folderId: row.folderId, tags: row.tags ?? [], captureKey: row.captureKey, imageUrl: row.imageUrl,
  }];
  const states = await db.select().from(schema.cardReviewState)
    .where(and(eq(schema.cardReviewState.cardId, row.id), eq(schema.cardReviewState.userId, row.userId!)));
  for (const s of states) {
    const state: ComponentState = {
      status: s.status as ComponentState['status'], dueAt: isoTimestamp(s.dueAt), intervalDays: s.intervalDays, easeFactor: s.easeFactor,
      stepIndex: s.stepIndex ?? 0, reviewCount: s.reviewCount, lapseCount: s.lapseCount, streak: s.streak,
      lastReviewedAt: s.lastReviewedAt ? isoTimestamp(s.lastReviewedAt) : null, stability: s.stability ?? null, difficulty: s.difficulty ?? null,
    };
    toWrite.push({ type: 'card.reschedule', userId: row.userId!, cardId: row.id, at: isoTimestamp(s.updatedAt), componentId: s.componentId, state });
  }
  await commit(db, toWrite);
}

// ---------------------------------------------------------------- writes

export interface CreateResult { row: CardRow; card: Card | null; existing: boolean }

export async function createCard(db: Db, userId: string, body: CreateCardBody): Promise<CreateResult> {
  const spec = specFromBody(body);
  if (!spec) throw new CardError(400, 'spec or question+answer required');
  const provenance = provenanceFromBody(body);
  const key = captureKeyFor(body, provenance);

  if (key) {
    const [dup] = await db.select().from(schema.cards)
      .where(and(eq(schema.cards.userId, userId), eq(schema.cards.captureKey, key), eq(schema.cards.isDeleted, false)));
    if (dup) return { row: dup, card: null, existing: true };
  }

  const mirror = legacyFromSpec(spec);
  let row: CardRow;
  try {
    [row] = await db.insert(schema.cards).values({
      userId,
      question: mirror.question, answer: mirror.answer, style: spec.style,
      answerType: mirror.answerType ?? 'text',
      numericAnswer: mirror.numericAnswer ?? null, numericLower: mirror.numericLower ?? null, numericUpper: mirror.numericUpper ?? null,
      numericUnit: mirror.numericUnit ?? null, numericPrecision: mirror.numericPrecision ?? 0,
      folderId: body.folder_id ?? null, tags: body.tags ?? null, imageUrl: body.image_url ?? null,
      sourceUrl: provenance?.url ?? body.source_url ?? null, sourceTitle: provenance?.title ?? body.source_title ?? null,
      sourceSelection: body.source_selection ?? provenance?.selection ?? null, sourceContext: body.source_context ?? provenance?.context ?? null,
      sourceSelector: body.source_selector ?? null, sourceTextOffset: body.source_text_offset ?? null,
      spec, provenance, captureKey: key,
    }).returning();
  } catch (err) {
    // Two captures of the same passage racing: the unique index wins, return the survivor.
    if (key && err instanceof Error && /cards_user_capture_key_idx|23505/.test(err.message)) {
      const [dup] = await db.select().from(schema.cards).where(and(eq(schema.cards.userId, userId), eq(schema.cards.captureKey, key)));
      if (dup) return { row: dup, card: null, existing: true };
    }
    throw err;
  }
  const { card } = await commit(db, [{
    type: 'card.ingest', userId, cardId: row.id,
    spec, provenance, folderId: row.folderId, tags: row.tags ?? [], captureKey: key, imageUrl: row.imageUrl,
  }]);
  return { row: await getCardRow(db, userId, row.id), card, existing: false };
}

export async function patchCard(db: Db, userId: string, id: string, body: PatchCardBody): Promise<CardRow> {
  const row = await getCardRow(db, userId, id);
  await ensureDiary(db, row);
  const current = specOf(row);
  const events: NewEvent[] = [];
  const base = { userId, cardId: id };

  const spec = specFromBody(body, current);
  if (spec) events.push({ ...base, type: 'card.setSpec', spec });
  if (body.folder_id !== undefined) events.push({ ...base, type: 'card.setFolder', folderId: body.folder_id ?? null });
  if (body.tags !== undefined) events.push({ ...base, type: 'card.setTags', tags: body.tags ?? [] });
  if (body.image_url !== undefined) events.push({ ...base, type: 'card.setImage', imageUrl: body.image_url ?? null });
  if (body.provenance !== undefined || body.source_url !== undefined || body.source_title !== undefined) {
    events.push({ ...base, type: 'card.setProvenance', provenance: provenanceFromBody(body, row.provenance) });
  }
  if (events.length === 0) throw new CardError(400, 'No fields to update');
  await commit(db, events);
  return getCardRow(db, userId, id);
}

export async function deleteCard(db: Db, userId: string, id: string): Promise<{ eventId: string }> {
  const row = await getCardRow(db, userId, id);
  await ensureDiary(db, row);
  const { events } = await commit(db, [{ type: 'card.setDeleted', userId, cardId: id, isDeleted: true }]);
  return { eventId: events[0].id };
}

export interface UndoResult { cardId: string; componentId: string | null; undone: string; card: Card }

/**
 * Undo a change by appending its compensating event: the card is rebuilt as it was
 * just before the event, and whatever that event touched is set back to that.
 * Only a card's latest change can be undone, so later changes are never clobbered.
 */
export async function undoEvent(db: Db, userId: string, eventId: string): Promise<UndoResult> {
  const [row] = await db.select().from(schema.cardEvents).where(and(eq(schema.cardEvents.id, eventId), eq(schema.cardEvents.userId, userId)));
  if (!row) throw new CardError(404, 'Event not found');
  const events = await loadEvents(db, row.cardId);
  const target = events.find((e) => e.id === eventId)!;
  const latest = events[events.length - 1];
  if (latest.id !== eventId) throw new CardError(409, 'Only the latest change to a card can be undone');
  if (target.type === 'card.ingest') throw new CardError(400, 'Creating a card cannot be undone; delete it instead');

  const before = rebuild(events.filter((e) => e.id !== eventId));
  if (!before) throw new CardError(500, 'Card has no state before this event');
  const base = { userId, cardId: row.cardId };
  let compensating: NewEvent;
  let componentId: string | null = null;
  switch (target.type) {
    case 'card.review':
    case 'card.reschedule': {
      componentId = target.componentId;
      const state = before.components[componentId];
      if (!state) throw new CardError(409, 'That component no longer exists');
      compensating = { ...base, type: 'card.reschedule', componentId, state };
      if (target.type === 'card.review') {
        // the analytics mirror should forget it too
        await db.delete(schema.reviewLogs).where(and(eq(schema.reviewLogs.cardId, row.cardId), eq(schema.reviewLogs.reviewedAt, target.at)));
      }
      break;
    }
    case 'card.setDeleted': compensating = { ...base, type: 'card.setDeleted', isDeleted: before.isDeleted }; break;
    case 'card.setSpec': compensating = { ...base, type: 'card.setSpec', spec: before.spec }; break;
    case 'card.setFolder': compensating = { ...base, type: 'card.setFolder', folderId: before.folderId }; break;
    case 'card.setTags': compensating = { ...base, type: 'card.setTags', tags: before.tags }; break;
    case 'card.setImage': compensating = { ...base, type: 'card.setImage', imageUrl: before.imageUrl }; break;
    case 'card.setProvenance': compensating = { ...base, type: 'card.setProvenance', provenance: before.provenance }; break;
    default: throw new CardError(400, `Cannot undo ${(target as { type: string }).type}`);
  }
  const { card } = await commit(db, [compensating]);
  if (!card) throw new CardError(500, 'Card vanished during undo');
  return { cardId: row.cardId, componentId, undone: target.type, card };
}

export async function setCardImage(db: Db, userId: string, id: string, imageUrl: string | null): Promise<void> {
  const row = await getCardRow(db, userId, id);
  await ensureDiary(db, row);
  await commit(db, [{ type: 'card.setImage', userId, cardId: id, imageUrl }]);
}

/** Folder rows are deleted with FK set-null; the diary has to say so too. */
export async function unfileCardsOfFolder(db: Db, userId: string, folderId: string): Promise<number> {
  const rows = await db.select().from(schema.cards)
    .where(and(eq(schema.cards.userId, userId), eq(schema.cards.folderId, folderId), eq(schema.cards.isDeleted, false)));
  for (const row of rows) {
    await ensureDiary(db, row);
    await commit(db, [{ type: 'card.setFolder', userId, cardId: row.id, folderId: null }]);
  }
  return rows.length;
}

export interface ReviewResult {
  card: Card;
  componentId: string;
  state: typeof schema.cardReviewState.$inferSelect;
  previous: ComponentState | null;
  previews: Record<Rating, string>;
  eventId: string;
}

export async function reviewCard(
  db: Db, userId: string, cardId: string, rating: Rating,
  opts: { componentId?: string; sessionId?: string | null; responseMs?: number | null } = {},
): Promise<ReviewResult> {
  const row = await getCardRow(db, userId, cardId);
  await ensureDiary(db, row);
  const ids = componentIdsOf(specOf(row));
  const requested = opts.componentId ?? MAIN_COMPONENT;
  // 'main' on a composite card (older clients) means its first component
  const componentId = ids.includes(requested) ? requested : requested === MAIN_COMPONENT ? ids[0] : null;
  if (!componentId) throw new CardError(400, `Unknown component ${requested}`);

  const [prevRow] = await db.select().from(schema.cardReviewState).where(and(
    eq(schema.cardReviewState.cardId, cardId), eq(schema.cardReviewState.userId, userId), eq(schema.cardReviewState.componentId, componentId),
  ));
  const previous: ComponentState | null = prevRow ? {
    status: prevRow.status as ComponentState['status'], dueAt: isoTimestamp(prevRow.dueAt), intervalDays: prevRow.intervalDays,
    easeFactor: prevRow.easeFactor, stepIndex: prevRow.stepIndex ?? 0, reviewCount: prevRow.reviewCount, lapseCount: prevRow.lapseCount,
    streak: prevRow.streak, lastReviewedAt: prevRow.lastReviewedAt ? isoTimestamp(prevRow.lastReviewedAt) : null,
  } : null;

  const { card, events } = await commit(db, [{
    type: 'card.review', userId, cardId, componentId, rating, sessionId: opts.sessionId ?? null, responseMs: opts.responseMs ?? null,
    mechanics: defaultScheduler.mechanics,
  }]);
  if (!card) throw new CardError(500, 'Card vanished during review');
  const [state] = await db.select().from(schema.cardReviewState).where(and(
    eq(schema.cardReviewState.cardId, cardId), eq(schema.cardReviewState.userId, userId), eq(schema.cardReviewState.componentId, componentId),
  ));
  const previews = defaultScheduler.preview(card.components[componentId], new Date());
  return { card, componentId, state, previous, previews, eventId: events[0].id };
}
