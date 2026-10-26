// Pluckk API client — the only way clients talk to data after the 2026-08 move
// off Supabase. Framework-agnostic: the caller supplies how to read the bearer
// token (localStorage in the webapp, chrome.storage in the extension).

import { BACKEND_URL } from '../constants/api';
import type { CardSpec, Provenance } from '@pluckk/core/entities';

export interface AuthUser {
  id: string;
  email: string | null;
  display_name: string | null;
  avatar_url: string | null;
  created_at: string;
}

export interface FolderRow {
  id: string; user_id: string; name: string; color: string | null; sort_order: number | null;
  weight: number | null; is_paused: boolean; new_per_day: number | null;
  created_at: string; updated_at: string;
}

export interface CardRow {
  id: string; user_id: string | null; question: string; answer: string;
  source_url: string | null; image_url: string | null; folder_id: string | null;
  style: string | null; answer_type: string | null; tags: string[] | null;
  created_at: string;
  source_selection: string | null; source_context: string | null; source_title: string | null;
  source_selector: string | null; source_text_offset: number | null;
  numeric_answer: number | null; numeric_lower: number | null; numeric_upper: number | null;
  numeric_unit: string | null; numeric_precision: number | null;
  folder?: FolderRow | null;
  due_at?: string | null;
  // core-engine: the authored card and where it came from. question/answer above mirror the first component.
  spec?: CardSpec | null;
  provenance?: Provenance | null;
  capture_key?: string | null;
  is_deleted?: boolean;
}

export interface ReviewStateRow {
  id: string; card_id: string; user_id: string; component_id: string; status: string; due_at: string;
  interval_days: number; ease_factor: number; review_count: number; lapse_count: number; streak: number;
  last_reviewed_at: string | null; created_at: string; updated_at: string;
}

export interface IntervalPreviews { again: string; hard: string; good: string; easy: string }

/** One entry of a card's diary, snake_case on the wire; the rest of the fields depend on `type`. */
export interface CardEventRow {
  id: string; seq: number; card_id: string; user_id: string; at: string;
  type: 'card.ingest' | 'card.review' | 'card.reschedule' | 'card.setDeleted' | 'card.setSpec' | 'card.setProvenance' | 'card.setFolder' | 'card.setTags' | 'card.setImage';
  component_id?: string; rating?: string; session_id?: string | null; response_ms?: number | null;
  is_deleted?: boolean; folder_id?: string | null; tags?: string[]; image_url?: string | null;
  spec?: CardSpec; provenance?: Provenance | null; capture_key?: string | null;
  state?: { status: string; due_at: string; interval_days: number; ease_factor: number; review_count: number };
}

/** One component of one card, rendered for review: what the session deals and what a rating targets. */
export interface ReviewItem extends CardRow {
  card_id: string;
  component_id: string;
  component_count: number;
  is_new: boolean;
  review_state: ReviewStateRow | null;
  previews: IntervalPreviews;
}

export interface ReviewQueue { cards: CardRow[]; states: ReviewStateRow[]; new_reviewed_today: string[] }
export interface ReviewSession {
  cards: CardRow[];
  states: ReviewStateRow[];
  dealt: Array<{ card_id: string; component_id: string }>;
  items: ReviewItem[];
  meta: {
    mode: string;
    per_folder: Record<string, { due: number; new: number; dealt: number }>;
    due_total: number;
    backlog_remaining?: number;
  };
}
export interface ReviewSettings { session_size: number; new_cards_per_day: number }
export interface DeckSummary {
  folder_id: string | null; name: string | null; is_paused: boolean;
  total: number; new: number; due: number;
}
export interface ActivityData {
  reviews: Array<{ review_date: string; total_reviews: number }>;
  cards: Array<{ created_date: string; cards_created: number }>;
}

export interface NewCardInput {
  question: string; answer: string; source_url?: string | null; style?: string | null; tags?: string[] | null;
  folder_id?: string | null; image_url?: string | null;
  source_selection?: string; source_context?: string; source_title?: string;
  source_selector?: string; source_text_offset?: number;
  /** core-engine: send the full card (composites stay one card) and structured provenance. */
  spec?: CardSpec; provenance?: Provenance | null; capture_key?: string | null;
}

export class ApiError extends Error {
  constructor(public status: number, message: string, public body?: unknown) { super(message); }
}

export interface ApiClientOptions {
  baseUrl?: string;
  getToken: () => Promise<string | null> | string | null;
  onUnauthorized?: () => void;
}

