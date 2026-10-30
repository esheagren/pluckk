// Scheduler configuration and the legacy (snake_case) state shapes that the webapp
// and the API have used since the Supabase era. New code uses ComponentState from
// ../entities.ts; these stay so nothing breaks while the engine moves.

import type { CardStatus, Rating } from '../entities.js';
export type { CardStatus, Rating };

export interface EaseBonus { trivial: number; easy: number; good: number; hard: number; again: number }
export interface IntervalMultiplier { hard: number; easy: number; trivial: number }
export interface NewCardIntervals { again: number; hard: number; good: number; easy: number; trivial: number }
export interface GraduationIntervals { again: number; hard: number; good: number; easy: number; trivial: number }

export interface SM2Config {
  /** Initial ease factor for new cards (typically 2.5) */
  initialEase: number;
  /** Minimum ease factor floor (typically 1.3) */
  minimumEase: number;
  /** Ease adjustments per rating */
  easeBonus: EaseBonus;
  /** Interval multipliers for review cards */
  intervalMultiplier: IntervalMultiplier;
  /** Fixed intervals for first-time cards (in days) */
  newCardIntervals: NewCardIntervals;
  /** Graduation intervals for learning cards (in days) */
  graduationIntervals: GraduationIntervals;
  /** Maximum interval cap (in days) */
  maxIntervalDays: number;
}

/**
 * The four mechanics borrowed from Orbit. All off reproduces today's behaviour exactly;
 * they are switched on together in step 7 of the core-engine plan.
 */
export interface Mechanics {
  /** Grow review intervals from the time that actually elapsed since the last review, when that is longer than the scheduled interval. */
  growFromElapsed: boolean;
  /** Minutes until a card rated "again" comes back within the same session (null = the algorithm's own value). */
  retryDelayMinutes: number | null;
  /** Deterministic jitter added to due dates of a day or more, 0–N minutes, so cards don't always arrive in the same order. */
  jitterMaxMinutes: number;
  /** A card due within this many hours counts as due now, so "due later today" is reviewed in today's session. */
  dueLookaheadHours: number;
}

/** Legacy state shape (snake_case), as stored by clients before the core engine. */
export interface CardReviewState {
  interval_days: number;
  ease_factor: number;
  status: CardStatus;
  review_count?: number;
  lapse_count?: number;
  streak?: number;
  last_reviewed_at?: string | null;
}

export interface NextReviewResult {
  interval_days: number;
  ease_factor: number;
  due_at: string;
  status: CardStatus;
}

export interface IntervalPreviews { again: string; hard: string; good: string; easy: string; trivial: string }

export interface RatingsMap { readonly AGAIN: 'again'; readonly HARD: 'hard'; readonly GOOD: 'good'; readonly EASY: 'easy'; readonly TRIVIAL: 'trivial' }
export interface StatusMap { readonly NEW: 'new'; readonly LEARNING: 'learning'; readonly REVIEW: 'review'; readonly RELEARNING: 'relearning'; readonly SUSPENDED: 'suspended' }
