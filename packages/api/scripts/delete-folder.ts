// Delete a folder AND its cards (the FK alone would orphan cards into Unfiled).
//   npx dotenv -e .env.local -- tsx scripts/delete-folder.ts "Art · Periods" "Art · Titles"
import { and, eq, inArray } from 'drizzle-orm';
import { getDb, schema } from '../lib/db.js';

const names = process.argv.slice(2);
if (names.length === 0) { console.error('usage: delete-folder.ts <name> [...]'); process.exit(1); }
const db = getDb();
const [user] = await db.select().from(schema.users).where(eq(schema.users.email, (process.env.PLUCKK_USER_EMAIL ?? (() => { throw new Error('Set PLUCKK_USER_EMAIL to the account to act on'); })())));

for (const name of names) {
  const [folder] = await db.select().from(schema.folders).where(and(eq(schema.folders.userId, user.id), eq(schema.folders.name, name)));
  if (!folder) { console.log(`${name}: not found`); continue; }
  const cards = await db.delete(schema.cards).where(and(eq(schema.cards.userId, user.id), eq(schema.cards.folderId, folder.id))).returning({ id: schema.cards.id });
  await db.delete(schema.folders).where(inArray(schema.folders.id, [folder.id]));
  console.log(`${name}: deleted ${cards.length} cards + folder`);
}
const left = await db.select({ name: schema.folders.name }).from(schema.folders).where(eq(schema.folders.userId, user.id));
console.log('folders now:', left.map((f) => f.name).join(' | '));
