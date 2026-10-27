// /api/v1/* — data + auth routes behind one function (Hobby 12-function cap).
//
//   POST   auth/google            { credential, client }  → { token, user }
//   DELETE auth/token                                      → revoke caller's token
//   GET    cards[?source_url_prefix=&source=&folder_id=<uuid>|unfiled&limit=&offset=] → cards with folder + due_at
//   POST   cards                                           → create
//   PATCH  cards/:id  · DELETE cards/:id
//   GET    folders · POST folders · PATCH folders/:id · DELETE folders/:id
//   GET    review/queue           → { cards, states, new_reviewed_today }
//   POST   review                 { card_id, rating, new_state } → { state }
//   GET    activity               → { reviews: [...], cards: [...] }
//   POST   images                 { card_id, image_data, mime_type } → { image_url }

import type { VercelRequest, VercelResponse } from '@vercel/node';
import { and, desc, eq, gte, inArray, isNull, like, sql } from 'drizzle-orm';
import { selectSession } from '../lib/mixer.js';
import { OAuth2Client } from 'google-auth-library';
import { put } from '@vercel/blob';
import { DEFAULT_MECHANICS, MAIN_COMPONENT, SCHEDULER_ID, createCardBodySchema, parseBody, patchCardBodySchema, reviewSubmitBodySchema, reviewUndoBodySchema } from '@pluckk/core';
import { getDb, schema } from '../lib/db.js';
import { authenticateRequest, isAuthError, issueToken, revokeToken } from '../lib/auth.js';
import { CardError, createCard, deleteCard, patchCard, reviewCard, setCardImage, undoEvent, unfileCardsOfFolder } from '../lib/cards.js';
import { buildItems } from '../lib/review.js';
import { loadEvents } from '../lib/store.js';
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
/** `folderId` narrows to one deck ('unfiled' = no deck); `page` slices the newest-first list. */
async function listCards(userId: string, sourceUrlPrefix?: string, sourceIdentifier?: string,
                         folderId?: string, page?: { limit: number; offset: number }) {
  const db = getDb();
  const conds = [eq(schema.cards.userId, userId), eq(schema.cards.isDeleted, false)];
  if (sourceUrlPrefix) conds.push(like(schema.cards.sourceUrl, sourceUrlPrefix.replace(/[%_]/g, '\\$&') + '%'));
  // Every card from one source (page, app window, imported deck): provenance.identifier is the clustering key.
  if (sourceIdentifier) conds.push(sql`${schema.cards.provenance}->>'identifier' = ${sourceIdentifier}`);
  if (folderId === 'unfiled') conds.push(isNull(schema.cards.folderId));
  else if (folderId) conds.push(eq(schema.cards.folderId, folderId));
  // A card has one schedule per component; its "due" is the earliest of them.
  const due = db.select({
    cardId: schema.cardReviewState.cardId,
    dueAt: sql<string>`min(${schema.cardReviewState.dueAt})`.as('due_at'),
  }).from(schema.cardReviewState).where(eq(schema.cardReviewState.userId, userId)).groupBy(schema.cardReviewState.cardId).as('due');
  const rows = await db
    .select({ card: schema.cards, folder: schema.folders, dueAt: due.dueAt })
    .from(schema.cards)
    .leftJoin(schema.folders, eq(schema.cards.folderId, schema.folders.id))
    .leftJoin(due, eq(due.cardId, schema.cards.id))
    .where(and(...conds))
    .orderBy(desc(schema.cards.createdAt))
    .limit(page?.limit ?? Number.MAX_SAFE_INTEGER)
    .offset(page?.offset ?? 0);
  return rows.map((r) => ({ ...snake<Record<string, unknown>>(r.card), folder: r.folder ? snake(r.folder) : null, due_at: r.dueAt ? isoTimestamp(r.dueAt) : null }));
}

