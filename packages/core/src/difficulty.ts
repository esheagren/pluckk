// How hard a deck (or a card) is for this person, from their own ratings, as a number from 0
// (everything known at first sight) to 100 (nothing ever sticks); and from it, how many cards a
// deck may have still being learned before it stops handing out new ones. Pure functions; the API
// feeds them review logs and review states.

import type { Rating } from './entities.js';

/** How much each rating says "this is a struggle". Again is total failure; Trivial is none. */
export const STRUGGLE: Record<Rating, number> = { again: 1, hard: 0.5, good: 0.2, easy: 0.05, trivial: 0 };

/** Recent ratings count more: a rating this old counts half as much as one today. */
export const DIFFICULTY_HALF_LIFE_DAYS = 14;

/** Fewer reviews than this and there's no score yet (and so no cap). */
export const MIN_REVIEWS_FOR_SCORE = 5;

/** A seen card whose next review is under this many days away hasn't stuck yet. */
export const STILL_LEARNING_DAYS = 7;

/** Below this score a deck is easy enough to need no cap. */
export const CAP_FREE_BELOW = 15;

/** Every lapse from this many on (4, 6, 8…) flags the card as a leech. */
export const LEECH_LAPSES = 4;

export interface RatedReview { rating: string; at: string | Date }

/**
 * 0–100, one decimal: 100 × the recency-weighted mean of STRUGGLE over the reviews. Unknown
 * ratings are ignored; null when there are fewer than MIN_REVIEWS_FOR_SCORE.
 */
export function difficultyScore(reviews: RatedReview[], now: Date = new Date()): number | null {
  let weight = 0, sum = 0, n = 0;
  for (const r of reviews) {
    const s = STRUGGLE[r.rating as Rating];
    if (s === undefined) continue;
    const ageDays = Math.max(0, (now.getTime() - new Date(r.at).getTime()) / 86400000);
    const w = Math.pow(0.5, ageDays / DIFFICULTY_HALF_LIFE_DAYS);
    weight += w; sum += w * s; n++;
  }
  if (n < MIN_REVIEWS_FOR_SCORE || weight === 0) return null;
  return Math.round((1000 * sum) / weight) / 10;
}

/**
 * How many cards a deck may have still being learned before new ones stop: none (null) for an
 * easy deck, then shrinking smoothly as the score rises — about ten days' worth of new cards at
 * 15, three and a half at 50, half a day's at 80 — never below 3.
 */
export function learningCap(score: number | null, dailyLimit: number): number | null {
  if (score == null || score < CAP_FREE_BELOW) return null;
  const room = Math.max(0, (100 - score) / (100 - CAP_FREE_BELOW));
  return Math.max(3, Math.round(dailyLimit * 10 * room * room));
}

/**
 * Today's new-card limit for a deck under its cap: what's already been introduced today, plus
 * whatever room the cap leaves, never more than the deck's own limit.
 */
export function gatedNewPerDay(limit: number, newToday: number, cap: number | null, stillLearning: number): number {
  if (cap == null) return limit;
  return Math.min(limit, newToday + Math.max(0, cap - stillLearning));
}

/** True when this review's lapse is one that should flag the card as a leech. */
export function isLeechLapse(previousLapses: number, lapses: number): boolean {
  return lapses > previousLapses && lapses >= LEECH_LAPSES && (lapses - LEECH_LAPSES) % 2 === 0;
}
