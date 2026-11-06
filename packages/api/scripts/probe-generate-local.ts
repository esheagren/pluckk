// Invoke the generate-cards handler in-process to see the real exception.
import type { VercelRequest, VercelResponse } from '@vercel/node';
import { eq } from 'drizzle-orm';
import handler from '../api/generate-cards.js';
import { issueToken, revokeToken } from '../lib/auth.js';
import { getDb, schema } from '../lib/db.js';

const db = getDb();
const [user] = await db.select().from(schema.users).where(eq(schema.users.email, (process.env.PLUCKK_USER_EMAIL ?? (() => { throw new Error('Set PLUCKK_USER_EMAIL to the account to act on'); })())));
const token = await issueToken(user.id, 'probe-local');
try {
  const req = {
    method: 'POST', url: '/api/generate-cards', headers: { authorization: `Bearer ${token}` }, query: {},
    body: { selection: 'The mitochondria is the powerhouse of the cell.', context: '', url: 'Notion - Test', title: 'Test', focusText: null },
  } as unknown as VercelRequest;
  let code = 0; let payload: unknown;
  const res = { status(c: number) { code = c; return res; }, json(p: unknown) { payload = p; return res; }, end() { return res; }, setHeader() { return res; }, headersSent: false } as unknown as VercelResponse;
  await handler(req, res);
  console.log('status', code, JSON.stringify(payload).slice(0, 800));
} finally {
  await revokeToken(token);
}
