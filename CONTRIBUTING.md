# Contributing to Pluckk

Thanks for looking. Pluckk is small and opinionated, so the best contributions are focused:

- **A card module.** A new way to show or ask something: a diagram, a simulation, audio, a 3D
  model, a code exercise. These are self-contained and need no change to the app; see below.
- **A fix** with a clear before and after.
- **An idea or a bug report** in Issues. Please describe what you were trying to learn and what
  got in the way, not only what you'd change.

For anything larger, such as a change to the scheduler, the card format or a client's layout,
open an issue first so we can agree on the shape before you spend time on it.

## Working on the code

```bash
npm install
npm run build:core
npm test              # core engine: scheduler, mixer, difficulty, schemas
npm run typecheck     # every package
```

- `packages/core` is pure and tested. Rules about cards and scheduling live there, and clients
  call it rather than re-implementing it. Add a test with any change there.
- The API's routes are all in `packages/api/api/v1.ts`, because the Vercel Hobby plan caps a
  deployment at 12 functions. Request and response schemas live in `packages/core/src/api.ts`.
- The Mac app is SwiftUI. New Swift files have to be added to `project.pbxproj` by hand, or
  through Xcode.
- Keep secrets and personal details out of the repo. Scripts read accounts and keys from the
  environment (see `packages/api/.env.example`).

## Writing a card module

A module is a folder under `packages/api/public/modules/<id>/<major version>/`:

```
my-module/1/
  index.html      the page: one self-contained HTML file
  manifest.json   { id, version, slots, describe, props }
  samples.json    example props, used by the test harness and the assistant
```

The page includes the runtime and answers its messages:

```html
<script src="/modules/pluckk-module.js"></script>
<script>
  Pluckk.on('init', ({ slot, props, theme, revealed }) => {
    // draw from props, then:
    Pluckk.ready();
  });
  // In the respond slot, once the user has answered: Pluckk.respond(data, score0to1, 'summary');
  // Pluckk.on('reveal', () => { show the right answer });
</script>
```

Rules of thumb:

- **Slots.** `prompt` shows something with the question. `respond` is how the card is answered,
  and its 0–1 score suggests the rating. `reveal` shows something with the answer.
- **Props.** Content goes in props, not the page, so one module serves many cards. The same props
  should always draw the same thing, so seed any randomness.
- **Size.** Never scroll: give the page a definite height and call `Pluckk.ready()` once it's
  drawn. The host sizes the page to its content.
- **Colours.** Use the theme's CSS variables: `--text`, `--muted`, `--accent`, `--surface`,
  `--rule`, `--success`, `--warning`. Keep the background transparent.
- **Libraries.** Load them from jsDelivr, cdnjs or unpkg, pinned to an exact version. Modules
  can't send data anywhere.
- **Simulations.** `pluckk-stepper.js` gives a step-through simulation Back, Next and Play
  buttons and captions; `kmeans/1` is an example.

To try a module, run a static server in `packages/api/public` and open
`/modules/harness.html?m=my-module/1`. Then run `node packages/api/scripts/build-module-index.mjs`
so the module appears in the index the assistant reads.

The full design is in [docs/roadmap/planned/card-modules/plan.md](docs/roadmap/planned/card-modules/plan.md).
