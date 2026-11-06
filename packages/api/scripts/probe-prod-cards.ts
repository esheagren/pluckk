// End-to-end against production: create a card (twice, same passage → same card),
// review it, patch it, soft-delete it, then hard-delete it so nothing is left behind.
//   npx dotenv -e .env.local -- tsx scripts/probe-prod-cards.ts
import { eq } from 'drizzle-orm';
import { issueToken, revokeToken } from '../lib/auth.js';
import { getDb, schema } from '../lib/db.js';

const BASE = process.env.PROBE_BASE ?? 'https://pluckk-api.vercel.app';
const db = getDb();
const [user] = await db.select().from(schema.users).where(eq(schema.users.email, (process.env.PLUCKK_USER_EMAIL ?? (() => { throw new Error('Set PLUCKK_USER_EMAIL to the account to act on'); })())));
const token = await issueToken(user.id, 'probe-prod');
const call = async (method: string, path: string, body?: unknown) => {
  const r = await fetch(`${BASE}/api/v1/${path}`, { method, headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` }, body: body ? JSON.stringify(body) : undefined });
  return { status: r.status, body: (await r.json()) as Record<string, unknown> };
};
const check = (label: string, ok: boolean, detail?: unknown) => { console.log(`${ok ? 'PASS' : 'FAIL'}  ${label}${detail !== undefined ? '  → ' + JSON.stringify(detail).slice(0, 120) : ''}`); if (!ok) process.exitCode = 1; };

let cardId: string | null = null;
try {
  const sel = 'The mitochondria is the powerhouse of the cell — probe ' + Date.now();
  const a = await call('POST', 'cards', { question: 'Probe Q?', answer: 'Probe A', source_url: 'https://example.com/probe?utm_source=x', source_title: 'Probe', source_selection: sel });
  cardId = a.body.id as string;
  check('POST cards → 201 with spec + provenance', a.status === 201 && !!a.body.spec && !!(a.body.provenance as { identifier?: string })?.identifier, { spec: a.body.spec, prov: (a.body.provenance as { identifier: string }).identifier });
  const b = await call('POST', 'cards', { question: 'Probe Q again?', answer: 'x', source_url: 'https://example.com/probe', source_selection: `  ${sel}  ` });
  check('same passage again → 200 existing', b.status === 200 && b.body.existing === true && b.body.id === cardId);

  const r = await call('POST', 'review', { card_id: cardId, rating: 'good' });
  const st = r.body.state as { review_count: number; interval_days: number; status: string };
  check('POST review → server-scheduled state + previews', r.status === 200 && st.review_count === 1 && st.interval_days === 3 && !!r.body.previews && !!r.body.event_id, { st, previews: r.body.previews });

  const p = await call('PATCH', `cards/${cardId}`, { answer: 'Probe A (edited)', tags: ['probe'] });
  check('PATCH → setSpec + setTags', p.status === 200 && p.body.answer === 'Probe A (edited)' && (p.body.tags as string[])[0] === 'probe');

  const d = await call('DELETE', `cards/${cardId}`);
  const g = await call('GET', `cards/${cardId}`);
  check('DELETE soft → gone from reads', d.status === 200 && g.status === 404);

  const events = await db.select().from(schema.cardEvents).where(eq(schema.cardEvents.cardId, cardId));
  check('diary has ingest, review, setSpec, setTags, setDeleted', events.map((e) => e.type).sort().join(',') === 'card.ingest,card.review,card.setDeleted,card.setSpec,card.setTags', events.map((e) => e.type));
} finally {
  if (cardId) await db.delete(schema.cards).where(eq(schema.cards.id, cardId));
  await revokeToken(token);
}
