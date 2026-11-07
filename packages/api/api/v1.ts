// /api/v1/* — data + auth routes behind one function (Hobby 12-function cap).
//
//   POST   auth/google            { credential, client }  → { token, user }
//   DELETE auth/token                                      → revoke caller's token
//   GET    cards[?source_url_prefix=&source=&folder_id=<uuid>|unfiled&tag=&limit=&offset=] → cards with folder + due_at
//   POST   cards                                           → create
//   PATCH  cards/:id  · DELETE cards/:id
//   GET    folders · POST folders · PATCH folders/:id · DELETE folders/:id
//   GET    review/queue           → { cards, states, new_reviewed_today }
//   GET    review/today           → { review, learn } left for today across the Mix
//   POST   review                 { card_id, rating, new_state } → { state }
//   GET    activity               → { reviews: [...], cards: [...] }
//   POST   images                 { card_id, image_data, mime_type } → { image_url }

import type { VercelRequest, VercelResponse } from '@vercel/node';
import { createHash, createHmac, timingSafeEqual } from 'node:crypto';
import { and, desc, eq, gte, inArray, isNull, like, sql } from 'drizzle-orm';
import { selectSession, todayCounts } from '../lib/mixer.js';
import { OAuth2Client } from 'google-auth-library';
import { del, list, put } from '@vercel/blob';
import { DEFAULT_MECHANICS, MAIN_COMPONENT, SCHEDULER_ID, INTERVAL_CONFIDENCE, createCardBodySchema, forecastWorkload, intervalScoreBodySchema, parseBody, patchCardBodySchema, practiceBodySchema, componentIdsOf, defaultScheduler, difficultyScore, learningCap, gatedNewPerDay, isLeechLapse, STILL_LEARNING_DAYS, rateInterval, reviewSubmitBodySchema, reviewUndoBodySchema } from '@pluckk/core';
import { getDb, schema } from '../lib/db.js';
import { authenticateRequest, isAuthError, issueToken, revokeToken } from '../lib/auth.js';
import { CardError, createCard, deleteCard, patchCard, reviewCard, setCardImage, undoEvent, unfileCardsOfFolder, specOf, getCardRow } from '../lib/cards.js';
import { buildItems, moduleSource, stateFromRow } from '../lib/review.js';
import { commit, loadEvents } from '../lib/store.js';
import { Router, pathSegments, type RouteHandler } from '../lib/router.js';
import { snake, pick, isoTimestamp } from '../lib/serialize.js';

const router = new Router();

/** Wrap a handler so it runs only for authenticated users. */
function authed(fn: (req: VercelRequest, res: VercelResponse, user: schema.User, params: Record<string, string>) => Promise<void>): RouteHandler {
  return async (req, res, params) => {
    const auth = await authenticateRequest(req);
    if (isAuthError(auth)) { res.status(auth.status).json({ error: auth.error }); return; }
    try {
      await fn(req, res, auth.user, params);
    } catch (err) {
      if (err instanceof CardError) { res.status(err.status).json({ error: err.message }); return; }
      throw err;
    }
  };
}

// ---------------------------------------------------------------- auth
const googleClient = new OAuth2Client();
function allowedAudiences(): string[] {
  return (process.env.GOOGLE_CLIENT_IDS || process.env.GOOGLE_CLIENT_ID || '').split(',').map((s) => s.trim()).filter(Boolean);
}

router.on('POST', 'auth/google', async (req, res) => {
  const { credential, client } = (req.body ?? {}) as { credential?: string; client?: string };
  if (!credential) { res.status(400).json({ error: 'credential required' }); return; }
  const audience = allowedAudiences();
  if (audience.length === 0) { res.status(500).json({ error: 'GOOGLE_CLIENT_IDS not configured' }); return; }

  let payload;
  try {
    const ticket = await googleClient.verifyIdToken({ idToken: credential, audience });
    payload = ticket.getPayload();
  } catch (err) {
    res.status(401).json({ error: 'Invalid Google credential', details: err instanceof Error ? err.message : String(err) });
    return;
  }
  if (!payload?.sub || !payload.email) { res.status(401).json({ error: 'Google token missing sub/email' }); return; }

  const db = getDb();
  // Match by google_sub first, then by email (links pre-migration accounts), else create.
  let [user] = await db.select().from(schema.users).where(eq(schema.users.googleSub, payload.sub)).limit(1);
  if (!user) {
    [user] = await db.select().from(schema.users).where(sql`lower(${schema.users.email}) = ${payload.email.toLowerCase()}`).limit(1);
    if (user) {
      [user] = await db.update(schema.users).set({ googleSub: payload.sub }).where(eq(schema.users.id, user.id)).returning();
    } else {
      [user] = await db.insert(schema.users).values({
        email: payload.email, googleSub: payload.sub,
        displayName: payload.name ?? null, avatarUrl: payload.picture ?? null,
      }).returning();
    }
  }
  const token = await issueToken(user.id, client || 'unknown');
  res.status(200).json({ token, user: publicUser(user) });
});

router.on('DELETE', 'auth/token', async (req, res) => {
  const header = req.headers.authorization || '';
  if (header.startsWith('Bearer ')) await revokeToken(header.slice(7).trim());
  res.status(200).json({ success: true });
});

function publicUser(u: schema.User) {
  return { id: u.id, email: u.email, display_name: u.displayName, avatar_url: u.avatarUrl, created_at: u.createdAt };
}

// ---------------------------------------------------------------- cards
/** `folderId` narrows to one deck ('unfiled' = no deck), `tag` to cards carrying that tag;
 *  `page` slices the newest-first list. */
