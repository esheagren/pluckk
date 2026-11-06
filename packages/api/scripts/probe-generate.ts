// Call the live /api/generate-cards with a real token and a tiny payload; print the raw response.
import { eq } from 'drizzle-orm';
import { issueToken, revokeToken } from '../lib/auth.js';
import { getDb, schema } from '../lib/db.js';

const db = getDb();
const [user] = await db.select().from(schema.users).where(eq(schema.users.email, (process.env.PLUCKK_USER_EMAIL ?? (() => { throw new Error('Set PLUCKK_USER_EMAIL to the account to act on'); })())));
const token = await issueToken(user.id, 'probe');
try {
  const res = await fetch('https://pluckk-api.vercel.app/api/generate-cards', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
    body: JSON.stringify({ selection: 'The mitochondria is the powerhouse of the cell.', context: '', url: 'Notion - Test', title: 'Test', focusText: null }),
  });
  console.log('status', res.status);
  console.log((await res.text()).slice(0, 600));
} finally {
  await revokeToken(token);
}
