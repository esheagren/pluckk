import type { Mechanics, RatingsMap, SM2Config, StatusMap } from './types.js';

export const DEFAULT_CONFIG: SM2Config = {
  initialEase: 2.5,
  minimumEase: 1.3,
  easeBonus: { trivial: 0.25, easy: 0.15, good: 0, hard: -0.15, again: -0.2 },
  intervalMultiplier: { hard: 1.2, easy: 1.3, trivial: 2.6 },
  // Intervals for new/first-time cards (days)
  newCardIntervals: { again: 0.00694, hard: 1, good: 3, easy: 7, trivial: 21 },
  // Graduation intervals for learning/relearning cards (days)
  graduationIntervals: { again: 0.00694, hard: 1, good: 2, easy: 4, trivial: 12 },
  maxIntervalDays: 365,
};

/** Reproduces the pre-core-engine behaviour exactly. */
export const MECHANICS_OFF: Mechanics = {
  growFromElapsed: false,
  retryDelayMinutes: null,
  jitterMaxMinutes: 0,
  dueLookaheadHours: 0,
};

/** Orbit's values. Switched on in step 7 of the core-engine plan. */
export const MECHANICS_ORBIT: Mechanics = {
  growFromElapsed: true,
  retryDelayMinutes: 10,
  jitterMaxMinutes: 10,
  dueLookaheadHours: 16,
};

/** Switched on 2026-09-02 (core-engine step 7). Every review event records the mechanics it used. */
export const DEFAULT_MECHANICS: Mechanics = MECHANICS_ORBIT;

export const RATINGS: RatingsMap = { AGAIN: 'again', HARD: 'hard', GOOD: 'good', EASY: 'easy', TRIVIAL: 'trivial' } as const;
export const STATUS: StatusMap = { NEW: 'new', LEARNING: 'learning', REVIEW: 'review', RELEARNING: 'relearning', SUSPENDED: 'suspended' } as const;

export const ALGORITHM_VERSION = 'sm2-simple-v1.0';
export const SCHEDULER_ID = 'sm2-v2';

export const DAY_MS = 24 * 60 * 60 * 1000;
export const MINUTE_MS = 60 * 1000;
