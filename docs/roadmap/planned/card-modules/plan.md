# Card modules: maps, anatomy, audio, code and whatever comes next

Status: proposed 2026-11-04. Nothing here is built yet beyond the China provinces map data
(`packages/api/public/maps/china-provinces.json`).

## The problem

Every new way of asking a question has so far been hand-built into each client. Number cards
needed core types, two API endpoints, columns on `review_logs` and a SwiftUI view. Map cards,
anatomy, pronunciation and code exercises built that way would each cost the same again, would
exist only on the Mac, and nobody outside the repo could add one.

The aim is the opposite. A new kind of question should be a self-contained **module** that
anyone can write, that every client runs unchanged, and that the scheduler never needs to know
about.

## Layers

| Layer | What it knows | Exists? |
|---|---|---|
| 1. Scheduler and diary | Cards, components, ratings, due dates. Nothing about content. | Yes (`core/reducer`, `core/scheduler`) |
| 2. Card spec | A text fallback plus *module slots*: plain data saying which modules to show and with what props. | Partly (`spec` jsonb) |
| 3. Module host | Runs modules in a sandbox, passes them props and theme, and turns their response into a suggested rating. One host per client. | No |
| 4. Modules | `geo-map`, `model-3d`, `image-regions`, `speak`, `range`, `code`, `typed`… Each is a small web bundle. | No |
| 5. Assets | Map files, 3D models, audio, datasets, versioned and addressed by id. | One map |
| 6. Authoring | Each module's manifest describes its props in plain words, so the assistant, the pluckk-cards skill and a generic form editor can all make cards for any module. | No |

The scheduler (1) only ever receives a rating, as now. A module (4) never sees the user's
account, other cards or the network beyond its own assets.

## The card spec

A simple card keeps `question` and `answer` as a text fallback, so a client that can't run a
module still shows something sensible. Modules go in three slots:

```json
{
  "style": "qa",
  "question": "Which province is highlighted?",
  "answer": "Guangdong · 广东 · Guǎngdōng",
  "modules": {
    "prompt":  [{ "use": "geo-map@1", "props": { "map": "china-provinces", "highlight": "CN-GD" } }],
    "reveal":  [{ "use": "speak@1",   "props": { "text": "广东", "lang": "zh-CN" } }]
  }
}
```

```json
{
  "style": "qa",
  "question": "Click on Chengdu",
  "answer": "Chengdu · 成都 · Chéngdū, capital of Sichuan",
  "modules": {
    "respond": { "use": "geo-map@1", "props": { "map": "china-provinces", "target": { "lat": 30.67, "lon": 104.07 } } },
    "reveal":  [{ "use": "speak@1", "props": { "text": "成都", "lang": "zh-CN" } }]
  }
}
```

- **prompt**: shown with the question. These modules display; they don't answer.
- **respond**: at most one. It *is* the answer: the user acts in it, and it returns a response
  and a score. Without a `respond` module the card is ordinary recall and self-rated.
- **reveal**: shown with the answer, such as audio, a labelled diagram or worked code.

