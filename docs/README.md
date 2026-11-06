> Early product notes, kept for history; parts describe the original Chrome-extension version.
> For the current state of Pluckk, start at the [README](../README.md).

# Pluckk

Pluckk is a browser-native spaced repetition system that transforms how people learn from the web. Highlight text on any webpage, get AI-generated flashcards, and review them using proven memory science.

**Stage:** Active development / MVP

## What Makes Pluckk Different

**AI-Generated Cards** — Claude analyzes your highlighted text and generates multiple card options (Q&A, cloze, bidirectional, diagrams). Cards are atomic, testable, and context-independent without manual effort.

**Browser-Native Workflow** — Highlight text → press Cmd+Shift+M → select from generated cards → done. No context switching, no copy-paste, no manual card writing.

**Multiple Card Styles** — The AI intelligently selects the best format: bidirectional cards for definitions, cloze for lists, explanation cards for concepts, diagram cards for visual learners.

**Learning User Preferences** — Your selection and editing patterns teach Pluckk what cards work for you. Card quality improves over time as your preference profile develops.

## Target Users

- College students learning new subjects
- Young professionals onboarding into an industry
- Lifelong learners reading technical content
- Anyone who reads online and wants to retain what they learn

## User Journey

### Creating Cards (Extension)

```
1. Read an article, documentation, or any webpage
2. Highlight a passage you want to remember
3. Press Cmd+Shift+P (Mac) or Ctrl+Shift+P (Windows)
4. Side panel opens with 3-6 AI-generated card options
5. Select a card, optionally edit the question/answer
6. Select which cards to save
7. Continue reading
```

### Reviewing Cards (Web App)

```
1. Open the Pluckk web app
2. Dashboard shows cards due for review
3. See question, mentally recall the answer
4. Press Space to reveal
5. Rate yourself: Again (forgot) → Easy (trivial)
6. Some spaced repetition algorithm: Currently SM-2 algorithm. But this is matter of active investigation.
7. Repeat until session complete
```

## Card Generation

When you highlight text, Claude analyzes:
- The selected text
- 500 characters of surrounding context
- Page URL and title
- Your preference profile (if established)

It generates 3-6 cards choosing from these styles:

| Style | When Used | Example |
|-------|-----------|---------|
| `qa_bidirectional` | Definitions, term-concept pairs | "What is X?" / "X is the term for ___" |
| `cloze` | Single facts, formulas | "The mitochondria is the ___ of the cell" |
| `cloze_list` | Enumerations, closed lists | "The three branches are ___, ___, and ___" |
| `explanation` | Processes, reasoning | "Why does X cause Y?" |
| `application` | Real-world connections | "How would you apply X to solve...?" |
| `diagram` | Visual concepts (Pro) | AI-generated image with labeled diagram |

## Spaced Repetition

Pluckk uses SM-2, the algorithm behind Anki, with these intervals:

**New Cards:**
- Again → 10 minutes
- Hard → 1 day
- Good → 3 days
- Easy → 7 days

**Review Cards:**
- Again → Back to learning (10 min)
- Hard → interval × 1.2
- Good → interval × ease_factor (starts at 2.5)
- Easy → interval × ease_factor × 1.3

Ease factor adjusts based on performance: drops when you struggle, rises when you succeed.

## Technical Architecture

### Package Structure

```
pluckFull/
├── packages/
│   ├── extension/     # Chrome extension (Manifest V3)
│   ├── webapp/        # React web app (Vite + Tailwind)
│   ├── shared/        # Types, SM-2 algorithm, API client + Google sign-in helpers
│   ├── api/           # Vercel serverless functions + Drizzle schema (Neon Postgres)
│   └── macos/         # Swift app (not yet migrated off Supabase)
└── docs/              # Documentation
```

### System Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         CHROME EXTENSION                                │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────────────────┐  │
│  │   Content    │    │  Background  │    │      Side Panel          │  │
│  │   Script     │───▶│   Worker     │───▶│                          │  │
│  │              │    │              │    │  - Card options          │  │
│  │ - Selection  │    │ - API calls  │    │  - Q&A editing          │  │
│  │ - Context    │    │ - Auth       │    │  - Send to review       │  │
│  │ - URL/Title  │    │ - Storage    │    │                          │  │
│  └──────────────┘    └──────────────┘    └──────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
          │                    │
          │                    ▼
          │         ┌──────────────────┐
          │         │   Vercel API     │
          │         │                  │
          │         │ /generate-cards  │──────▶ Claude API
          │         │ /generate-image  │──────▶ Gemini API
          │         │ /send-to-mochi   │──────▶ Mochi API
          │         │ /v1/auth/google  │──────▶ Google (ID token verify)
          │         │ /v1/cards …      │
          │         │ /v1/review …     │
          │         │ /v1/images       │──────▶ Vercel Blob
          │         └──────────────────┘
          │                    │
          │                    ▼
          │         ┌──────────────────┐
          └────────▶│  Neon Postgres   │◀────── WEB APP (via the same API)
                    │  (Drizzle)       │
                    │ - users, tokens  │
                    │ - cards, folders │
                    │ - review state   │
                    │ - review logs    │
                    └──────────────────┘
                              ▲
                              │
                    ┌──────────────────┐
                    │    WEB APP       │
                    │                  │
                    │ - Review UI      │
                    │ - Card library   │
                    │ - Activity grid  │
                    │ - Settings       │
                    └──────────────────┘