export function createApiClient(opts: ApiClientOptions) {
  const base = (opts.baseUrl ?? BACKEND_URL).replace(/\/$/, '');

  async function request<T>(method: string, path: string, body?: unknown, auth = true): Promise<T> {
    const headers: Record<string, string> = { 'Content-Type': 'application/json' };
    if (auth) {
      const token = await opts.getToken();
      if (token) headers.Authorization = `Bearer ${token}`;
    }
    const res = await fetch(`${base}${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
    if (res.status === 401 && auth) opts.onUnauthorized?.();
    const text = await res.text();
    let data: unknown = null;
    try { data = text ? JSON.parse(text) : null; } catch { data = text; }
    if (!res.ok) {
      const msg = (data && typeof data === 'object' && 'error' in data && typeof (data as { error: unknown }).error === 'string')
        ? (data as { error: string }).error : `HTTP ${res.status}`;
      throw new ApiError(res.status, msg, data);
    }
    return data as T;
  }

  const q = (params: Record<string, string | undefined>) => {
    const s = new URLSearchParams();
    for (const [k, v] of Object.entries(params)) if (v !== undefined) s.set(k, v);
    const str = s.toString();
    return str ? `?${str}` : '';
  };

  return {
    request,
    auth: {
      /** Exchange a Google ID token for a Pluckk bearer token. */
      google: (credential: string, client: string) =>
        request<{ token: string; user: AuthUser }>('POST', '/api/v1/auth/google', { credential, client }, false),
      logout: () => request<{ success: true }>('DELETE', '/api/v1/auth/token'),
    },
    user: {
      me: () => request<UserMeResponse>('GET', '/api/user/me'),
      update: (updates: Record<string, unknown>) => request<{ success: true }>('PATCH', '/api/user/me', updates),
    },
    cards: {
      /** `source` = a provenance identifier: every card from one page, app window or imported deck. */
      list: (params: { source_url_prefix?: string; source?: string } = {}) => request<CardRow[]>('GET', `/api/v1/cards${q(params)}`),
      get: (id: string) => request<CardRow>('GET', `/api/v1/cards/${id}`),
      create: (card: NewCardInput) => request<CardRow>('POST', '/api/v1/cards', card),
      update: (id: string, updates: Partial<NewCardInput>) => request<CardRow>('PATCH', `/api/v1/cards/${id}`, updates),
      remove: (id: string) => request<{ success: true; event_id?: string }>('DELETE', `/api/v1/cards/${id}`),
      /** The card's diary, newest first. */
      events: (id: string) => request<{ events: CardEventRow[] }>('GET', `/api/v1/cards/${id}/events`),
    },
    folders: {
      list: () => request<FolderRow[]>('GET', '/api/v1/folders'),
      create: (name: string) => request<FolderRow>('POST', '/api/v1/folders', { name }),
      update: (id: string, updates: { name?: string; color?: string; sort_order?: number; weight?: number | null; is_paused?: boolean; new_per_day?: number | null }) => request<FolderRow>('PATCH', `/api/v1/folders/${id}`, updates),
      remove: (id: string) => request<{ success: true }>('DELETE', `/api/v1/folders/${id}`),
    },
    review: {
      queue: () => request<ReviewQueue>('GET', '/api/v1/review/queue'),
      session: (payload: {
        mode?: 'scheduled' | 'focus' | 'backlog';
        size?: number;
        folder_id?: string | null;
        mix?: Array<{ folder_id: string | null; pct: number }>;
      }) => request<ReviewSession>('POST', '/api/v1/review/session', payload),
      decks: () => request<{ decks: DeckSummary[] }>('GET', '/api/v1/review/decks'),
      settings: () => request<ReviewSettings>('GET', '/api/v1/review/settings'),
      updateSettings: (s: Partial<ReviewSettings>) => request<{ success: true }>('PATCH', '/api/v1/review/settings', s),
      /** The server schedules; send the rating and which component it was. */
      submit: (payload: { card_id: string; component_id?: string; rating: string; session_id?: string | null; response_time_ms?: number }) =>
        request<{ state: ReviewStateRow; component_id: string; previews: IntervalPreviews; event_id: string }>('POST', '/api/v1/review', payload),
      /** Fresh items for saved (card, component) pairs — used to resume a session. */
      items: (items: Array<{ card_id: string; component_id: string }>) =>
        request<{ items: ReviewItem[] }>('POST', '/api/v1/review/items', { items }),
      /** Undo the latest change to a card (a rating, a delete, an edit) by the event id the write returned. */
      undo: (event_id: string) =>
        request<{ card_id: string; component_id: string | null; undone: string; is_deleted: boolean; item: ReviewItem | null }>('POST', '/api/v1/review/undo', { event_id }),
    },
    activity: { get: () => request<ActivityData>('GET', '/api/v1/activity') },
    images: {
      upload: (card_id: string, image_data: string, mime_type: string) =>
        request<{ image_url: string }>('POST', '/api/v1/images', { card_id, image_data, mime_type }),
    },
  };
}

export type ApiClient = ReturnType<typeof createApiClient>;

export interface UserMeResponse {
  user: { id: string; email: string | null; displayName: string | null; avatarUrl: string | null; createdAt: string; isAdmin: boolean };
  settings: { mochiApiKey: string | null; mochiDeckId: string | null };
  learningProfile: Record<string, unknown> & { onboardingCompleted: boolean };
}