The same module can fill different slots. `geo-map` in `prompt` highlights a region. In
`respond` it asks for a click. A brain in `model-3d` works the same way: highlight a part in
`prompt` ("what is this?"), or name a part and ask for a click in `respond` ("find the
occipital lobe").

Number cards become `respond: range@1` over time. The existing `answerType: 'numeric'` keeps
working until they are migrated.

## The module contract

A module is a folder:

```
geo-map/
  manifest.json
  index.html      (plus its JS/CSS; may bundle libraries like three.js, Pyodide, CodeMirror)
  samples.json    (example props, for the dev harness and for authors)
```

`manifest.json`:

```json
{
  "id": "geo-map",
  "version": "1.0.0",
  "slots": ["prompt", "respond"],
  "describe": "A map from Pluckk's map library. In prompt, highlights a region or marks a point. In respond, asks the user to click a target point or region; scored by distance.",
  "props": { "$schema": "https://json-schema.org/draft/2020-12/schema", "type": "object", "...": "..." },
  "assets": ["maps/*"]
}
```

The host and the module talk only through `postMessage`:

| Direction | Message | Meaning |
|---|---|---|
| host → module | `init { slot, props, theme, textScale, locale }` | Draw yourself. `theme` carries Pluckk's colour tokens so modules match light and dark. |
| host → module | `reveal { }` | The answer is showing. A respond module shows the right answer next to the user's. |
| module → host | `ready { height }`, `resize { height }` | Sizing. |
| module → host | `response { data, score, summary }` | `score` is 0–1. `summary` is a short line such as "212 km away" or "3 of 4 tests passed". |

The host turns the score into a suggested rating, using the same bands everywhere unless the
manifest overrides them. As a starting point: ≥ 0.9 easy, ≥ 0.7 good, ≥ 0.4 hard, otherwise
again. The user can still pick a different rating, as with number cards today. The review log
stores `module`, `response`, `score` and `summary` in one jsonb column, which replaces the
number-specific columns for anything new.

Scores are computed in the module, on the client. These are your own cards, so trusting your
own client is fine. Calibration and stats read the logged score.

## Why modules are web bundles

Each Pluckk client gets a host:

- **Mac:** a single long-lived `WKWebView` that gets new props for each card, so it costs nothing per card.
- **Web app:** a sandboxed `<iframe>`.
- **Extension:** reuses the web app's host if it ever reviews.

The same module code then runs everywhere, and the hard parts are libraries that already exist:

| Module | Built on | Data |
|---|---|---|
| `geo-map` | Canvas or SVG with our own projection (already written for the China map) | Natural Earth (public domain), GeoNames (CC BY) |
| `model-3d` | three.js, glTF models with named parts | BodyParts3D / Z-Anatomy (CC BY-SA). The licence means credit is required and changed models must share alike. |
| `image-regions` | SVG with named regions: an eye cross-section, a diagram, a painting's details | Wikimedia Commons SVGs (per-file licence) or your own |
| `speak` | Web Speech API, which uses the Mac's built-in voices on macOS. Optional recorded audio file. | none |
| `range` | Port of the current number card | none |
| `code` | CodeMirror editor; Python through Pyodide (WebAssembly), JavaScript in a Worker; props carry the tests | none |
| `typed` | Typed answer with fuzzy or pinyin-aware matching | none |

Text-only cards and the existing number cards stay native SwiftUI, so the common case is
unchanged.

**Trade-offs:** a web view is slightly less native-feeling and needs the theme passed in. It
also needs caching for offline use. In return, a module is written once instead of once per
client, and outside authors can write one.

## Safety

- Modules run in a sandbox: no cookies, no Pluckk token and no access to the app.
- A content-security policy limits a module to its own folder and Pluckk's asset store.
- First-party modules ship from `pluckk-api/modules/<id>@<version>/`.
- Third-party modules are installed by URL and pinned to a version. The user approves each one
  once, and the approval shows what it can load.
- Code modules run user code inside that same sandbox (Pyodide/Worker), never on the server.

## Making a new module

1. Copy `modules/_template/`, then write `index.html` against the contract above.
2. Open `modules/harness.html?m=<id>`. It loads every sample in `samples.json`, flips between
   slots and between light and dark, and prints the messages exchanged.
3. Add the manifest's `describe` and `props` schema. That is all the assistant needs to start
   making cards with the module ("make me 30 cards finding these bones on the skeleton").

The contract is small enough that "I want a module that plays a chord and I name it" is a
single request to Claude Code.

## Build order

1. **Spec and API:** add the `modules` slots to the spec schema, and a generic module response
   on `POST review` with a jsonb column.
2. **Mac module host:** WKWebView, theme tokens, sizing, score → suggested rating, plus the
   harness.
3. **First modules:** `speak`, `geo-map` (prompt and respond), with China provinces (34, Taiwan
   included) and China cities.
4. **Chinese characters deck:** 500 most frequent characters, as text cards with `speak` in reveal.
5. **Next modules:** `image-regions`, `model-3d` (anatomy), `code`. Port `range` last.
6. **Web app host:** the iframe version, so module cards practise on the web too.

## Prior art

- **Anki card templates:** HTML/JS per note type. This is how Anki users get maps and image
  occlusion, but nothing flows back to the scheduler except a self-rating.
- **H5P:** open-source, pluggable interactive content types for LMSs. It has a similar
  manifest-and-library idea but no spaced repetition.

Pluckk's angle is the respond slot: a module's score becomes the suggested rating, so map
clicks, code tests and 3D picks drive the schedule directly.
