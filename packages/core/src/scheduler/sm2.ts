// SM-2, as Pluckk has run it since 2025, moved here unchanged in its arithmetic and
// given an explicit `now`, a ComponentState shape, and the four Orbit mechanics
// (all off by default). The legacy snake_case functions at the bottom are what the
// webapp still calls; they are thin adapters over computeNext.

import type { ComponentState, Rating } from '../entities.js';
import { DAY_MS, DEFAULT_CONFIG, DEFAULT_MECHANICS, MINUTE_MS, RATINGS, STATUS } from './constants.js';
import type { CardReviewState, CardStatus, IntervalPreviews, Mechanics, NextReviewResult, SM2Config } from './types.js';

export function initialComponentState(now: Date, config: SM2Config = DEFAULT_CONFIG): ComponentState {
  return {
    status: STATUS.NEW,
    dueAt: now.toISOString(),
    intervalDays: 0,
    easeFactor: config.initialEase,
    stepIndex: 0,
    reviewCount: 0,
    lapseCount: 0,
    streak: 0,
    lastReviewedAt: null,
  };
}

/** Deterministic 0–max minutes derived from the clock, Orbit-style: same input, same jitter. */
export function jitterMinutes(now: Date, maxMinutes: number): number {
  if (maxMinutes <= 0) return 0;
  return ((now.getTime() % 1000) / 1000) * maxMinutes;
}

/**
 * The next state of one component after a rating. Pure: same inputs, same output.
 * Counts (reviewCount, lapseCount, streak, lastReviewedAt) are updated here too, so
 * the reducer and the API never have to agree on them separately.
 */
export function computeNext(
  state: ComponentState,
  rating: Rating,
  now: Date,
  config: SM2Config = DEFAULT_CONFIG,
  mechanics: Mechanics = DEFAULT_MECHANICS,
): ComponentState {
  const currentInterval = state.intervalDays;
  const currentEase = state.easeFactor;
  const currentStatus = state.status;

  let newInterval: number;
  let newEase = currentEase;
  let newStatus: CardStatus;

  const isNewCard = currentStatus === STATUS.NEW || currentInterval === 0;
  const isLearningPhase = currentStatus === STATUS.LEARNING || currentStatus === STATUS.RELEARNING;

  if (isNewCard) {
    newInterval = config.newCardIntervals[rating];
    newStatus = rating === RATINGS.AGAIN ? STATUS.LEARNING : STATUS.REVIEW;
    if (rating === RATINGS.AGAIN) newEase = Math.max(config.minimumEase, currentEase + config.easeBonus.again);
  } else if (isLearningPhase) {
    newInterval = config.graduationIntervals[rating];
    newStatus = rating === RATINGS.AGAIN ? currentStatus : STATUS.REVIEW;
  } else {
    newEase = Math.max(config.minimumEase, currentEase + (config.easeBonus[rating] || 0));
    // Orbit mechanic: credit the interval that actually elapsed when it is longer than the one scheduled.
    let base = currentInterval;
    if (mechanics.growFromElapsed && state.lastReviewedAt) {
      const elapsedDays = (now.getTime() - new Date(state.lastReviewedAt).getTime()) / DAY_MS;
      if (elapsedDays > base) base = elapsedDays;
    }
    switch (rating) {
      case RATINGS.AGAIN:
        newInterval = config.newCardIntervals.again;
        newStatus = STATUS.RELEARNING;
        break;
      case RATINGS.HARD:
        newInterval = Math.max(base * config.intervalMultiplier.hard, 1);
        newStatus = STATUS.REVIEW;
        break;
      case RATINGS.GOOD:
        newInterval = Math.max(base * newEase, 1);
        newStatus = STATUS.REVIEW;
        break;
      case RATINGS.EASY:
        newInterval = Math.max(base * newEase * config.intervalMultiplier.easy, 1);
        newStatus = STATUS.REVIEW;
        break;
      case RATINGS.TRIVIAL:
        newInterval = Math.max(base * newEase * config.intervalMultiplier.trivial, 1);
        newStatus = STATUS.REVIEW;
        break;
      default:
        throw new Error(`Unknown rating: ${rating}`);
    }
  }

  newInterval = Math.min(newInterval, config.maxIntervalDays);

  // Orbit mechanic: a failed card comes back within the session after a fixed delay.
  if (rating === RATINGS.AGAIN && mechanics.retryDelayMinutes != null) {
    newInterval = (mechanics.retryDelayMinutes * MINUTE_MS) / DAY_MS;
  }

  let dueMs = now.getTime() + newInterval * DAY_MS;
  if (newInterval >= 1) dueMs += jitterMinutes(now, mechanics.jitterMaxMinutes) * MINUTE_MS;

  const isAgain = rating === RATINGS.AGAIN;
  return {
    ...state,
    status: newStatus,
    dueAt: new Date(dueMs).toISOString(),
    intervalDays: newInterval,
    easeFactor: newEase,
    reviewCount: state.reviewCount + 1,
    lapseCount: state.lapseCount + (isAgain ? 1 : 0),
    streak: isAgain ? 0 : state.streak + 1,
    lastReviewedAt: now.toISOString(),
  };
}

