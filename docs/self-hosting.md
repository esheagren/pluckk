# Running your own Pluckk

The clients talk to the hosted API at `pluckk-api.vercel.app` by default. To run everything
yourself, you need:

- a Postgres database (Neon works well),
- Vercel Blob storage,
- a Google OAuth client for sign-in,
- an Anthropic API key, and optionally a Gemini key, for card generation.

## 1. API

```bash
cd packages/api
cp .env.example .env.local      # then fill it in (below)
npm run db:migrate              # create the tables (Drizzle migrations in drizzle/)
npm run dev                     # vercel dev on http://localhost:3000
```

| Variable | What it is |
|---|---|
| `DATABASE_URL` | Postgres connection string. Neon's Vercel integration sets it for you. |
| `BLOB_READ_WRITE_TOKEN` | Vercel Blob: card images, and the modules people write themselves. |
| `GOOGLE_CLIENT_IDS` | Comma-separated Google OAuth Web client ID(s) that sign-ins are checked against. |
| `CLAUDE_API_KEY` | Anthropic key for generating cards. |
| `GEMINI_API_KEY` | Optional: Gemini for generating cards from images. |
| `GATE_SECRET` | Optional: signs the passes the site gate hands to browser extensions. Without it, a key is derived from `DATABASE_URL`. |

To deploy, create a Vercel project with `packages/api` as its root, add the same variables, and
run `vercel --prod`. Static files in `public/` (modules, maps, `blocked.html`, `pass.html`) are
served alongside the functions.

## 2. Web app

```bash
VITE_PLUCKK_API_URL=https://your-api.example.com \
VITE_GOOGLE_CLIENT_ID=your-client-id.apps.googleusercontent.com \
npm run build:webapp
```

Deploy `packages/webapp/dist` to any static host, such as a second Vercel project. In your Google
OAuth client, add `https://<your web app>/auth/callback` as an authorised redirect URI, and add
`http://localhost:5173/auth/callback` for local development.

## 3. Mac app

Open `packages/macos/Pluckk/Pluckk.xcodeproj`, set your own signing team and bundle identifier,
and build. Then point it at your servers:

```bash
defaults write com.pluckk.app backendURL https://your-api.example.com
defaults write com.pluckk.app webappURL https://your-webapp.example.com
```

If you changed the bundle identifier, use yours in place of `com.pluckk.app`. Sign-in opens the
web app, which hands a token back to the app through the `pluckk://` URL scheme.

## 4. Chrome extension

Build it with the same `VITE_` variables (`npm run build:extension`), then load
`packages/extension/dist` as an unpacked extension. Add its
`https://<extension-id>.chromiumapp.org/` redirect to your Google OAuth client.
