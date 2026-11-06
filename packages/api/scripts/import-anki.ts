// One-off import from the local Anki collection into Pluckk.
//   npx dotenv -e .env.local -- tsx scripts/import-anki.ts gwoa [--dry]
//   npx dotenv -e .env.local -- tsx scripts/import-anki.ts spanish [--dry]
//
// Reads a COPY of collection.anki2 via the sqlite3 CLI (-json). Great Works of
// Art becomes three paused folders (Artists/Titles/Periods — three question
// directions over the same 651 paintings), images uploaded once to Blob.
// Spanish Top 5000 imports word→translation text-only (audio/pictures dropped),
// frequency rank kept as a tag. Idempotent: skips question+folder duplicates.

import { execFileSync } from 'node:child_process';
import { copyFileSync, existsSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { eq, and } from 'drizzle-orm';
import { put } from '@vercel/blob';
import { getDb, schema } from '../lib/db.js';

const ANKI_DIR = `${process.env.HOME}/Library/Application Support/Anki2/User 1`;
const MEDIA_DIR = join(ANKI_DIR, 'collection.media');
const USER_EMAIL = (process.env.PLUCKK_USER_EMAIL ?? (() => { throw new Error('Set PLUCKK_USER_EMAIL to the account to act on'); })());
const which = process.argv[2];
const dry = process.argv.includes('--dry');
if (which !== 'gwoa' && which !== 'spanish') { console.error('usage: import-anki.ts gwoa|spanish [--dry]'); process.exit(1); }

// Work on a copy so the live collection is never opened by us.
const dbCopy = join(tmpdir(), `anki-import-${Date.now()}.db`);
copyFileSync(join(ANKI_DIR, 'collection.anki2'), dbCopy);
function q<T>(sqlText: string): T[] {
  const out = execFileSync('sqlite3', ['-json', dbCopy, sqlText], { maxBuffer: 256 * 1024 * 1024 }).toString();
  return out.trim() ? (JSON.parse(out) as T[]) : [];
}

const db = getDb();
const [user] = await db.select().from(schema.users).where(eq(schema.users.email, USER_EMAIL));
if (!user) { console.error('user not found'); process.exit(1); }

const SEP = '\x1f';
interface NoteRow { id: number; mid: number; flds: string }

function fieldIndex(mid: number): Map<string, number> {
  const rows = q<{ ord: number; name: string }>(`select ord, name from fields where ntid=${mid} order by ord`);
  return new Map(rows.map((r) => [r.name.toLowerCase(), r.ord]));
}
const imgSrc = (html: string): string | null => /<img[^>]*src="([^"]+)"/.exec(html)?.[1] ?? null;
const strip = (html: string): string => html.replace(/<[^>]*>/g, '').replace(/\[sound:[^\]]*\]/g, '').replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/\s+/g, ' ').trim();

async function ensureFolder(name: string): Promise<string> {
  const [existing] = await db.select().from(schema.folders).where(and(eq(schema.folders.userId, user.id), eq(schema.folders.name, name)));
  if (existing) return existing.id;
  if (dry) return `dry-${name}`;
  const [row] = await db.insert(schema.folders).values({ userId: user.id, name, isPaused: true, newPerDay: 5 }).returning();
  return row.id;
}

const blobCache = new Map<string, string | null>();
let blobBytes = 0;
async function uploadMedia(file: string): Promise<string | null> {
  if (blobCache.has(file)) return blobCache.get(file)!;
  const path = join(MEDIA_DIR, file);
  let url: string | null = null;
  if (existsSync(path)) {
    const size = statSync(path).size;
    blobBytes += size;
    if (!dry) {
      const ext = file.split('.').pop()!.toLowerCase();
      const type = ext === 'png' ? 'image/png' : ext === 'gif' ? 'image/gif' : 'image/jpeg';
      const blob = await put(`anki-media/${encodeURIComponent(file)}`, readFileSync(path), {
        access: 'public', contentType: type, addRandomSuffix: false, allowOverwrite: true,
        token: process.env.BLOB_READ_WRITE_TOKEN,
      });
      url = blob.url;
    } else {
      url = `dry://${file}`;
    }
  }
  blobCache.set(file, url);
  return url;
}

async function insertCards(folderId: string, rows: Array<typeof schema.cards.$inferInsert>): Promise<{ inserted: number; skipped: number }> {
  const existing = dry ? [] : await db.select({ question: schema.cards.question }).from(schema.cards)
    .where(and(eq(schema.cards.userId, user.id), eq(schema.cards.folderId, folderId)));
  const seen = new Set(existing.map((e) => e.question));
  const fresh = rows.filter((r) => !seen.has(r.question));
  if (!dry) {
    for (let i = 0; i < fresh.length; i += 200) await db.insert(schema.cards).values(fresh.slice(i, i + 200));
  }
  return { inserted: fresh.length, skipped: rows.length - fresh.length };
}