async function listCards(userId: string, sourceUrlPrefix?: string, sourceIdentifier?: string,
                         folderId?: string, page?: { limit: number; offset: number }, tag?: string,
                         state?: 'new' | 'due' | 'seen') {
  const db = getDb();
  const conds = [eq(schema.cards.userId, userId), eq(schema.cards.isDeleted, false)];
  if (sourceUrlPrefix) conds.push(like(schema.cards.sourceUrl, sourceUrlPrefix.replace(/[%_]/g, '\\$&') + '%'));
  // Every card from one source (page, app window, imported deck): provenance.identifier is the clustering key.
  if (sourceIdentifier) conds.push(sql`${schema.cards.provenance}->>'identifier' = ${sourceIdentifier}`);
  if (folderId === 'unfiled') conds.push(isNull(schema.cards.folderId));
  else if (folderId) conds.push(eq(schema.cards.folderId, folderId));
  if (tag) conds.push(sql`${tag} = any(${schema.cards.tags})`);
  // A card has one schedule per component; its "due" is the earliest of them.
  const due = db.select({
    cardId: schema.cardReviewState.cardId,
    dueAt: sql<string>`min(${schema.cardReviewState.dueAt})`.as('due_at'),
    // Reviewed at least once; anything else is new to the person.
    seen: sql<boolean>`bool_or(${schema.cardReviewState.status} <> 'new')`.as('seen'),
    interval: sql<number>`max(${schema.cardReviewState.intervalDays})::float8`.as('interval_days'),   // numeric would arrive as a string
  }).from(schema.cardReviewState).where(eq(schema.cardReviewState.userId, userId)).groupBy(schema.cardReviewState.cardId).as('due');
  // ?state=new (never reviewed), due (reviewed and due now), seen (reviewed at least once).
  if (state === 'new') conds.push(sql`${due.seen} is not true`);
  if (state === 'due') conds.push(sql`${due.seen} is true and ${due.dueAt} <= now()`);
  if (state === 'seen') conds.push(sql`${due.seen} is true`);
  const rows = await db
    .select({ card: schema.cards, folder: schema.folders, dueAt: due.dueAt, seen: due.seen, interval: due.interval })
    .from(schema.cards)
    .leftJoin(schema.folders, eq(schema.cards.folderId, schema.folders.id))
    .leftJoin(due, eq(due.cardId, schema.cards.id))
    .where(and(...conds))
    .orderBy(...(state === 'due' ? [sql`${due.dueAt} asc`] : [desc(schema.cards.createdAt)]))
    .limit(page?.limit ?? Number.MAX_SAFE_INTEGER)
    .offset(page?.offset ?? 0);
  return rows.map((r) => ({
    ...snake<Record<string, unknown>>(r.card), folder: r.folder ? snake(r.folder) : null,
    due_at: r.dueAt ? isoTimestamp(r.dueAt) : null, seen: r.seen === true, interval_days: r.interval ?? null,
  }));
}

router.on('GET', 'cards', authed(async (req, res, user) => {
  const prefix = typeof req.query.source_url_prefix === 'string' ? req.query.source_url_prefix : undefined;
  const source = typeof req.query.source === 'string' ? req.query.source : undefined;
  // Optional: one deck (?folder_id=<uuid>|unfiled), one tag (?tag=), a page (?limit=&offset=, limit ≤ 500).
  const folder = typeof req.query.folder_id === 'string' ? req.query.folder_id : undefined;
  if (folder && folder !== 'unfiled' && !/^[0-9a-f-]{36}$/i.test(folder)) {
    res.status(400).json({ error: 'folder_id must be a uuid or "unfiled"' });
    return;
  }
  const limit = Number(req.query.limit);
  const offset = Number(req.query.offset);
  const page = Number.isInteger(limit) && limit > 0
    ? { limit: Math.min(limit, 500), offset: Number.isInteger(offset) && offset > 0 ? offset : 0 }
    : undefined;
  const tag = typeof req.query.tag === 'string' && req.query.tag ? req.query.tag : undefined;
  const state = ['new', 'due', 'seen'].includes(String(req.query.state)) ? (req.query.state as 'new' | 'due' | 'seen') : undefined;
  res.status(200).json(await listCards(user.id, prefix, source, folder, page, tag, state));
}));

// Creates through the diary (card.ingest). Accepts the new {spec, provenance} form and the
// legacy flat form. A capture_key that matches an existing card returns that card (200, existing: true).
router.on('POST', 'cards', authed(async (req, res, user) => {
  const parsed = parseBody(createCardBodySchema, req.body);
  if (!parsed.ok) { res.status(400).json({ error: parsed.error }); return; }
  const r = await createCard(getDb(), user.id, parsed.data);
  res.status(r.existing ? 200 : 201).json({ ...snake<Record<string, unknown>>(r.row), existing: r.existing });
}));

router.on('GET', 'cards/:id', authed(async (_req, res, user, { id }) => {
  const [row] = await getDb().select().from(schema.cards)
    .where(and(eq(schema.cards.id, id), eq(schema.cards.userId, user.id), eq(schema.cards.isDeleted, false)));
  if (!row) { res.status(404).json({ error: 'Card not found' }); return; }
  res.status(200).json(snake(row));
}));

router.on('PATCH', 'cards/:id', authed(async (req, res, user, { id }) => {
  const parsed = parseBody(patchCardBodySchema, req.body);
  if (!parsed.ok) { res.status(400).json({ error: parsed.error }); return; }
  const row = await patchCard(getDb(), user.id, id, parsed.data);
  const folder = row.folderId ? (await getDb().select().from(schema.folders).where(eq(schema.folders.id, row.folderId)))[0] ?? null : null;
  res.status(200).json({ ...snake<Record<string, unknown>>(row), folder: folder ? snake(folder) : null });
}));

// Soft delete (card.setDeleted). The row and its diary stay; every read filters is_deleted.
// The event id lets the client offer Undo.
router.on('DELETE', 'cards/:id', authed(async (_req, res, user, { id }) => {
  const { eventId } = await deleteCard(getDb(), user.id, id);
  res.status(200).json({ success: true, event_id: eventId });
}));

// The diary of one card, newest first (includes deleted cards — that is the point).
router.on('GET', 'cards/:id/events', authed(async (_req, res, user, { id }) => {
  const db = getDb();
  const [row] = await db.select({ id: schema.cards.id }).from(schema.cards).where(and(eq(schema.cards.id, id), eq(schema.cards.userId, user.id)));
  if (!row) { res.status(404).json({ error: 'Card not found' }); return; }
  const events = (await loadEvents(db, id)).reverse();
  res.status(200).json({ events: events.map((e) => ({ ...snake<Record<string, unknown>>(e), at: e.at })) });
}));

// ---------------------------------------------------------------- folders
const FOLDER_FIELDS = ['name', 'color', 'sortOrder', 'weight', 'isPaused', 'newPerDay'] as const;

router.on('GET', 'folders', authed(async (_req, res, user) => {
  const rows = await getDb().select().from(schema.folders).where(eq(schema.folders.userId, user.id))
    .orderBy(schema.folders.sortOrder, schema.folders.name);
  res.status(200).json(snake(rows));
}));

router.on('POST', 'folders', authed(async (req, res, user) => {
  const values = pick<typeof schema.folders.$inferInsert>(req.body, FOLDER_FIELDS);
  if (!values.name?.trim()) { res.status(400).json({ error: 'name required' }); return; }
  const [row] = await getDb().insert(schema.folders).values({ ...values, name: values.name.trim(), userId: user.id }).returning();
  res.status(201).json(snake(row));
}));

