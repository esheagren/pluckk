# What Pluckk can learn from Orbit

*Study of [andymatuschak/orbit](https://github.com/andymatuschak/orbit) (shallow clone of `master`, 2026-09-02; ~340 TypeScript files across 20 packages). Two full explorer reports with file-level citations back this note; the file paths below are Orbit's unless marked Pluckk.*

## 0. The one-paragraph version

Orbit and Pluckk are mirror images. Orbit is an **engine with almost no authoring**: prompts are hand-written by essayists and ingested from Markdown, and the whole system is built around a tiny, rigorous, event-sourced core (two entity types, eight event types, an 80-line scheduler, two query predicates) that runs identically in SQLite, IndexedDB and Firestore. Pluckk is **authoring with an improvised engine**: the AI generator is the product, while cards, review state and scheduling are mutable rows shaped by whatever the last client needed. The audit we did on 2026-09-01 already said Pluckk's core needs to be pulled out into a `packages/core`. Orbit is the reference design for what that core should look like. The UI has a second, separate lesson: every visual choice in Orbit's review screen encodes something true about memory (the starburst *is* the schedule), and nothing in it is decorative.

## 1. What is worth emulating, in order

### 1.1 An event-sourced core with materialised snapshots

Orbit stores an append-only log of eight events (`core/src/event.ts`: `taskIngest`, `taskRepetition`, `taskReschedule`, `taskUpdateDeleted`, `taskUpdateSpec`, `taskUpdateProvenance`, `taskUpdateMetadata`, `attachmentIngest`) and derives entity state with one pure reducer (`core/src/eventReducer.ts`). Snapshots are stored next to the log as `{ entity, lastEventID, lastEventTimestampMillis }`; new events apply incrementally, and an event arriving out of order triggers a rebuild from the log (`store-shared/src/database.ts#_computeUpdatedEntitySnapshot`). Consequences that fall out for free: **undo** is "emit the inverse event" (deleting a prompt undoes with `taskUpdateDeleted { isDeleted: false }`); **sync** is "ship events since a cursor" with no conflict resolution at all (`sync/src/sync.ts`); **changing the scheduler later** is "replay the log with the new reducer"; **importing Anki history** is "translate revlog rows into repetition events".

Pluckk is halfway there without knowing it. `review_logs` already records `previous_*` and `new_*` state for every review (Pluckk `packages/api/db/schema.ts`), but `card_review_state` is the source of truth: a 24-column mutable row (ease, stability, difficulty, streak, calibration stats, leech flags…) that three clients used to compute independently. Recommendation: in Phase 3, make the log the truth. `review_logs` becomes the repetition event; card creation, edits, deletion, folder moves and reschedules become events too; `card_review_state` becomes a snapshot table the API rebuilds from the reducer. This is the single change that makes Phase 6 (FSRS) and Phase 5 (offline PWA) cheap instead of risky.

### 1.2 Task vs. component: one prompt, several schedules

Orbit's `Task` carries `componentStates: { [componentID]: { intervalMillis, dueTimestampMillis, lastRepetitionTimestampMillis } }` (`core/src/entities/task.ts`). A Q&A task has one component, `"main"`; a cloze with three blanks has three, each scheduled independently, all sharing one body, one provenance, one edit history. The type system enforces the mapping (`TaskComponentStates<TC> = { [ID in ComponentIDsOf<TC>]: … }`), and the review queue picks at most one component per task per session.

This is exactly the seam where Pluckk hurts. A bidirectional card is expanded into two `cards` rows at save time, a list-cloze into N rows, and the expansion logic lives in the extension, the webapp and the Mac app separately (the "3× duplicated" finding from the audit). Edit one twin and the other diverges; delete one and the other lingers. Recommendation: `cards` becomes the task (content JSON with `style` + `components`), and review state is keyed by `(card_id, component_id)`. Expansion happens in one reducer on the server. The Cards page shows one card; the review session shows one component at a time.

### 1.3 Provenance as a structure, not two strings

Orbit's `TaskProvenance` has `identifier` (the clustering key), `url`, `title`, `containerTitle`, `colorPaletteName`, and W3C-annotation `selectors` (`TextQuote`, `TextPosition`, `Range`, `XPath`). The identifier lets the ingester group tasks by source and detect *moves*; the selectors are there so a prompt can one day re-anchor to the passage it came from; `containerTitle` distinguishes "Quantum Country" from the chapter.

Pluckk has `source_url` and `source_title`. For browser captures that's nearly enough; for the Mac app it is already wrong (the "URL" is `"Google Chrome - Pequod - Google Chrome"`). Recommendation: a `provenance` JSON column with Orbit's shape, where the Mac app fills `containerTitle` = app name, `title` = window title, and both clients record a `TextQuote` selector (the selection plus a few words either side). Cheap now; it makes "visit origin, highlighted" and "all cards from this page" possible later, and it is the natural grouping key for the mixer.

### 1.4 Content-derived identity and idempotent ingest

Orbit gives embedded prompts a UUIDv5 of their stable-stringified spec (`web-component/src/extractItems.ts`: "a user can read an article on multiple machines without acquiring duplicate prompts"), and the Markdown interpreter hashes a canonically ordered content array into `metadata.ingestSourceIdentifier` (`interpreter/src/hasher/CryptoBase64Hasher.ts`). Re-running ingestion is a pure diff (`ingester/src/ingest.ts#ingestSources`): new → ingest event, gone → delete event, moved → provenance-update event, and *an ingest plus a delete of the same identifier is reinterpreted as a move*. The Readme states the contract honestly: move a prompt between notes and history survives; edit its text and it is a new prompt.

Pluckk has no notion of this. Capture the same paragraph twice and you get two cards. Recommendation: hash `(selection text, source identifier)` into a `capture_key` and make `POST /cards` idempotent on it, returning the existing card. And when Phase 6 (notes → cards) arrives, lift the interpreter/ingester split wholesale: a pure function from a note to an `Ingestible`, then a pure diff against the store. It is the correct design and it is already written.

### 1.5 A scheduler you can hold in your head

Orbit's scheduler is ~80 lines with two constants (`core/src/schedulers/spacedRepetitionScheduler.ts`): initial interval 5 days, growth 2.3×. Growth is computed from the **actually elapsed** interval, not the scheduled one, so reviewing late grows the interval more and reviewing early grows it less; success never shrinks the interval. Forgotten halves-ish (`/2.3`, floored at 5 days) and re-shows the prompt in ten minutes within the same session. Jitter is deterministic (`(timestamp % 1000) × 10 min`) "so prompts don't always end up in the same order". The queue has a 16-hour "fuzzy due" lookahead: if it's due later today, do it now. A code comment explicitly declines to punish early-review failures: "better to limit how much is 'at stake' at a given time."

Pluckk's SM-2 with four ratings is more expressive and Erik wants the mixer's control, so I am not proposing binary outcomes. But four things transfer directly: elapsed-time-based growth (SM-2 uses the scheduled interval, which punishes the backlog case Erik cares about), the 16-hour lookahead (today's due count stops jumping at midnight), same-session retry for "again" (Pluckk currently re-queues via learning steps in a way the UI hides), and jitter. And the scheduler should sit behind Orbit's interface, `computeNext(componentState, now, outcome) → { due, interval }`, so FSRS is a drop-in.

### 1.6 A typed API spec shared by client and server

`api/src/orbitAPI.ts` declares one TypeScript type mapping route → method → `{ query, params, body, response }`. `typescript-json-schema` turns it into a JSON schema; Ajv validates every request on the client (`api-client/src/requestManager.ts`) and every request on the server (`backend/src/api/util/typedRouter.ts`, with schema defaults applied). JSDoc tags (`@minimum`, `@TJS-pattern`) are the validation rules.

Pluckk's equivalent is a hand-written fetch client, a snake_case serializer at the boundary and no validation on either side. The cheap 2026 version is zod schemas in `packages/core` consumed by the `api/v1.ts` router and by `createApiClient`. That also retires the camelCase/snake_case split the CLAUDE.md has to warn about.

### 1.7 Tests as the specification

Orbit's storage layer has one conformance suite (`store-shared/src/databaseTests.ts`, ~35 cases) run unchanged against SQLite, IndexedDB and Firestore. The scheduler test is property-flavoured (`expect(interval / (old × 2.3)).toBeCloseTo(1)`) rather than golden numbers. Pluckk has two smoke scripts that hit a live database. The Phase 3 test plan should copy Orbit's shape: pure-function tests for reducer, scheduler and mixer with fixtures, plus one conformance suite for the store.

### 1.8 Notifications that model the cost of waiting

Orbit's daily job does not nag when three prompts are due. It builds the queue for today and each of the next seven days, estimates the prompts you would *marginally* forget by waiting (`0.9 ^ overdue-units`), and only emails when a full session is ready, too much is overdue, or no better session is coming (`backend/src/notifications/reviewSessionScheduling.ts`). Reminder spacing itself expands: 2, 2, 5, 10, 20, 30 days, then silence. Pluckk has no reminders. When it does, this is the algorithm.

### 1.9 The review screen: every pixel encodes the schedule

- **The starburst** (`ui/src/components/Starburst.tsx`): one ray per prompt in the session, ray length proportional to `log2(interval)`. It is the logo, the progress bar and a portrait of your memory of this page, in one shape. The current ray **previews the consequence** while you hover or press "Remembered" vs "Forgotten", before you commit.
- **The reveal is not a flip** (`Card.tsx`): staggered cross-fades with 8–16pt offset springs, bounciness zero everywhere, the question delayed 50 ms behind the answer. The proportions of question and answer change depending on which side carries an image, and on reveal the question drops one type size so the answer dominates.
- **Type sizes itself to the content** (`PromptFieldRenderer.tsx`): render invisibly, measure, step down through five size variants until it fits; short answers are enormous, long ones shrink gracefully. Real overflow is masked with a torn-paper **sawtooth**, not a fade.
- **A bounded stage**: content is capped at 750×750 and centred; review screens are saturated full-bleed colour fields, one of twelve palettes chosen by source. No streaks anywhere in the codebase.

For Pluckk's webapp, three of these are cheap and worth doing during Phase 5: the bounded centred stage (Erik already asked for the card to be centred), **interval preview on the four rating buttons** (SM-2 makes this even more informative than Orbit's binary case), and content-sized type. A palette per deck or source is a nice fourth.

## 2. Choices to be aware of (and mostly not copy)

- **Binary outcomes.** Orbit records only remembered/forgotten/skipped and *discards Anki ease on import*. That is a research bet ("limit what's at stake"), and it forecloses FSRS-style difficulty estimation. Keep Pluckk's four ratings; they are the raw material for Phase 6.
- **No session shaping.** Orbit has no new-cards-per-day limit and no deck mixing; the queue is "everything due, oldest first, cap 50". That works for prompts trickling in from reading. It would not survive Pluckk's 5,000-card Spanish import. The mixer stays.
- **Platform choices are not ours.** Firebase Functions, Firestore, Firebase Auth, React Native/Expo for web+iOS+Android+Catalyst, Bun. None of it transfers, and the repo is a 2024-era research vehicle (Expo 51) rather than a maintained product.
- **Cloze syntax.** `{curly braces}` in prose, which the parser itself admits collides with natural text and math. Pluckk's `cloze_list` with explicit prompts is the safer representation; Orbit's *per-blank scheduling* is the part to take.
- **"Plain" / application prompts are declared, not built.** The type, hasher, importer and button labels ("Succeeded" / "Needs Practice") exist; the renderer throws. The idea underneath, that each spec type carries its own *interaction language*, is good and applies to Pluckk's `explanation` and `application` styles, which today render as Q&A.
- **Even Andy's code has holes.** The SQLite backend applies a duplicate repetition event twice (`store-fs/src/sqlite.ts#updateEntities` does not pre-filter known event IDs; IndexedDB and Firestore do), the queue test is 24 lines, sync has two tests. The lesson is the conformance-suite *pattern*, not any claim of correctness.
- **Embedding is Orbit's whole reason to exist and Pluckk's non-goal.** The closed-shadow-root iframe, the postMessage protocol, anonymous buffering, the popup token relay: all beautifully done, all for public essays. Pluckk is private-first. The one transferable idea is "review where you read": the extension side panel could surface cards due from the current site, and the API already supports it (`?source_url_prefix=`).

## 3. What "elegant" means here

Three things, in descending order of transferability.

1. **A small vocabulary, used everywhere.** Two entities, eight events, one reducer, two query predicates, four sync methods. Every package (CLI ingester, iOS widget, web embed, notifier) is written against the same handful of pure functions, so the backend does not know about clozes and the widget does not know about Firestore. Pluckk's `packages/core` should aim for a vocabulary this small.
2. **Design decisions that are also data decisions.** Content-hashed identity is what makes anonymous review claimable *and* what makes notes re-ingestable *and* what dedupes across machines. Elapsed-time growth is what makes late reviews fair *and* what makes the "fuzzy due" lookahead safe. Each choice pays for itself three times.
3. **The interface tells the truth about the model.** Ray length is the interval. The hover preview is the scheduler running. The sawtooth says "torn off here" instead of pretending the answer ends. Nothing is a metaphor for something the system does not actually do.

## 4. Concrete fold into the Pluckk roadmap

**Phase 3 (`packages/core`)** — model it on Orbit's `core` + `store-shared`, in this order:

1. `entities.ts`: `Card { id, spec: { style, content }, provenance, componentStates, isDeleted, metadata }` with `componentStates` keyed per component (bidirectional → `forward`/`reverse`; list → `p0…pN`; else `main`).
2. `events.ts`: `cardIngest`, `cardRepetition { componentId, rating, sessionId }`, `cardReschedule`, `cardUpdateDeleted`, `cardUpdateSpec`, `cardUpdateProvenance`, `cardUpdateFolder`. Backfill from `cards` + `review_logs`.
3. `reducer.ts` + `scheduler.ts` (SM-2 behind `computeNext(state, now, rating)`; elapsed-time basis, jitter, 10-minute retry) + `queue.ts` (the mixer, plus the 16-hour lookahead).
4. zod schemas for the v1 API, shared with `createApiClient`.
5. Tests: reducer, scheduler (property-style), mixer; one store conformance suite against Neon.

**Phase 5 (client refactor)** — bounded centred stage, interval preview on rating buttons, content-sized type, palette per deck.

**Phase 6 (notes → cards, FSRS)** — interpreter/ingester split with content-hash identity and move detection; FSRS as a second `Scheduler` replayed over the event log.

**Anytime** — `capture_key` idempotency on `POST /cards`; structured `provenance` with `containerTitle` from the Mac app.