if (which === 'gwoa') {
  // One shared note set; subdeck membership only changes the question direction.
  const notes = q<NoteRow>(`select distinct n.id, n.mid, n.flds from notes n join cards c on c.nid=n.id where c.did in (1667589475433,1667589475434,1667589475435)`);
  console.log(`GWoA notes: ${notes.length}`);
  const fi = fieldIndex(notes[0].mid);
  console.log('fields:', [...fi.keys()].join(', '));
  const idx = (name: string) => { const i = fi.get(name); if (i === undefined) throw new Error(`missing field ${name}`); return i; };
  const [artI, titleI, dateI, moveI, artworkI] = [idx('artist'), idx('title'), idx('date'), idx('period/movement'), idx('artwork')];

  // Erik only wants the artist direction (2026-09-01); Titles/Periods decks were deleted.
  const directions = [
    { folder: 'Art · Artists', question: 'Who is the artist?', answer: (f: string[]) => `${strip(f[artI])}\n“${strip(f[titleI])}” (${strip(f[dateI])})` },
  ];
  void moveI;

  // Upload each painting once.
  const imageUrls = new Map<number, string | null>();
  let missing = 0;
  for (const n of notes) {
    const src = imgSrc(n.flds.split(SEP)[artworkI] ?? '');
    imageUrls.set(n.id, src ? await uploadMedia(src) : null);
    if (!imageUrls.get(n.id)) missing++;
  }
  console.log(`images: ${blobCache.size} unique, ${missing} notes without image, ~${(blobBytes / 1e6).toFixed(0)} MB${dry ? ' (dry)' : ' uploaded'}`);

  for (const d of directions) {
    const folderId = await ensureFolder(d.folder);
    const rows = notes.map((n) => {
      const f = n.flds.split(SEP);
      return {
        userId: user.id, folderId, question: d.question ,
        answer: d.answer(f),
        imageUrl: imageUrls.get(n.id),
        style: 'qa', tags: ['anki:great-works'],
        sourceTitle: 'Imported from Anki · Great Works of Art',
      };
    // question must be unique per card for dedupe → embed the note id invisibly? No:
    // question is identical by design (image differentiates). Dedupe by answer instead.
    });
    // For image-question decks the question text repeats; dedupe on answer.
    const seenAns = new Set<string>();
    const unique = rows.filter((r) => (seenAns.has(r.answer) ? false : (seenAns.add(r.answer), true)));
    const existing = dry ? [] : await db.select({ answer: schema.cards.answer }).from(schema.cards)
      .where(and(eq(schema.cards.userId, user.id), eq(schema.cards.folderId, folderId)));
    const have = new Set(existing.map((e) => e.answer));
    const fresh = unique.filter((r) => !have.has(r.answer));
    if (!dry) for (let i = 0; i < fresh.length; i += 200) await db.insert(schema.cards).values(fresh.slice(i, i + 200));
    console.log(`${d.folder}: +${fresh.length} (dupes in-source: ${rows.length - unique.length}, already present: ${unique.length - fresh.length})`);
  }
} else {
  const notes = q<NoteRow>(`select n.id, n.mid, n.flds from notes n join cards c on c.nid=n.id where c.did=1668723973726 group by n.id`);
  console.log(`Spanish notes: ${notes.length}`);
  const fi = fieldIndex(notes[0].mid);
  console.log('fields:', [...fi.keys()].join(', '));
  const names = [...fi.keys()];
  // Expected shape: word / picture / translation / audio / rank — resolve loosely.
  const wordI = fi.get('word') ?? fi.get('spanish') ?? 0;
  const transI = fi.get('translation') ?? fi.get('english') ?? 2;
  const rankI = fi.get('rank') ?? fi.get('frequency') ?? names.length - 1;

  const folderId = await ensureFolder('Spanish Top 5000');
  const rows = notes.map((n) => {
    const f = n.flds.split(SEP);
    const rank = strip(f[rankI] ?? '');
    return {
      userId: user.id, folderId,
      question: strip(f[wordI] ?? ''),
      answer: strip(f[transI] ?? ''),
      style: 'qa',
      tags: ['anki:spanish-5000', ...(rank && /^\d+$/.test(rank) ? [`freq:${rank}`] : [])],
      sourceTitle: 'Imported from Anki · Essential Spanish Top 5000',
    };
  }).filter((r) => r.question && r.answer);
  const { inserted, skipped } = await insertCards(folderId, rows);
  console.log(`Spanish Top 5000: +${inserted} (skipped ${skipped}; ${notes.length - rows.length} empty)`);
}

// Final counts
if (!dry) {
  const counts = await db.execute(
    (await import('drizzle-orm')).sql`select f.name, count(c.id)::int as n, f.is_paused from folders f left join cards c on c.folder_id=f.id where f.user_id=${user.id} group by f.id order by n desc`
  );
  console.log(JSON.stringify(counts.rows));
}
console.log('done', dry ? '(dry run)' : '');