router.on('PATCH', 'folders/:id', authed(async (req, res, user, { id }) => {
  const values = pick<typeof schema.folders.$inferInsert>(req.body, FOLDER_FIELDS);
  const [row] = await getDb().update(schema.folders).set(values)
    .where(and(eq(schema.folders.id, id), eq(schema.folders.userId, user.id))).returning();
  if (!row) { res.status(404).json({ error: 'Folder not found' }); return; }
  res.status(200).json(snake(row));
}));

router.on('DELETE', 'folders/:id', authed(async (_req, res, user, { id }) => {
  await unfileCardsOfFolder(getDb(), user.id, id);  // the diary records the un-filing; the FK set-null would not
  const rows = await getDb().delete(schema.folders).where(and(eq(schema.folders.id, id), eq(schema.folders.userId, user.id))).returning({ id: schema.folders.id });
  if (rows.length === 0) { res.status(404).json({ error: 'Folder not found' }); return; }
  res.status(200).json({ success: true });
}));

// ---------------------------------------------------------------- review
router.on('GET', 'review/queue', authed(async (_req, res, user) => {
  const db = getDb();
  const cards = await listCards(user.id);
  const states = await db.select().from(schema.cardReviewState).where(eq(schema.cardReviewState.userId, user.id));
  const todayStart = new Date(); todayStart.setHours(0, 0, 0, 0);
  const logs = await db.selectDistinct({ cardId: schema.reviewLogs.cardId }).from(schema.reviewLogs)
    .where(and(eq(schema.reviewLogs.userId, user.id), gte(schema.reviewLogs.reviewedAt, todayStart.toISOString()), eq(schema.reviewLogs.previousStatus, 'new')));
  res.status(200).json({ cards, states: snake(states), new_reviewed_today: logs.map((l) => l.cardId) });
}));

// The server schedules (card.review → reducer → scheduler). `new_state` from older clients is
// accepted and ignored. review_logs stays as an analytics mirror until step 8.
/** A number card's answer and unit, or null when the card isn't one. */
async function numericAnswer(userId: string, cardId: string) {
  const spec = specOf(await getCardRow(getDb(), userId, cardId));
  if (!('answerType' in spec) || spec.answerType !== 'numeric' || spec.numeric?.value == null) return null;
  return { value: spec.numeric.value, unit: spec.numeric.unit ?? null };
}

router.on('POST', 'review/score', authed(async (req, res, user) => {
  const parsed = parseBody(intervalScoreBodySchema, req.body);
  if (!parsed.ok) { res.status(400).json({ error: parsed.error }); return; }
  const answer = await numericAnswer(user.id, parsed.data.card_id);
  if (!answer) { res.status(400).json({ error: 'Not a number card' }); return; }
  const outcome = rateInterval(answer.value, parsed.data.interval.lower, parsed.data.interval.upper, answer.unit);
  res.status(200).json({ ...snake<Record<string, unknown>>(outcome), answer: answer.value, unit: answer.unit });
}));

router.on('POST', 'review', authed(async (req, res, user) => {
  const parsed = parseBody(reviewSubmitBodySchema, req.body);
  if (!parsed.ok) { res.status(400).json({ error: parsed.error }); return; }
  const body = parsed.data;
  const db = getDb();
  // A range is scored against the card's number; an explicit rating overrides the score.
  const answer = body.interval ? await numericAnswer(user.id, body.card_id) : null;
  if (body.interval && !answer) { res.status(400).json({ error: 'Not a number card' }); return; }
  const outcome = body.interval && answer ? rateInterval(answer.value, body.interval.lower, body.interval.upper, answer.unit) : null;
  const rating = body.rating ?? outcome?.rating;
  if (!rating) { res.status(400).json({ error: 'rating or interval required' }); return; }
  if (body.practice) {
    res.status(200).json(await practiseCard(db, user.id, body.card_id, body.component_id ?? MAIN_COMPONENT, rating, body.response_time_ms ?? null));
    return;
  }
  const r = await reviewCard(db, user.id, body.card_id, rating, {
    componentId: body.component_id ?? MAIN_COMPONENT, sessionId: body.session_id ?? null, responseMs: body.response_time_ms ?? null,
  });
  await db.insert(schema.reviewLogs).values({
    cardReviewStateId: r.state.id, userId: user.id, cardId: body.card_id, reviewMode: outcome ? 'numeric_interval' : 'standard', rating,
    responseTimeMs: body.response_time_ms ?? null,
    ...(outcome && answer ? {
      responseLower: outcome.lower, responseUpper: outcome.upper, correctAnswer: answer.value, containedAnswer: outcome.contained,
      intervalWidth: outcome.upper - outcome.lower, relativeWidth: outcome.relativeWidth, confidenceLevelUsed: INTERVAL_CONFIDENCE,
      derivedRating: outcome.rating,
    } : {}),
    previousStatus: r.previous?.status ?? 'new', previousInterval: r.previous?.intervalDays ?? 0, previousEase: r.previous?.easeFactor ?? 2.5,
    previousDue: r.previous?.dueAt ?? null,
    newStatus: r.state.status, newInterval: r.state.intervalDays, newEase: r.state.easeFactor, newDue: r.state.dueAt,
    algorithmVersion: `core:${SCHEDULER_ID}`,
    reviewedAt: r.state.lastReviewedAt ?? new Date().toISOString(),
  });
  // A card forgotten again and again is a leech: flag it (tag 'leech') so it gets reworked
  // rather than drilled. Every second lapse from the fourth.
  let leech = false;
  if (isLeechLapse(r.previous?.lapseCount ?? 0, r.state.lapseCount) && !r.card.tags.includes('leech')) {
    await patchCard(db, user.id, body.card_id, { tags: [...r.card.tags, 'leech'] });
    leech = true;
  }
  res.status(200).json({ state: snake(r.state), component_id: r.componentId, previews: r.previews, event_id: r.eventId, rating, leech, lapses: r.state.lapseCount });
}));

