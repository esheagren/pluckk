// Read-only sanity check: a scheduled session for the real user must exclude paused folders.
import type { VercelRequest, VercelResponse } from '@vercel/node';
import { eq } from 'drizzle-orm';
import v1 from '../api/v1.js';
import { issueToken, revokeToken } from '../lib/auth.js';
import { getDb, schema } from '../lib/db.js';

const db = getDb();
const [user] = await db.select().from(schema.users).where(eq(schema.users.email, (process.env.PLUCKK_USER_EMAIL ?? (() => { throw new Error('Set PLUCKK_USER_EMAIL to the account to act on'); })())));
const token = await issueToken(user.id, 'verify');
try {
  const req = { method: 'POST', url: '/api/v1/review/session', body: { mode: 'scheduled', size: 30 }, headers: { authorization: `Bearer ${token}` }, query: { path: ['review', 'session'] } } as unknown as VercelRequest;
  let payload: unknown; let code = 200;
  const res = { status(c: number) { code = c; return res; }, json(p: unknown) { payload = p; return res; }, end() { return res; }, setHeader() { return res; }, headersSent: false } as unknown as VercelResponse;
  await v1(req, res);
  const body = payload as { cards: Array<{ folder: { name: string } | null }>; meta: unknown };
  const folders = [...new Set(body.cards.map((c) => c.folder?.name ?? 'unfiled'))];
  console.log('status', code, '| dealt', body.cards.length, '| folders in session:', folders.join(', '));
  console.log('meta:', JSON.stringify(body.meta));
  const pausedLeak = folders.some((f) => f.startsWith('Art ·') || f === 'Spanish Top 5000');
  console.log(pausedLeak ? 'FAIL: paused deck leaked into session' : 'PASS: paused decks excluded');
  process.exitCode = pausedLeak || code !== 200 ? 1 : 0;
} finally {
  await revokeToken(token);
}
