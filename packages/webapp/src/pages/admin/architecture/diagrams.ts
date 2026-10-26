// Source of truth for the /architecture page. Plain Mermaid text so it can be
// edited here, or live in the page (edits persist in localStorage until "Reset").
// Keep these honest: they describe the system as deployed, not as imagined.

export interface DiagramDef {
  id: string;
  title: string;
  kind: string;          // UML flavour shown as a badge
  summary: string;       // one paragraph shown above the diagram
  source: string;        // Mermaid
}

export const diagrams: DiagramDef[] = [
  {
    id: 'systems',
    title: 'Systems',
    kind: 'UML component / deployment',
    summary:
      'Three clients talk to one API. Nothing else holds credentials: the API is the only thing that ' +
      'reads Neon or writes Blob, and it authorises every query with the caller’s user id.',
    source: `flowchart TB
  subgraph clients["Clients"]
    direction LR
    subgraph ext["Chrome extension (Manifest V3)"]
      direction TB
      cs["Content script<br/>selection · DOM context · annotations"] --> bg["Background worker<br/>API calls · image tasks"] --> sp["Side panel<br/>card options · edit · save"]
    end
    web["Web app · pluckk.app<br/>Vite + React · review · library · settings"]
    mac["macOS app<br/>legacy · still on Supabase · dark"]:::legacy
  end

  google["Google Identity<br/>OIDC id_token"]

  subgraph api["Vercel · pluckk-api (serverless functions)"]
    direction TB
    auth["lib/auth.ts — Bearer pk_… → api_tokens → user"]
    v1["api/v1.ts — auth · cards · folders · review · activity · feedback · images"]
    gen["generate-cards · generate-cards-from-image · answer-question"]
    img["generate-image"]
    mochi["send-to-mochi · import-from-mochi"]
    user["user/me · check-username · profile/:username"]
    auth ~~~ v1 ~~~ gen ~~~ img ~~~ mochi ~~~ user
  end

  subgraph data["Data (owned by the API only)"]
    direction LR
    neon[("Neon Postgres<br/>Drizzle schema")]
    blob[("Vercel Blob<br/>card-images/*.png")]
  end

  subgraph third["Third-party services"]
    direction LR
    claude["Claude API<br/>card generation"]
    gemini["Gemini API<br/>diagram images"]
    mochiapi["Mochi API<br/>optional export"]
  end

  ext -. "sign in → id_token" .-> google
  web -. "sign in → id_token" .-> google
  ext == "Bearer token (chrome.storage)" ==> api
  web == "Bearer token (localStorage)" ==> api
  v1 -- "verify id_token" --> google
  v1 & user & mochi --> neon
  v1 -- "PUT image" --> blob
  gen --> claude
  img --> gemini
  mochi --> mochiapi
  mac -. "direct PostgREST (broken)" .-x data

  classDef legacy stroke-dasharray: 5 5,opacity:0.6;`,
  },
  {
    id: 'capture',
    title: 'Capture flow',
    kind: 'UML sequence',
    summary:
      'A reader highlights text on any page and ends up with a saved card. Card generation is one API ' +
      'call; the save is a second; diagram images are fire-and-forget after the save.',
    source: `sequenceDiagram
  autonumber
  actor U as Reader
  participant P as Web page
  participant CS as Content script
  participant BG as Background worker
  participant SP as Side panel
  participant API as pluckk-api
  participant C as Claude
  participant G as Gemini
  participant DB as Neon
  participant B as Blob

  U->>P: highlight text, press ⌘⇧P
  P->>CS: selection event
  CS->>CS: capture selection, ±500 chars context,<br/>URL, title, CSS selector + text offset
  CS->>BG: sendMessage(selectionData)
  BG->>SP: open side panel with selection
  SP->>BG: generateCards
  BG->>API: POST /api/generate-cards {selection, context, url, title}
  API->>API: authenticate bearer token
  API->>C: system prompt (persona from learning profile) + selection
  C-->>API: 3–6 cards as JSON (qa, cloze, bidirectional, explanation, diagram…)
  API-->>BG: cards
  BG-->>SP: render card options
  U->>SP: pick cards, edit Q/A, (refine: rephrase / simplify / harder)
  SP->>BG: sendToMochi / save {question, answer, source_*}
  BG->>API: POST /api/v1/cards
  API->>DB: INSERT cards (user_id, question, answer, source_url, source_selector…)
  DB-->>API: card row (id)
  API-->>BG: card
  opt diagram card with “generate diagram” checked
    BG->>API: POST /api/generate-image {question, answer, diagram_prompt}
    API->>G: image generation
    G-->>API: PNG (base64)
    API-->>BG: image
    BG->>API: POST /api/v1/images {card_id, image_data}
    API->>B: put card-images/{id}.png (public)
    API->>DB: UPDATE cards SET image_url
  end
  opt Mochi configured
    BG->>API: POST /api/send-to-mochi
    API->>API: create Mochi card with user's key
  end
  BG-->>SP: saved ✓
  U->>P: keep reading (annotation appears in the margin on later visits)`,
  },
  {
    id: 'review',
    title: 'Review flow',
    kind: 'UML sequence + activity',
    summary:
      'A practising user works through the cards that are due. Today the entry is user-initiated ' +
      '(there is no notification system yet — shown dashed as a future trigger). The scheduler runs in ' +
      'the browser; the server records state and history.',
    source: `sequenceDiagram
  autonumber
  actor U as Learner
  participant N as Notification (future)
  participant W as Web app
  participant API as pluckk-api
  participant DB as Neon
  participant S as SM-2 (shared/scheduler)

  N-->>U: “12 cards due today” (not implemented)
  U->>W: open pluckk.app
  W->>W: bearer token in localStorage? else Google sign-in → /auth/callback
  U->>W: pick mode — Mix (proportions) · Focus (one deck) · Backlog (burn down due pile)
  W->>API: POST /api/v1/review/session {mode, size, mix?, folder_id?}
  API->>DB: candidate cards + states + folders (weights, pauses, new/day)
  DB-->>API: rows
  API->>API: mixer: per-deck quotas · due→new fill ·<br/>deficit redistribution · paused decks excluded · interleave
  API-->>W: {dealt cards, states, meta per deck}
  loop each card in queue
    W-->>U: show question (Space to reveal)
    U->>W: reveal
    W->>S: previewIntervals(state) → Again 10m · Hard · Good · Easy
    W-->>U: answer + four buttons with predicted intervals
    U->>W: rate (1–4 or click)
    W->>S: calculateNextReview(state, rating)
    S-->>W: {status, interval_days, ease_factor, due_at}
    W->>API: POST /api/v1/review {card_id, rating, new_state}
    API->>DB: UPSERT card_review_state (counts, streak, lapses)
    API->>DB: INSERT review_logs (previous_* → new_*)
    API-->>W: saved state
    alt rating = Again
      W->>W: re-queue card at end of session
    else
      W->>W: next card
    end
  end
  W-->>U: session summary · activity grid updates (GET /api/v1/activity)`,
  },
  {
    id: 'card-state',
    title: 'Card lifecycle',
    kind: 'UML state machine',
    summary:
      'Every card has exactly one review state per user. The transitions and intervals below are ' +
      'the SM-2 variant in packages/shared/src/scheduler/sm2-simple.ts (ease starts at 2.5, floor 1.3, ' +
      'max interval 365 d).',
    source: `stateDiagram-v2
  [*] --> new : card created<br/>(no review_state row)
  new --> learning : Again · 10 min<br/>ease −0.2
  new --> review : Hard 1 d · Good 3 d · Easy 7 d
  learning --> learning : Again · 10 min
  learning --> review : Hard 1 d · Good 2 d · Easy 4 d<br/>(graduate, no ease change)
  review --> relearning : Again · 10 min<br/>ease −0.2 · lapse_count +1
  review --> review : Hard ×1.2 · Good ×ease · Easy ×ease×1.3<br/>ease −0.15 / 0 / +0.15
  relearning --> relearning : Again · 10 min
  relearning --> review : Hard 1 d · Good 2 d · Easy 4 d
  note right of review
    interval capped at 365 d
    due_at = now + interval
    streak resets on Again
  end note`,
  },
  {
    id: 'card-model',
    title: 'Card model',
    kind: 'UML class',
    summary:
      'What a card is made of, what surrounds it, and who owns each field. The table under the ' +
      'diagram says where every part of a card comes from and what processes it.',
    source: `classDiagram
  direction TB
  class User {
    +uuid id
    +text email
    +text google_sub
    +text username
    +text display_name
    +text mochi_api_key
    +text mochi_deck_id
    +bool onboarding_completed
    +text primary_category
    +text[] work_fields
    +int technicality_preference · 1–4
    +int breadth_preference · 1–4
  }
  class ApiToken {
    +uuid id
    +text token_hash · sha256
    +text label · webapp | extension
    +ts last_used_at
  }
  class Folder {
    +uuid id
    +text name
    +text color
    +int sort_order
  }
  class Card {
    +uuid id
    +text question
    +text answer
    +text style · qa | cloze | bidirectional | explanation | application | diagram
    +text answer_type · text | numeric
    +numeric numeric_answer / lower / upper
    +text numeric_unit
    +text[] tags
    +text source_url
    +text source_title
    +text source_selection
    +text source_context
    +text source_selector
    +int source_text_offset
    +text image_url
    +bool is_public
    +ts created_at
  }
  class CardReviewState {
    +uuid id
    +text status · new | learning | review | relearning
    +ts due_at
    +numeric interval_days
    +numeric ease_factor
    +int review_count
    +int lapse_count
    +int streak
    +numeric stability / difficulty · FSRS, unused
    +ts last_reviewed_at
  }
  class ReviewLog {
    +uuid id
    +text rating · again | hard | good | easy
    +text previous_status
    +numeric previous_interval
    +numeric previous_ease
    +text new_status
    +numeric new_interval
    +numeric new_ease
    +ts new_due
    +text algorithm_version
    +ts reviewed_at
  }
  class AlgorithmConfig {
    +text name
    +text algorithm_type · sm2 | fsrs
    +numeric initial_ease
    +numeric minimum_ease
    +numeric[] learning_steps
    +int max_interval_days
  }

  User "1" --> "*" ApiToken : issues
  User "1" --> "*" Folder : owns
  User "1" --> "*" Card : owns
  Folder "0..1" --> "*" Card : groups
  Card "1" --> "0..1" CardReviewState : per user
  CardReviewState "1" --> "*" ReviewLog : history
  User "1" --> "*" ReviewLog
  User "0..1" --> "*" AlgorithmConfig : custom
  ReviewLog ..> AlgorithmConfig : params snapshot`,
  },
];