// Practice outside the schedule. The rating is logged (review_mode 'practice') but the card keeps
// its due date, so rehearsing a deck early doesn't push it weeks out. The one exception: "again"
// on a card due later than tomorrow brings it back tomorrow. New cards stay new.
async function practiseCard(db: ReturnType<typeof getDb>, userId: string, cardId: string, componentId: string, rating: string, responseMs: number | null) {
  const row = await getCardRow(db, userId, cardId);
  const ids = componentIdsOf(specOf(row));
  const component = ids.includes(componentId) ? componentId : ids[0];
  const [stateRow] = await db.select().from(schema.cardReviewState).where(and(
    eq(schema.cardReviewState.cardId, cardId), eq(schema.cardReviewState.userId, userId), eq(schema.cardReviewState.componentId, component)));
  const now = new Date();
  let eventId: string | null = null;
  if (stateRow && stateRow.status !== 'new') {
    const state = stateFromRow(stateRow);
    const tomorrow = new Date(now.getTime() + 86400000);
    if (rating === 'again' && new Date(state.dueAt) > tomorrow) {
      const { events } = await commit(db, [{ type: 'card.reschedule', userId, cardId, componentId: component, state: { ...state, dueAt: tomorrow.toISOString() } }]);
      eventId = events[0]?.id ?? null;
    }
    await db.insert(schema.reviewLogs).values({
      cardReviewStateId: stateRow.id, userId, cardId, reviewMode: 'practice', rating, responseTimeMs: responseMs,
      previousStatus: state.status, previousInterval: state.intervalDays, previousEase: state.easeFactor, previousDue: state.dueAt,
      newStatus: state.status, newInterval: state.intervalDays, newEase: state.easeFactor,
      newDue: eventId ? tomorrow.toISOString() : state.dueAt,
      algorithmVersion: `core:${SCHEDULER_ID}:practice`, reviewedAt: now.toISOString(),
    });
  }
  const state = stateRow ? stateFromRow(stateRow) : defaultScheduler.initial(now);
  return { practice: true, component_id: component, event_id: eventId, rating, previews: defaultScheduler.preview(state, now) };
}

router.on('POST', 'review/practice', authed(async (req, res, user) => {
  const parsed = parseBody(practiceBodySchema, req.body);
  if (!parsed.ok) { res.status(400).json({ error: parsed.error }); return; }
  const body = parsed.data;
  const db = getDb();
  const conds = [eq(schema.cards.userId, user.id), eq(schema.cards.isDeleted, false)];
  if (body.card_ids?.length) conds.push(inArray(schema.cards.id, body.card_ids));
  if (body.folder_id !== undefined) conds.push(body.folder_id === null ? isNull(schema.cards.folderId) : eq(schema.cards.folderId, body.folder_id));
  let rows = await db.select().from(schema.cards).where(and(...conds));
  const filter = body.filter ?? 'all';
  if (filter !== 'all' && rows.length) {
    const ids = rows.map((r) => r.id);
    const keep = new Set<string>();
    if (filter === 'learned') {
      const s = await db.select({ cardId: schema.cardReviewState.cardId }).from(schema.cardReviewState)
        .where(and(eq(schema.cardReviewState.userId, user.id), inArray(schema.cardReviewState.cardId, ids), sql`${schema.cardReviewState.status} <> 'new'`));
      s.forEach((x) => keep.add(x.cardId));
    } else {
      const since = new Date(Date.now() - 30 * 86400000).toISOString();
      const s = await db.select({ cardId: schema.reviewLogs.cardId }).from(schema.reviewLogs)
        .where(and(eq(schema.reviewLogs.userId, user.id), inArray(schema.reviewLogs.cardId, ids),
          inArray(schema.reviewLogs.rating, ['again', 'hard']), gte(schema.reviewLogs.reviewedAt, since)));
      s.forEach((x) => keep.add(x.cardId));
    }
    rows = rows.filter((r) => keep.has(r.id));
  }
  // Chosen cards keep the order they were picked in; a deck is shuffled.
  if (body.card_ids?.length) {
    const order = new Map(body.card_ids.map((id, i) => [id, i]));
    rows.sort((a, b) => order.get(a.id)! - order.get(b.id)!);
  } else {
    for (let i = rows.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [rows[i], rows[j]] = [rows[j], rows[i]]; }
  }
  const dealt = rows.flatMap((r) => componentIdsOf(specOf(r)).map((componentId) => ({ cardId: r.id, componentId })))
    .slice(0, body.size ?? 200);
  res.status(200).json({ items: await buildItems(db, user.id, dealt) });
}));

// The coming workload, day by day: reviews of cards seen before today, reviews of cards still to
// come, and new cards. Assumes every review is rated Good and new cards arrive at each deck's
// daily limit. ?days=1–365, ?tz=minutes east of UTC so days start at the person's midnight.
router.on('GET', 'review/forecast', authed(async (req, res, user) => {
  const days = Math.max(1, Math.min(365, Number(req.query?.days ?? 60) || 60));
  const tz = Number(req.query?.tz ?? 0) || 0;
  const now = new Date();
  const local = now.getTime() + tz * 60000;
  const start = new Date(local - (local % 86400000) - tz * 60000);
  const db = getDb();
  const settings = await getStudySettings(user.id);
  const { folderRows, candidateRows, newToday } = await mixerContext(user.id);
  const paused = new Set(folderRows.filter((f) => f.isPaused).map((f) => f.id));
  const active = (f: string | null) => !(f && paused.has(f));

  const rows = await db.select({ state: schema.cardReviewState, folderId: schema.cards.folderId })
    .from(schema.cardReviewState)
    .innerJoin(schema.cards, eq(schema.cards.id, schema.cardReviewState.cardId))
    .where(and(eq(schema.cardReviewState.userId, user.id), eq(schema.cards.isDeleted, false)));
  const states = rows.filter((r) => r.state.status !== 'new' && active(r.folderId)).map((r) => stateFromRow(r.state));

  const unseen = new Map<string | null, number>();
  for (const c of candidateRows) {
    if ((!c.status || c.status === 'new') && active(c.folderId)) unseen.set(c.folderId, (unseen.get(c.folderId) ?? 0) + 1);
  }
  const decks = [...unseen].map(([f, count]) => ({
    unseen: count,
    perDay: (f ? folderRows.find((x) => x.id === f)?.newPerDay : null) ?? settings.newCardsPerDay ?? DEFAULT_NEW_PER_DAY,
    usedToday: newToday.get(f) ?? 0,
  }));

  const forecast = forecastWorkload({ states, decks, days, start, now });
  res.status(200).json({
    start: start.toISOString(),
    days: forecast.map((d) => ({ date: new Date(start.getTime() + d.day * 86400000).toISOString(), reviews: d.reviews, learned: d.learned, new: d.newCards })),
  });
}));

