# CLAUDE.md

Guidance for AI coding agents (and people) working in this repository.

## What Pluckk is

A spaced-repetition system: capture from anything you read, generate or write cards, and
practise them on a schedule. It's a TypeScript monorepo plus a SwiftUI Mac app; see README.md for
the tour.

| Package | What | Commands |
|---|---|---|
| `packages/core` | Pure TS: card entities, the event diary and its reducer, the SM-2 scheduler, the session mixer, difficulty and caps, API schemas (zod) | `npm run build`, `npm test` (vitest) |
| `packages/api` | Vercel functions, with every `/api/v1/*` route in `api/v1.ts`; Drizzle schema in `db/`; static modules and maps in `public/` | `npm run dev` (vercel dev), `npm run typecheck` |
| `packages/webapp` | React + Vite web app | `npm run dev`, `npm run build` |
| `packages/macos` | SwiftUI Mac app (`Pluckk.xcodeproj`) | `xcodebuild -project Pluckk.xcodeproj -scheme Pluckk build` |
| `packages/extension` | Chrome extension (capture) | `npm run build` |
| `packages/shared` | Constants shared by the browser clients | none |

## Rules that matter

- **Rules live in core.** Scheduling, dealing, difficulty and anything about what a card is go in
  `packages/core` with tests. The API and clients call core rather than re-implementing it.
- **Build core first.** `dist/` is gitignored, and the API and webapp read core's build. Run
  `npm run build:core` before typechecking them.
- **A card is a spec plus a diary.** `cards.spec` (jsonb) holds what was authored: the
  question, answer, style, number answer, and modules. Its state is reduced from `card_events`.
  The flat columns (question, answer…) are a read-only mirror. Edits go through
  `lib/cards.ts`, which writes events.
- **Card modules are web pages,** sandboxed and served from `public/modules` or, for a user's
  own, from Blob storage under `/um/…`. The host talks to them only by `postMessage`. See
  `docs/roadmap/planned/card-modules/plan.md` and CONTRIBUTING.md.
- **One function.** The Vercel Hobby plan caps a deployment at 12 functions, so new routes go in
  `api/v1.ts`.
- **Mac app.** New Swift files must be added to `project.pbxproj` with unused IDs. The app talks
  only to the API with a bearer token; it holds no database credentials.
- **No secrets or personal details in the repo.** Scripts read accounts and keys from the
  environment.
- **Roadmap.** `docs/roadmap/`: icebox.md → planned/ → active/ → completed/.