/** Is this component due for the session starting `now`? Honours the look-ahead mechanic. */
export function isDue(state: Pick<ComponentState, 'dueAt'>, now: Date, mechanics: Mechanics = DEFAULT_MECHANICS): boolean {
  return new Date(state.dueAt).getTime() <= now.getTime() + mechanics.dueLookaheadHours * 60 * MINUTE_MS;
}

// ---------------------------------------------------------------- display

/** "10m", "3h", "5d", "2w", "3mo", "1.5y" */
export function getIntervalDisplay(days: number): string {
  if (days < 0.0007) return '<1m';
  const minutes = days * 24 * 60;
  if (minutes < 60) return `${Math.round(minutes)}m`;
  const hours = minutes / 60;
  if (hours < 24) return `${Math.round(hours)}h`;
  if (days < 7) return `${Math.round(days)}d`;
  const weeks = days / 7;
  if (weeks < 4) return `${Math.round(weeks)}w`;
  const months = days / 30;
  if (months < 12) return `${Math.round(months)}mo`;
  return `${(days / 365).toFixed(1)}y`;
}

/** "today", "tomorrow", "in 3 days", "in 2 weeks", "due", "new" */
export function getRelativeDueDate(dueAt: string | null | undefined, now: Date = new Date()): string {
  if (!dueAt) return 'new';
  const due = new Date(dueAt);
  const nowMidnight = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const dueMidnight = new Date(due.getFullYear(), due.getMonth(), due.getDate());
  const diffDays = Math.round((dueMidnight.getTime() - nowMidnight.getTime()) / DAY_MS);
  if (diffDays < 0) return 'due';
  if (diffDays === 0) return 'today';
  if (diffDays === 1) return 'tomorrow';
  if (diffDays < 7) return `in ${diffDays} days`;
  const weeks = Math.round(diffDays / 7);
  if (weeks < 4) return weeks === 1 ? 'in 1 week' : `in ${weeks} weeks`;
  const months = Math.round(diffDays / 30);
  if (months < 12) return months === 1 ? 'in 1 month' : `in ${months} months`;
  const years = Math.round(diffDays / 365);
  return years === 1 ? 'in 1 year' : `in ${years} years`;
}

export function previewComponent(
  state: ComponentState,
  now: Date,
  config: SM2Config = DEFAULT_CONFIG,
  mechanics: Mechanics = DEFAULT_MECHANICS,
): IntervalPreviews {
  const out = { again: '', hard: '', good: '', easy: '', trivial: '' };
  for (const rating of Object.values(RATINGS) as Rating[]) {
    out[rating] = getIntervalDisplay(computeNext(state, rating, now, config, mechanics).intervalDays);
  }
  return out;
}

// ---------------------------------------------------------------- legacy adapters (snake_case, implicit now)

export function fromLegacyState(s: CardReviewState | null | undefined, now: Date, config: SM2Config = DEFAULT_CONFIG): ComponentState {
  const base = initialComponentState(now, config);
  if (!s) return base;
  return {
    ...base,
    status: s.status ?? base.status,
    intervalDays: s.interval_days ?? 0,
    easeFactor: s.ease_factor ?? config.initialEase,
    reviewCount: s.review_count ?? 0,
    lapseCount: s.lapse_count ?? 0,
    streak: s.streak ?? 0,
    lastReviewedAt: s.last_reviewed_at ?? null,
  };
}

/** @deprecated Use computeNext. Kept so the webapp keeps working until step 3 moves scheduling server-side. */
export function calculateNextReview(
  currentState: CardReviewState | null | undefined,
  rating: Rating,
  config: SM2Config = DEFAULT_CONFIG,
): NextReviewResult {
  const now = new Date();
  const next = computeNext(fromLegacyState(currentState, now, config), rating, now, config, DEFAULT_MECHANICS);
  return { interval_days: next.intervalDays, ease_factor: next.easeFactor, due_at: next.dueAt, status: next.status };
}

/** @deprecated Use previewComponent. */
export function previewIntervals(currentState: CardReviewState | null | undefined, config: SM2Config = DEFAULT_CONFIG): IntervalPreviews {
  const now = new Date();
  return previewComponent(fromLegacyState(currentState, now, config), now, config, DEFAULT_MECHANICS);
}

/** @deprecated Use initialComponentState. */
export function getInitialState(config: SM2Config = DEFAULT_CONFIG): CardReviewState {
  return { interval_days: 0, ease_factor: config.initialEase, status: STATUS.NEW, review_count: 0, lapse_count: 0, streak: 0 };
}