// How often number-card ranges caught the answer: the 95% ranges should catch about 95%.
router.on('GET', 'review/calibration', authed(async (_req, res, user) => {
  const r = await getDb().execute(sql`
    select count(*)::int as reviews, count(*) filter (where contained_answer)::int as caught
    from review_logs where user_id = ${user.id} and review_mode = 'numeric_interval'`);
  const row = (r.rows[0] ?? { reviews: 0, caught: 0 }) as { reviews: number; caught: number };
  res.status(200).json({ ...row, confidence: INTERVAL_CONFIDENCE });
}));

// ---------------------------------------------------------------- review mixer
const DEFAULT_SESSION_SIZE = 100;
const DEFAULT_NEW_PER_DAY = 10;

async function getStudySettings(userId: string) {
  const db = getDb();
  const [row] = await db.select().from(schema.userStudySettings).where(eq(schema.userStudySettings.userId, userId));
  if (row) return row;
  const [created] = await db.insert(schema.userStudySettings).values({ userId }).onConflictDoNothing().returning();
  return created ?? (await db.select().from(schema.userStudySettings).where(eq(schema.userStudySettings.userId, userId)))[0];
}

// Per-deck review summary for the Focused Review page (includes paused + unfiled).
router.on('GET', 'review/decks', authed(async (_req, res, user) => {
  const r = await getDb().execute(sql`
    select c.folder_id, f.name, coalesce(f.is_paused, false) as is_paused, f.new_per_day,
           count(distinct c.id)::int as total,
           count(distinct c.id) filter (where s.id is null or s.status = 'new')::int as new,
           count(distinct c.id) filter (where s.due_at <= now() + make_interval(hours => ${DEFAULT_MECHANICS.dueLookaheadHours}) and s.status <> 'new')::int as due
    from cards c
    left join folders f on f.id = c.folder_id
    left join card_review_state s on s.card_id = c.id and s.user_id = c.user_id
    where c.user_id = ${user.id} and c.is_deleted = false
    group by c.folder_id, f.name, f.is_paused, f.new_per_day
    order by f.name nulls last`);
  const settings = await getStudySettings(user.id);
  const gate = await deckGates(user.id);
  const decks = (r.rows as Array<{ folder_id: string | null; new_per_day: number | null }>).map((row) => {
    const g = gate(row.folder_id, row.new_per_day ?? settings.newCardsPerDay ?? DEFAULT_NEW_PER_DAY);
    return { ...row, difficulty: g.score, still_learning: g.stillLearning, learning_cap: g.cap };
  });
  res.status(200).json({ decks });
}));

router.on('GET', 'review/settings', authed(async (_req, res, user) => {
  const s = await getStudySettings(user.id);
  res.status(200).json({
    session_size: s.sessionSize ?? DEFAULT_SESSION_SIZE,
    new_cards_per_day: s.newCardsPerDay ?? DEFAULT_NEW_PER_DAY,
  });
}));

router.on('PATCH', 'review/settings', authed(async (req, res, user) => {
  const body = (req.body ?? {}) as { session_size?: number; new_cards_per_day?: number };
  await getStudySettings(user.id);
  const set: Record<string, number> = {};
  if (Number.isFinite(body.session_size)) set.sessionSize = Math.max(1, Math.min(1000, Math.floor(body.session_size!)));
  if (Number.isFinite(body.new_cards_per_day)) set.newCardsPerDay = Math.max(0, Math.min(500, Math.floor(body.new_cards_per_day!)));
  if (Object.keys(set).length === 0) { res.status(400).json({ error: 'Nothing to update' }); return; }
  await getDb().update(schema.userStudySettings).set(set).where(eq(schema.userStudySettings.userId, user.id));
  res.status(200).json({ success: true });
}));

/** What the mixer needs: this user's decks, candidate components, and new cards introduced today. */
/**
 * Each deck's difficulty (0–100, from the last 90 days of ratings), how many of its cards are
 * still being learned (seen, next review under STILL_LEARNING_DAYS away), and the cap that follows.
 */
async function deckGates(userId: string) {
  const db = getDb();
  const since = new Date(Date.now() - 90 * 86400000).toISOString();
  const logs = await db.execute(sql`
    select c.folder_id, l.rating, l.reviewed_at
    from review_logs l join cards c on c.id = l.card_id
    where l.user_id = ${userId} and l.reviewed_at >= ${since} and c.is_deleted = false`);
  const ratings = new Map<string | null, Array<{ rating: string; at: string }>>();
  for (const r of logs.rows as Array<{ folder_id: string | null; rating: string; reviewed_at: string | Date }>) {
    const list = ratings.get(r.folder_id) ?? [];
    list.push({ rating: r.rating, at: new Date(r.reviewed_at).toISOString() });
    ratings.set(r.folder_id, list);
  }
  const learning = await db.execute(sql`
    select c.folder_id, count(distinct c.id)::int as n
    from cards c join card_review_state s on s.card_id = c.id and s.user_id = c.user_id
    where c.user_id = ${userId} and c.is_deleted = false
      and (s.status in ('learning', 'relearning') or (s.status = 'review' and s.interval_days < ${STILL_LEARNING_DAYS}))
    group by c.folder_id`);
  const stillLearning = new Map<string | null, number>();
  for (const r of learning.rows as Array<{ folder_id: string | null; n: number }>) stillLearning.set(r.folder_id, r.n);
  const now = new Date();
  return (folderId: string | null, dailyLimit: number) => {
    const score = difficultyScore(ratings.get(folderId) ?? [], now);
    const cap = learningCap(score, dailyLimit);
    return { score, cap, stillLearning: stillLearning.get(folderId) ?? 0 };
  };
}

