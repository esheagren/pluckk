# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project Overview

**Pluckk** is a private-first spaced-repetition system (users = Erik and people he invites; no billing,
no public profiles, no social features — decided 2026-09-01). A Chrome extension captures highlighted text
in the browser; a macOS app (`⌘⌘`) captures from any native app; a web app (pluckk.app) is the single
review surface. All three talk to one API. Product doc: `docs/README.md`. Architecture audit and forward
plan: `docs/audit/2026-09-01-architecture-audit.md`, `docs/roadmap/planned/consolidation/plan.md`.

**Stack (since the 2026-08 migration off Supabase):** Neon Postgres via Drizzle, Vercel serverless
functions, Vercel Blob for card images, Google Sign-In → opaque bearer tokens. No Stripe, no usage limits.

## Packages

| Package | What | Run |
|---|---|---|
| `packages/core` | **The engine** (core-engine, 2026-09): `entities.ts` (Card = spec + provenance + one `ComponentState` per component), `events.ts` (the append-only diary), `reducer.ts` (events → card), `scheduler/` (SM-2 behind a `Scheduler` interface; Orbit mechanics on), `queue.ts` (the review mixer), `api.ts` (zod wire schemas). Pure, no I/O. Built to `dist/` because Vercel does not transpile workspace packages. | `npm run build:core`, `npm test -w @pluckk/core` (vitest), `npm run typecheck` |
| `packages/api` | Vercel functions. `api/v1.ts` is one function routing all `/api/v1/*` data/auth paths via a `vercel.json` rewrite (Hobby plan caps 12 functions). `db/schema.ts` is the Drizzle schema; `drizzle/` holds the migrations. `lib/store.ts` appends events and rebuilds snapshots; `lib/cards.ts` / `lib/review.ts` are the write and read paths. | `npm run typecheck`, `npm run db:generate` + `db:migrate`, `npm run smoke`, `smoke:mixer`, `db:verify`, `vercel --prod` |
| `packages/shared` | `api/` (fetch client, session store, Google OIDC helpers), `constants/`, `utils/`; `scheduler/` only re-exports from core | imported by the others |
| `packages/webapp` | Vite + React 18, pluckk.app. Hooks in `src/hooks/` call `@pluckk/shared/api`. | `npm run dev:webapp`, `npm run build:webapp` |
| `packages/extension` | Manifest V3. `src/auth.ts` owns sign-in + the API client; background/content built by esbuild as IIFE. | `npm run build:extension`, load unpacked from `packages/extension/dist` |
| `packages/macos` | Swift client: `⌘⌘` → Accessibility selection (or synthetic ⌘C for Electron apps) → panel → generate → `/api/v1/cards`; native Practice tab over `/api/v1/review/session`, `review`, `review/undo`. Signs in via `pluckk.app/auth/desktop` → `pluckk://` callback. No browsing (webapp does that). | `xcodebuild -project packages/macos/Pluckk/Pluckk.xcodeproj -scheme Pluckk build` |

## Rules

- **All data access goes through `packages/api`.** Clients never hold DB credentials. Every query in the
  API is scoped `where user_id = <authenticated user>` — there is no RLS any more, so never omit it.
- **Auth:** `POST /api/v1/auth/google { credential }` verifies a Google ID token and issues a `pk_…` token
  (sha256-hashed in `api_tokens`). `lib/auth.ts#authenticateRequest` is the single verifier. Webapp stores
  the token in localStorage, extension in `chrome.storage.local['pluckk_session']`, macOS in the Keychain
  (obtained through the webapp's `/auth/desktop` page, which redirects to `pluckk://auth/callback#token=`).
- **API JSON is snake_case** (the old Supabase row shape) — `lib/serialize.ts#snake` at the boundary.
  Drizzle properties are camelCase. Don't mix them.
- **The diary is the truth.** Every change to a card is a `card_events` row (`card.ingest`, `card.review`,
  `card.reschedule`, `card.setDeleted`, `card.setSpec`, …); `cards` and `card_review_state` are snapshots the
  reducer rebuilds. Never update those tables directly in the API — go through `lib/store.ts#commit`. A card
  has one `card_review_state` row per component (`main`, or `forward`/`reverse`, or `p0…pN`). Delete is soft
  (`is_deleted`); every read filters it. `npm run db:verify` rebuilds every card from its events and must
  report 0 mismatches. `question`/`answer`/`style`/`source_*` on `cards` are a read-only mirror of
  `spec`/`provenance` until they are dropped.
- **Schema changes:** edit `packages/api/db/schema.ts`, then `npm run db:generate` and `npm run db:migrate`
  (the migrations in `packages/api/drizzle/` are tracked; `db:push` is no longer used). The historical
  Supabase SQL lives in `docs/history/supabase-migrations/` — reference only, never applied.
- **Scheduling happens on the server.** Clients send `{ card_id, component_id, rating }` to `POST review` and
  get the new state and interval previews back. Do not compute SM-2 in a client. Review events record the
  scheduler mechanics they used so replays stay exact; change `DEFAULT_MECHANICS` in core only with that in mind.
- **After changing `packages/core`:** `npm run build:core` (the API and the clients import `dist/`).
- **Adding an endpoint:** add a route to `api/v1.ts`, not a new file, unless the function count
  allows it.
- `import.meta` is not available in the esbuild IIFE builds (background/content) — keep shared constants
  plain values.
- Env vars for the API live in Vercel (`vercel env pull .env.local` inside `packages/api`); see
  `packages/api/.env.example`. `GOOGLE_CLIENT_ID` (public) is a constant in `packages/shared/src/constants/api.ts`.

## Roadmap workflow

`docs/roadmap/` — `icebox.md` → `planned/<feature>/plan.md` → `completed/<feature>/`. The current
sequence of work is `docs/roadmap/planned/consolidation/plan.md` (phases 0–6).

## Verification

Before deploying the API: `npm run smoke`, `npm run smoke:mixer` and `npm run db:verify` in `packages/api`;
`npm test` at the root runs the core unit tests (CI runs typecheck + tests on every push). Deploy with
`bash scripts-deploy-api.sh` / `bash scripts-deploy-webapp.sh` from the repo root (the Vercel projects have
Root Directory set, so the CLI needs the project identity from env); `scripts-deploy-api-preview.sh` makes a
preview, which can be probed through a Protection Bypass secret. After a production deploy,
`npx dotenv -e .env.local -- tsx scripts/probe-prod-cards.ts` exercises create → dedupe → review → patch →
delete against the live API.