router.on('GET', 'cards', authed(async (req, res, user) => {
  const prefix = typeof req.query.source_url_prefix === 'string' ? req.query.source_url_prefix : undefined;
  const source = typeof req.query.source === 'string' ? req.query.source : undefined;
  // Optional: one deck (?folder_id=<uuid>|unfiled) and a page (?limit=&offset=, limit ≤ 500).
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
  res.status(200).json(await listCards(user.id, prefix, source, folder, page));
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
router.on('POST', 'review', authed(async (req, res, user) => {
  const parsed = parseBody(reviewSubmitBodySchema, req.body);
  if (!parsed.ok) { res.status(400).json({ error: parsed.error }); return; }
  const body = parsed.data;
  const db = getDb();
  const r = await reviewCard(db, user.id, body.card_id, body.rating, {
    componentId: body.component_id ?? MAIN_COMPONENT, sessionId: body.session_id ?? null, responseMs: body.response_time_ms ?? null,
  });
  await db.insert(schema.reviewLogs).values({
    cardReviewStateId: r.state.id, userId: user.id, cardId: body.card_id, reviewMode: 'standard', rating: body.rating,
    responseTimeMs: body.response_time_ms ?? null,
    previousStatus: r.previous?.status ?? 'new', previousInterval: r.previous?.intervalDays ?? 0, previousEase: r.previous?.easeFactor ?? 2.5,
    previousDue: r.previous?.dueAt ?? null,
    newStatus: r.state.status, newInterval: r.state.intervalDays, newEase: r.state.easeFactor, newDue: r.state.dueAt,
    algorithmVersion: `core:${SCHEDULER_ID}`,
    reviewedAt: r.state.lastReviewedAt ?? new Date().toISOString(),
  });
  res.status(200).json({ state: snake(r.state), component_id: r.componentId, previews: r.previews, event_id: r.eventId });
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
    select c.folder_id, f.name, coalesce(f.is_paused, false) as is_paused,
           count(distinct c.id)::int as total,
           count(distinct c.id) filter (where s.id is null or s.status = 'new')::int as new,
           count(distinct c.id) filter (where s.due_at <= now() + make_interval(hours => ${DEFAULT_MECHANICS.dueLookaheadHours}) and s.status <> 'new')::int as due
    from cards c
    left join folders f on f.id = c.folder_id
    left join card_review_state s on s.card_id = c.id and s.user_id = c.user_id
    where c.user_id = ${user.id} and c.is_deleted = false
    group by c.folder_id, f.name, f.is_paused
    order by f.name nulls last`);
  res.status(200).json({ decks: r.rows });
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

router.on('POST', 'review/session', authed(async (req, res, user) => {
  const body = (req.body ?? {}) as {
    mode?: 'scheduled' | 'focus' | 'backlog';
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

  const folderRows = await db.select({
    id: schema.folders.id, weight: schema.folders.weight, isPaused: schema.folders.isPaused, newPerDay: schema.folders.newPerDay,
  }).from(schema.folders).where(eq(schema.folders.userId, user.id));

  // Slim candidate rows, one per component: id, component, folder, created, state status/due.
  // A card with no state rows yet is its single 'main' component, new.
  const candidateRows = (await db.select({
    cardId: schema.cards.id, componentId: schema.cardReviewState.componentId, folderId: schema.cards.folderId, createdAt: schema.cards.createdAt,
    status: schema.cardReviewState.status, dueAt: schema.cardReviewState.dueAt,
  }).from(schema.cards)
    .leftJoin(schema.cardReviewState, and(eq(schema.cardReviewState.cardId, schema.cards.id), eq(schema.cardReviewState.userId, user.id)))
    .where(and(eq(schema.cards.userId, user.id), eq(schema.cards.isDeleted, false))))
    .map((r) => ({ ...r, componentId: r.componentId ?? MAIN_COMPONENT }));

  // New cards already introduced today, per folder.
  const todayStart = new Date(); todayStart.setHours(0, 0, 0, 0);
  const introduced = await db.execute(sql`
    select c.folder_id, count(distinct l.card_id)::int as n
    from review_logs l join cards c on c.id = l.card_id
    where l.user_id = ${user.id} and l.previous_status = 'new' and l.reviewed_at >= ${todayStart.toISOString()}
    group by c.folder_id`);
  const newToday = new Map<string | null, number>();
  for (const r of introduced.rows as Array<{ folder_id: string | null; n: number }>) newToday.set(r.folder_id, r.n);

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

export default async function handler(req: VercelRequest, res: VercelResponse): Promise<void> {
  await router.dispatch(req, res, pathSegments(req));
}