async function mixerContext(userId: string) {
  const db = getDb();
  const settings = await getStudySettings(userId);
  const defaultLimit = settings.newCardsPerDay ?? DEFAULT_NEW_PER_DAY;
  const gate = await deckGates(userId);

  // Slim candidate rows, one per component: id, component, folder, created, state status/due.
  // A card with no state rows yet is its single 'main' component, new.
  const candidateRows = (await db.select({
    cardId: schema.cards.id, componentId: schema.cardReviewState.componentId, folderId: schema.cards.folderId, createdAt: schema.cards.createdAt,
    status: schema.cardReviewState.status, dueAt: schema.cardReviewState.dueAt,
  }).from(schema.cards)
    .leftJoin(schema.cardReviewState, and(eq(schema.cardReviewState.cardId, schema.cards.id), eq(schema.cardReviewState.userId, userId)))
    .where(and(eq(schema.cards.userId, userId), eq(schema.cards.isDeleted, false))))
    .map((r) => ({ ...r, componentId: r.componentId ?? MAIN_COMPONENT }));

  // New cards already introduced today, per folder.
  const todayStart = new Date(); todayStart.setHours(0, 0, 0, 0);
  const introduced = await db.execute(sql`
    select c.folder_id, count(distinct l.card_id)::int as n
    from review_logs l join cards c on c.id = l.card_id
    where l.user_id = ${userId} and l.previous_status = 'new' and l.reviewed_at >= ${todayStart.toISOString()}
    group by c.folder_id`);
  const newToday = new Map<string | null, number>();
  for (const r of introduced.rows as Array<{ folder_id: string | null; n: number }>) newToday.set(r.folder_id, r.n);

  // A hard deck with too many cards still being learned gets fewer new ones (or none) today.
  const folderRows = (await db.select({
    id: schema.folders.id, weight: schema.folders.weight, isPaused: schema.folders.isPaused, newPerDay: schema.folders.newPerDay,
  }).from(schema.folders).where(eq(schema.folders.userId, userId))).map((f) => {
    const limit = f.newPerDay ?? defaultLimit;
    const g = gate(f.id, limit);
    return { ...f, newPerDay: gatedNewPerDay(limit, newToday.get(f.id) ?? 0, g.cap, g.stillLearning) };
  });

  return { folderRows, candidateRows, newToday };
}

// What's left for today across the Mix: { review, learn }. Same rules as a scheduled session.
router.on('GET', 'review/today', authed(async (_req, res, user) => {
  const settings = await getStudySettings(user.id);
  const { folderRows, candidateRows, newToday } = await mixerContext(user.id);
  res.status(200).json(todayCounts({
    folders: folderRows, candidates: candidateRows, newReviewedTodayByFolder: newToday,
    defaultNewPerDay: settings.newCardsPerDay ?? DEFAULT_NEW_PER_DAY,
  }));
}));

router.on('POST', 'review/session', authed(async (req, res, user) => {
  const body = (req.body ?? {}) as {
    mode?: 'scheduled' | 'focus' | 'backlog' | 'ahead';
    size?: number;
    folder_id?: string | null;
    mix?: Array<{ folder_id: string | null; pct: number }>;
  };
  const mode = body.mode ?? 'scheduled';
  if ((mode === 'focus' || mode === 'backlog') && body.folder_id === undefined) {
    res.status(400).json({ error: `${mode} mode requires folder_id (null for unfiled)` });
    return;
  }
  const db = getDb();
  const settings = await getStudySettings(user.id);
  const size = Math.max(1, Math.min(1000, Math.floor(body.size ?? settings.sessionSize ?? DEFAULT_SESSION_SIZE)));

  const { folderRows, candidateRows, newToday } = await mixerContext(user.id);

  const result = selectSession({
    mode, size,
    folderId: body.folder_id,
    mix: body.mix?.map((m) => ({ folderId: m.folder_id, pct: m.pct })),
    folders: folderRows,
    candidates: candidateRows,
    newReviewedTodayByFolder: newToday,
    defaultNewPerDay: settings.newCardsPerDay ?? DEFAULT_NEW_PER_DAY,
  });

  // Full rows for only the dealt cards, preserving deal order.
  let cards: unknown[] = [];
  let states: unknown[] = [];
  if (result.dealtIds.length > 0) {
    const all = await listCards(user.id);
    const orderMap = new Map(result.dealtIds.map((id, i) => [id, i]));
    cards = (all as unknown as Array<{ id: string }>).filter((c) => orderMap.has(c.id)).sort((a, b) => orderMap.get(a.id)! - orderMap.get(b.id)!);
    states = snake(await db.select().from(schema.cardReviewState)
      .where(and(eq(schema.cardReviewState.userId, user.id), inArray(schema.cardReviewState.cardId, result.dealtIds)))) as unknown[];
  }
  // items: one entry per dealt component, rendered for that component, with its state and previews.
  const items = await buildItems(db, user.id, result.dealt);
  res.status(200).json({ cards, states, dealt: snake(result.dealt), items, meta: result.meta });
}));

// Undo the latest change to a card (a rating, a delete, an edit…) by its event id.
router.on('POST', 'review/undo', authed(async (req, res, user) => {
  const parsed = parseBody(reviewUndoBodySchema, req.body);
  if (!parsed.ok) { res.status(400).json({ error: parsed.error }); return; }
  const db = getDb();
  const r = await undoEvent(db, user.id, parsed.data.event_id);
  const items = r.componentId && !r.card.isDeleted ? await buildItems(db, user.id, [{ cardId: r.cardId, componentId: r.componentId }]) : [];
  res.status(200).json({ card_id: r.cardId, component_id: r.componentId, undone: r.undone, is_deleted: r.card.isDeleted, item: items[0] ?? null });
}));

// Fresh items for a saved session (the webapp restores by card+component ids).
router.on('POST', 'review/items', authed(async (req, res, user) => {
  const body = (req.body ?? {}) as { items?: Array<{ card_id?: string; component_id?: string }> };
  const wanted = (body.items ?? []).filter((i) => typeof i.card_id === 'string')
    .map((i) => ({ cardId: i.card_id!, componentId: i.component_id ?? MAIN_COMPONENT }));
  res.status(200).json({ items: await buildItems(getDb(), user.id, wanted) });
}));

// ---------------------------------------------------------------- activity
export async function activityFor(userId: string, sinceDate: string) {
  const db = getDb();
  const reviews = await db.execute(sql`
    select date(reviewed_at) as review_date, count(*)::int as total_reviews
    from review_logs where user_id = ${userId} and reviewed_at >= ${sinceDate}
    group by 1 order by 1`);
  const created = await db.execute(sql`
    select date(created_at) as created_date, count(*)::int as cards_created
    from cards where user_id = ${userId} and created_at >= ${sinceDate}
    group by 1 order by 1`);
  return { reviews: reviews.rows, cards: created.rows };
}

router.on('GET', 'activity', authed(async (_req, res, user) => {
  const since = new Date(); since.setDate(since.getDate() - 365);
  res.status(200).json(await activityFor(user.id, since.toISOString().slice(0, 10)));
}));

