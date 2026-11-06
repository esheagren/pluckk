// API URLs and configuration constants

// Build-time overrides for a self-hosted copy (Vite: VITE_PLUCKK_API_URL, VITE_GOOGLE_CLIENT_ID);
// see docs/self-hosting.md. Outside Vite there's no import.meta.env and the defaults apply.
const env: Record<string, string | undefined> = (import.meta as { env?: Record<string, string | undefined> }).env ?? {};

// Backend API (Vercel: data, auth, Claude/Gemini proxies)
export const BACKEND_URL: string = env.VITE_PLUCKK_API_URL || 'https://pluckk-api.vercel.app';

// Google OAuth *Web* client ID used by the webapp (redirect flow) and the
// extension (chrome.identity → accounts.google.com). It is public, not a secret;
// the API verifies ID tokens server-side against GOOGLE_CLIENT_IDS.
// Authorized redirect URIs the client must list:
//   https://pluckk.app/auth/callback
//   http://localhost:5173/auth/callback
//   https://<extension-id>.chromiumapp.org/
export const GOOGLE_CLIENT_ID: string = env.VITE_GOOGLE_CLIENT_ID || '1004228422906-0kq0nd19qgkpqqgpr8kahg0oevro8e3c.apps.googleusercontent.com';

// Direct API URLs (deprecated - use BACKEND_URL for Claude/Gemini)
export const CLAUDE_API_URL: string = 'https://api.anthropic.com/v1/messages';
export const GEMINI_IMAGE_API_URL: string = 'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash-exp:generateContent';

// Mochi API (still called directly with user's own key)
export const MOCHI_API_URL: string = 'https://app.mochi.cards/api';