/** Where each part of a card comes from and what processes it. */
export const cardFieldProcessing: Array<{ field: string; origin: string; processing: string; consumers: string }> = [
  { field: 'question · answer', origin: 'Claude, from the highlighted text (+ context, title, persona)', processing: 'Prompted for atomic, testable, context-independent cards; user may edit inline or refine (rephrase / simplify / harder = second Claude call). Stored verbatim.', consumers: 'Review card, library, public profile, Mochi export' },
  { field: 'style', origin: 'Claude picks per card', processing: 'qa · cloze · cloze_list · qa_bidirectional (forward + reverse saved as two cards) · explanation · application · diagram (also yields a diagram_prompt).', consumers: 'Side panel rendering; diagram → image pipeline' },
  { field: 'answer_type · numeric_*', origin: 'Claude when the answer is a quantity', processing: 'numeric_answer with optional lower/upper bounds + unit. Review can score an interval answer (calibration fields in card_review_state); default review still uses the 4 buttons.', consumers: 'Review UI (numeric mode), calibration stats' },
  { field: 'tags', origin: 'Claude (content_type, domain, technicality 1–4) · Mochi import adds imported:mochi', processing: 'Stored as text[]; not yet used for scheduling.', consumers: 'Library filters, public cards' },
  { field: 'source_url · source_title', origin: 'Content script from the page', processing: 'URL normalised (hash/query stripped) for annotation matching.', consumers: '“Source” link on the card; annotations on revisit' },
  { field: 'source_selection · source_context', origin: 'Content script: exact highlight + ~500 chars around it', processing: 'Sent to Claude as grounding; stored so the card can show its provenance.', consumers: 'Card detail, refine calls' },
  { field: 'source_selector · source_text_offset', origin: 'Content script: CSS selector of the anchor element + character offset', processing: 'Lets the extension re-highlight the passage and deep-link (?pluckk_card=id) back to it.', consumers: 'annotations.ts on page load; deep links' },
  { field: 'image_url', origin: 'Gemini (diagram cards) or a pasted screenshot', processing: 'Base64 → POST /api/v1/images → Vercel Blob (public, card-images/{id}.png) → URL written back to the card. Fire-and-forget after save.', consumers: 'Review card, library' },
  { field: 'folder_id', origin: 'User (library drag-and-drop) or Mochi deck on import', processing: 'FK to folders; null = unfiled.', consumers: 'Library grouping' },
  { field: 'is_public', origin: 'User toggle', processing: 'Gates inclusion on /u/:username.', consumers: 'Public profile page' },
  { field: 'card_review_state', origin: 'First rating creates it', processing: 'SM-2 in the browser computes status/interval/ease/due; server upserts and maintains review_count, lapse_count, streak, last_reviewed_at.', consumers: 'Queue selection (due_at ≤ now), interval previews, difficulty stats' },
  { field: 'review_logs', origin: 'Every rating', processing: 'Immutable before/after snapshot per review with algorithm_version. Aggregated by day for the activity grid and for the new-cards-per-day cap.', consumers: 'Activity grid, public profile stats, future algorithm tuning' },
];