// ---------------------------------------------------------------- images
router.on('POST', 'images', authed(async (req, res, user) => {
  const { card_id, image_data, mime_type } = (req.body ?? {}) as { card_id?: string; image_data?: string; mime_type?: string };
  if (!card_id || !image_data || !mime_type) { res.status(400).json({ error: 'card_id, image_data, mime_type required' }); return; }
  const db = getDb();
  const [card] = await db.select({ id: schema.cards.id }).from(schema.cards).where(and(eq(schema.cards.id, card_id), eq(schema.cards.userId, user.id)));
  if (!card) { res.status(404).json({ error: 'Card not found' }); return; }
  const ext = mime_type.includes('png') ? 'png' : 'jpg';
  const blob = await put(`card-images/${card_id}.${ext}`, Buffer.from(image_data, 'base64'), {
    access: 'public', contentType: mime_type, addRandomSuffix: false, allowOverwrite: true,
    token: process.env.BLOB_READ_WRITE_TOKEN,
  });
  await setCardImage(db, user.id, card_id, blob.url);  // card.setImage in the diary
  res.status(200).json({ image_url: blob.url });
}));

// ---------------------------------------------------------------- card modules
// Built-in modules live in public/modules (their manifests indexed in public/modules/index.json).
// A user's own modules, written by them or their assistant, live in Blob storage:
//   user-modules/<user id>/<slug>/<draft | 1 | 2 …>/{index.html, manifest.json}
// A draft can be previewed; publishing freezes it as the next numbered version, which cards use
// as "me/<slug>@<n>". Pages are served from /um/… on this origin under a strict content policy.

const SLUG = /^[a-z0-9][a-z0-9-]{1,39}$/;
const MAX_HTML = 600_000;
const blobToken = () => process.env.BLOB_READ_WRITE_TOKEN;
const modulePrefix = (userId: string, slug?: string) => `user-modules/${userId}/${slug ? `${slug}/` : ''}`;

interface ModuleManifest { describe: string; slots: string[]; props?: unknown; samples?: Array<{ slot: string; props?: unknown }> }

function checkManifest(m: unknown): ModuleManifest | string {
  const o = m as Partial<ModuleManifest> | null;
  if (!o || typeof o !== 'object') return 'manifest must be an object';
  if (typeof o.describe !== 'string' || o.describe.length < 10) return 'manifest.describe: say in a sentence or two what the module shows and which props it takes';
  if (!Array.isArray(o.slots) || !o.slots.length || !o.slots.every((s) => ['prompt', 'respond', 'reveal'].includes(s))) return 'manifest.slots: any of prompt, respond, reveal';
  return o as ModuleManifest;
}

async function moduleFiles(userId: string, slug?: string) {
  const out: Array<{ pathname: string; url: string; uploadedAt: Date }> = [];
  let cursor: string | undefined;
  do {
    const page = await list({ prefix: modulePrefix(userId, slug), cursor, limit: 1000, token: blobToken() });
    out.push(...page.blobs.map((b) => ({ pathname: b.pathname, url: b.url, uploadedAt: b.uploadedAt })));
    cursor = page.hasMore ? page.cursor : undefined;
  } while (cursor);
  return out;
}

async function fetchText(url: string): Promise<string | null> {
  const r = await fetch(url, { cache: 'no-store' });
  return r.ok ? r.text() : null;
}

/** The user's modules: slug → versions, whether there's a draft, and the newest manifest. */
async function myModules(userId: string) {
  const files = await moduleFiles(userId);
  const by = new Map<string, { versions: number[]; draft: boolean; manifestUrl?: string; best: number }>();
  for (const f of files) {
    const [, , slug, ver, name] = f.pathname.split('/');
    if (!slug || !ver) continue;
    const e = by.get(slug) ?? { versions: [], draft: false, best: -1 };
    const n = ver === 'draft' ? 0 : Number(ver);
    if (name === 'index.html') { if (ver === 'draft') e.draft = true; else if (Number.isInteger(n)) e.versions.push(n); }
    if (name === 'manifest.json' && n >= e.best) { e.best = n; e.manifestUrl = f.url; }
    by.set(slug, e);
  }
  return by;
}

router.on('GET', 'modules', authed(async (req, res, user) => {
  const host = req.headers['x-forwarded-host'] ?? req.headers.host;
  let builtIn: unknown[] = [];
  try { builtIn = ((await (await fetch(`https://${host}/modules/index.json`)).json()) as { modules: unknown[] }).modules; } catch { /* listed below anyway */ }
  const mine = await myModules(user.id);
  const own = await Promise.all([...mine.entries()].map(async ([slug, e]) => {
    const manifest = e.manifestUrl ? JSON.parse((await fetchText(e.manifestUrl)) ?? '{}') : {};
    const latest = e.versions.length ? Math.max(...e.versions) : null;
    return { use: latest ? `me/${slug}@${latest}` : null, slug, owner: 'mine', versions: e.versions.sort((a, b) => a - b), has_draft: e.draft, ...manifest };
  }));
  // Where this user's own modules are served: me/<slug>@<n> → <base>/<slug>/<n>/index.html.
  res.status(200).json({ modules: [...builtIn, ...own], user_module_base: `/um/${user.id}` });
}));

router.on('GET', 'modules/mine/:slug', authed(async (_req, res, user, { slug }) => {
  if (!SLUG.test(slug)) { res.status(400).json({ error: 'Bad module name' }); return; }
  const e = (await myModules(user.id)).get(slug);
  if (!e) { res.status(404).json({ error: 'No module with that name' }); return; }
  const ver = e.draft ? 'draft' : String(Math.max(...e.versions));
  const files = await moduleFiles(user.id, slug);
  const file = (name: string) => files.find((f) => f.pathname === `${modulePrefix(user.id, slug)}${ver}/${name}`);
  const html = file('index.html') ? await fetchText(file('index.html')!.url) : null;
  const manifest = file('manifest.json') ? JSON.parse((await fetchText(file('manifest.json')!.url)) ?? '{}') : null;
  res.status(200).json({ slug, showing: ver, versions: e.versions.sort((a, b) => a - b), has_draft: e.draft, manifest, html });
}));

// Save (or replace) the draft.
router.on('POST', 'modules/mine/:slug', authed(async (req, res, user, { slug }) => {
  if (!SLUG.test(slug)) { res.status(400).json({ error: 'Module names are 2–40 lowercase letters, digits and dashes' }); return; }
  const { html, manifest } = (req.body ?? {}) as { html?: string; manifest?: unknown };
  if (typeof html !== 'string' || !html.includes('<')) { res.status(400).json({ error: 'html (the page) is required' }); return; }
  if (html.length > MAX_HTML) { res.status(400).json({ error: `The page is over ${MAX_HTML} characters; load big libraries from a CDN instead` }); return; }
  const checked = checkManifest(manifest);
  if (typeof checked === 'string') { res.status(400).json({ error: checked }); return; }
  const base = `${modulePrefix(user.id, slug)}draft/`;
  const opts = { access: 'public' as const, addRandomSuffix: false, allowOverwrite: true, token: blobToken(), cacheControlMaxAge: 0 };
  await put(`${base}index.html`, html, { ...opts, contentType: 'text/html; charset=utf-8' });
  await put(`${base}manifest.json`, JSON.stringify({ ...checked, id: `me/${slug}` }), { ...opts, contentType: 'application/json' });
  res.status(200).json({ slug, use: `me/${slug}@draft`, src: `/um/${user.id}/${slug}/draft/index.html` });
}));

