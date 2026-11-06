# Pluckk

Pluckk is a spaced-repetition system for learning from what you read. Select text anywhere on
your Mac, double-tap ⌘, and Pluckk drafts flashcards from it; practise them on a schedule that
adapts to how well you actually know each one.

It goes beyond text cards. A card can carry **modules**: small web pages that show or ask what
words can't. That covers a map with a province highlighted, a "click on Chengdu" question scored
by distance, a character read aloud, or a step-through simulation of k-means. Anyone can write a
module, and the built-in assistant can write one for you.

> Status: a personal project, used daily, now opened up. macOS first; the web app covers most of
> the rest. Expect rough edges and say hello in Issues.

## What's in it

- **Mac app** (`packages/macos`, SwiftUI). A panel you summon with ⌘⌘ from any app: capture and
  generate cards, write your own, and practise. It includes:
  - number cards answered with a 95% range,
  - fill-in-the-blank cards you answer by typing,
  - off-schedule practice of a deck or chosen cards,
  - deck statistics with a new-card ring,
  - an assistant panel (Claude or any OpenAI-compatible model) that can edit cards and write
    modules,
  - an optional gate that keeps distracting sites closed until the day's cards are done.
- **Web app** (`packages/webapp`, React + Vite). Practice, decks and settings in the browser;
  also runs the sign-in for the other clients.
- **API** (`packages/api`). Vercel functions on Neon Postgres, Blob storage for images and
  user-written modules, and Claude or Gemini for card generation.
- **Core engine** (`packages/core`, TypeScript, no I/O). The scheduler and the rest of the rules,
  shared by every client:
  - a card's history is an append-only diary of events, and its state is reduced from that diary;
  - the SM-2 scheduler, with Pluckk's mechanics on top;
  - the session mixer that deals cards across decks;
  - each deck's difficulty score and the cap on cards still being learned;
  - leech detection;
  - workload forecasts.
- **Card modules** (`packages/api/public/modules`). The built-in modules are `geo-map`, `speak` and
  `kmeans`, plus a step-through player for simulations. See
  [the design](docs/roadmap/planned/card-modules/plan.md).
- **Chrome extension** (`packages/extension`). The original capture client: highlight text on a
  page and make cards from it.

## Run it

You need Node 20+ and npm. The Mac app also needs Xcode 15+ on macOS 13+.

```bash
npm install
npm run build:core      # the other packages import its build
npm test                # core engine tests (vitest)
npm run dev:webapp      # web app on http://localhost:5173
```

Out of the box the clients talk to the hosted API at `pluckk-api.vercel.app`. To run your own
API, database and storage, follow [docs/self-hosting.md](docs/self-hosting.md).

Mac app: open `packages/macos/Pluckk/Pluckk.xcodeproj`, choose your own signing team, and run. It
needs Accessibility permission for ⌘⌘ and text capture, and Automation permission for the
optional site gate.

## Layout

```
packages/
  core/       scheduler, diary reducer, mixer, difficulty, API schemas (pure TS, tested)
  api/        Vercel functions (api/v1.ts routes everything), Drizzle schema, public/ modules + maps
  webapp/     React web app
  macos/      SwiftUI Mac app
  extension/  Chrome extension
  shared/     constants shared by the browser clients
docs/         design notes, roadmap (icebox → planned → active → completed), audits
```

## Contributing

New card modules are the easiest way in: a module is one HTML page and a manifest, and it needs
no change to the app. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Licence

[MIT](LICENSE)
