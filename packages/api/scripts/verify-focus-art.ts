// Read-only: focus session on Art · Artists must deal cards with image_url set.
import type { VercelRequest, VercelResponse } from '@vercel/node';
import { and, eq } from 'drizzle-orm';
import v1 from '../api/v1.js';
import { issueToken, revokeToken } from '../lib/auth.js';
import { getDb, schema } from '../lib/db.js';

const db = getDb();
const [user] = await db.select().from(schema.users).where(eq(schema.users.email, (process.env.PLUCKK_USER_EMAIL ?? (() => { throw new Error('Set PLUCKK_USER_EMAIL to the account to act on'); })())));
const [folder] = await db.select().from(schema.folders).where(and(eq(schema.folders.userId, user.id), eq(schema.folders.name, 'Art · Artists')));
const token = await issueToken(user.id, 'verify-art');
try {
  const req = { method: 'POST', url: '/api/v1/review/session', body: { mode: 'focus', folder_id: folder.id, size: 5 }, headers: { authorization: `Bearer ${token}` }, query: { path: ['review', 'session'] } } as unknown as VercelRequest;
  let payload: unknown; let code = 0;
  const res = { status(c: number) { code = c; return res; }, json(p: unknown) { payload = p; return res; }, end() { return res; }, setHeader() { return res; }, headersSent: false } as unknown as VercelResponse;
  await v1(req, res);
  const body = payload as { cards: Array<{ question: string; answer: string; image_url: string | null; folder: { name: string } }> };
  console.log('status', code, '| dealt', body.cards.length);
  for (const c of body.cards.slice(0, 3)) console.log(`- [${c.folder?.name}] ${c.question} → ${c.answer.split('\n')[0]} | image: ${c.image_url ? c.image_url.slice(0, 60) : 'MISSING'}`);
  const ok = code === 200 && body.cards.length === 5 && body.cards.every((c) => c.image_url);
  console.log(ok ? 'PASS: paused Art deck deals 5 with images' : 'FAIL');
  process.exitCode = ok ? 0 : 1;
} finally {
  await revokeToken(token);
}