// Remove a module (its draft and every version). Cards still naming it fall back to their text.
router.on('DELETE', 'modules/mine/:slug', authed(async (_req, res, user, { slug }) => {
  if (!SLUG.test(slug)) { res.status(400).json({ error: 'Bad module name' }); return; }
  const files = await moduleFiles(user.id, slug);
  if (files.length) await del(files.map((f) => f.url), { token: blobToken() });
  res.status(200).json({ deleted: files.length });
}));

// Freeze the draft as the next version.
router.on('POST', 'modules/mine/:slug/publish', authed(async (_req, res, user, { slug }) => {
  if (!SLUG.test(slug)) { res.status(400).json({ error: 'Bad module name' }); return; }
  const e = (await myModules(user.id)).get(slug);
  if (!e?.draft) { res.status(404).json({ error: 'There is no draft to publish' }); return; }
  const files = await moduleFiles(user.id, slug);
  const next = (e.versions.length ? Math.max(...e.versions) : 0) + 1;
  const opts = { access: 'public' as const, addRandomSuffix: false, allowOverwrite: false, token: blobToken() };
  for (const name of ['index.html', 'manifest.json']) {
    const f = files.find((x) => x.pathname === `${modulePrefix(user.id, slug)}draft/${name}`);
    const body = f ? await fetchText(f.url) : null;
    if (body == null) { res.status(500).json({ error: `Couldn't read the draft's ${name}` }); return; }
    await put(`${modulePrefix(user.id, slug)}${next}/${name}`, body, {
      ...opts, contentType: name.endsWith('.html') ? 'text/html; charset=utf-8' : 'application/json',
    });
  }
  res.status(200).json({ slug, version: next, use: `me/${slug}@${next}`, src: moduleSource(`me/${slug}@${next}`, user.id) });
}));

// The page of a user's module, unauthenticated (the module host loads it in a web view), under a
// content policy: same-origin plus the big public CDNs for libraries, nothing it can post to.
const USER_MODULE_CSP = [
  "default-src 'self'",
  "script-src 'self' 'unsafe-inline' 'unsafe-eval' 'wasm-unsafe-eval' https://cdn.jsdelivr.net https://cdnjs.cloudflare.com https://unpkg.com",
  "style-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net https://cdnjs.cloudflare.com https://unpkg.com https://fonts.googleapis.com",
  "font-src 'self' data: https://fonts.gstatic.com https://cdn.jsdelivr.net",
  "img-src 'self' data: blob: https:",
  "media-src 'self' data: blob: https:",
  "connect-src 'self' https://cdn.jsdelivr.net https://cdnjs.cloudflare.com https://unpkg.com",
  "worker-src 'self' blob:",
  "frame-src 'none'", "form-action 'none'", "base-uri 'none'",
].join('; ');

router.on('GET', 'um/:uid/:slug/:ver/:file', async (_req, res, { uid, slug, ver, file }) => {
  if (!/^[0-9a-f-]{36}$/.test(uid) || !SLUG.test(slug) || !/^(draft|\d+)$/.test(ver) || !['index.html', 'manifest.json'].includes(file)) {
    res.status(404).end(); return;
  }
  const page = await list({ prefix: `${modulePrefix(uid, slug)}${ver}/${file}`, limit: 1, token: blobToken() });
  const body = page.blobs[0] ? await fetchText(page.blobs[0].url) : null;
  if (body == null) { res.status(404).end(); return; }
  res.setHeader('Content-Type', file.endsWith('.html') ? 'text/html; charset=utf-8' : 'application/json');
  res.setHeader('Content-Security-Policy', USER_MODULE_CSP);
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('Cache-Control', ver === 'draft' ? 'no-store' : 'public, max-age=300');
  res.status(200).send(body);
});

// ---------------------------------------------------------------- site passes
// The Mac app's "Open x.com for 5 minutes" also has to satisfy Erik's Learn Gate extension in
// Chrome. The app asks for a pass, which is only issued once nothing is due and today's new cards
// are done, signed so it can't be made up; Learn Gate checks it here before unlocking.

const gateKey = () => process.env.GATE_SECRET
  || createHash('sha256').update(`pluckk-gate:${process.env.DATABASE_URL ?? ''}`).digest();
const b64url = (b: Buffer | string) => Buffer.from(b).toString('base64url');
const passSignature = (body: string) => createHmac('sha256', gateKey()).update(body).digest('base64url');

router.on('POST', 'gate/pass', authed(async (req, res, user) => {
  const minutes = Math.max(1, Math.min(60, Math.round(Number((req.body ?? {}).minutes) || 5)));
  const settings = await getStudySettings(user.id);
  const { folderRows, candidateRows, newToday } = await mixerContext(user.id);
  const left = todayCounts({
    folders: folderRows, candidates: candidateRows, newReviewedTodayByFolder: newToday,
    defaultNewPerDay: settings.newCardsPerDay ?? DEFAULT_NEW_PER_DAY,
  });
  if (left.review > 0 || left.learn > 0) { res.status(403).json({ error: "Today's cards aren't done yet", ...left }); return; }
  const until = Date.now() + minutes * 60000;
  const body = `${user.id}.${until}`;
  res.status(200).json({ token: `${b64url(body)}.${passSignature(body)}`, until });
}));

router.on('GET', 'gate/verify', async (req, res) => {
  const token = String(req.query?.token ?? '');
  const [encoded, signature] = token.split('.');
  const body = encoded ? Buffer.from(encoded, 'base64url').toString() : '';
  const expected = body ? passSignature(body) : '';
  const valid = !!signature && signature.length === expected.length && timingSafeEqual(Buffer.from(signature), Buffer.from(expected));
  const until = Number(body.split('.')[1]);
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.status(200).json(valid && until > Date.now() ? { ok: true, until } : { ok: false });
});

export default async function handler(req: VercelRequest, res: VercelResponse): Promise<void> {
  await router.dispatch(req, res, pathSegments(req));
}