```

### Data Flow: Highlight to Card

```
Webpage
   │ (user highlights text)
   ▼
Content Script
   │ Captures: selection, context (500 chars), URL, title
   │ (chrome.runtime.sendMessage)
   ▼
Background Worker
   │ Adds: auth token, user preferences
   │ (fetch to backend)
   ▼
Vercel API (/api/generate-cards)
   │ Validates auth, checks usage limits
   │ (POST to Claude)
   ▼
Claude Sonnet 4
   │ Analyzes context, generates 4-8 cards as JSON
   │ (response)
   ▼
Background Worker
   │ Fire-and-forget: image generation for diagram cards
   │ (sendResponse)
   ▼
Side Panel
   │ Displays card options, user selects/edits
   │ (user action)
   ▼
POST /api/v1/cards
   └─▶ Card saved to Neon (images → Blob via /api/v1/images)
```

### Data Flow: Review Session

```
Web App loads
   │
   ▼
GET /api/v1/review/queue  (cards + review states + new-cards-reviewed-today)
   │
   ▼
Load session from sessionStorage (if < 24h old)
   │
   ▼
Display card (question only)
   │ (user thinks, presses Space)
   ▼
Reveal answer + rating buttons
   │ (user rates: Again/Hard/Good/Easy)
   ▼
SM-2 calculates next due date (client)
   │
   ▼
POST /api/v1/review → server upserts card_review_state + writes review_logs
   │
   ▼
Next card (or session summary if done)
```

### Key Technologies

| Layer | Technology | Purpose |
|-------|------------|---------|
| Extension | Chrome Manifest V3 | Browser integration |
| Frontend | React 18 + Vite | Web app UI |
| Styling | Tailwind CSS | Utility-first CSS |
| State | React hooks + Context | Local state management |
| Backend | Vercel Functions | Serverless API (`api/v1.ts` routes all `/api/v1/*` data/auth paths) |
| Database | Neon Postgres + Drizzle ORM | Data persistence (`packages/api/db/schema.ts`) |
| Auth | Google Sign-In → Pluckk bearer tokens | One credential for webapp, extension, macOS |
| Files | Vercel Blob | Card images |
| AI | Claude Sonnet 4 | Card generation |
| Images | Gemini API | Diagram generation |

### Database Schema (Simplified)

```sql
-- Core tables
users (id, email, google_sub, username, display_name, mochi_*, learning profile ...)
api_tokens (id, user_id, token_hash, label, last_used_at)
cards (id, user_id, folder_id, question, answer, source_*, image_url, numeric_*, tags ...)
folders (id, user_id, name, color, sort_order)
card_review_state (id, card_id, user_id, status, due_at, interval_days, ease_factor, streak ...)
review_logs (id, card_id, user_id, rating, previous_*, new_*, reviewed_at ...)
algorithm_configs, user_study_settings, study_sessions, user_calibration_stats, feedback, reserved_usernames
```

### Authentication

**Extension:** `chrome.identity.launchWebAuthFlow` → Google (OIDC `id_token`) → `POST /api/v1/auth/google` → bearer token in `chrome.storage.local`

**Web App:** redirect to Google → `/auth/callback` parses `id_token` → same exchange → token in localStorage

**API:** `Authorization: Bearer pk_…` → sha256 lookup in `api_tokens` → every query scoped by `user_id` (no RLS)

### Storage Strategy

| What | Where | Why |
|------|-------|-----|
| API keys, settings | chrome.storage.sync | Syncs across devices |
| Auth session | chrome.storage.local / localStorage | Device-specific, sensitive |
| Review session | sessionStorage | Temporary, survives refresh |
| Folder order | localStorage | UI preference |
| All persistent data | Neon Postgres (via the API) | Source of truth |
| Card images | Vercel Blob | Public URLs stored in `cards.image_url` |

## Development

```bash
# Install dependencies
npm install

# Development (run from root)
npm run dev:extension    # Watch extension
npm run dev:webapp       # Watch web app
npm run dev:api          # Local API (needs packages/api/.env.local: vercel env pull)

# Database (from packages/api)
npm run db:push          # Sync db/schema.ts to Neon
npm run db:studio        # Browse tables

# Build
npm run build:extension
npm run build:webapp

# Load extension in Chrome
# 1. Go to chrome://extensions
# 2. Enable Developer Mode
# 3. Load unpacked → select packages/extension/dist
```

## Integrations

### Mochi (Optional)

Users can export cards to Mochi if they prefer that review system. Configure in extension settings with Mochi API key and deck ID.

### Future

See [roadmap/icebox.md](./roadmap/icebox.md) for planned features including:
- Anki/Mochi deck import
- Mobile app
- Social features (follow, kudos, nudge)
- Knowledge graph visualization
