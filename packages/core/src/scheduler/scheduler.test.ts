import { describe, expect, it } from 'vitest';
import type { ComponentState, Rating } from '../entities.js';
import { DAY_MS, DEFAULT_CONFIG, MECHANICS_OFF, MECHANICS_ORBIT, MINUTE_MS } from './constants.js';
import {
  calculateNextReview, computeNext, getIntervalDisplay, getRelativeDueDate, initialComponentState,
  isDue, jitterMinutes, previewComponent, previewIntervals,
} from './sm2.js';

const NOW = new Date('2026-09-02T12:00:00.000Z'); // millis % 1000 === 0 → jitter 0
const RATINGS: Rating[] = ['again', 'hard', 'good', 'easy', 'trivial'];

function reviewState(intervalDays: number, ease = 2.5, lastReviewedDaysAgo = intervalDays): ComponentState {
  return {
    ...initialComponentState(NOW),
    status: 'review', intervalDays, easeFactor: ease, reviewCount: 3, streak: 3,
    lastReviewedAt: new Date(NOW.getTime() - lastReviewedDaysAgo * DAY_MS).toISOString(),
  };
}

describe('SM-2 parity with the pre-core-engine behaviour', () => {
  it('a new card takes the fixed first intervals', () => {
    const s = initialComponentState(NOW);
    expect(computeNext(s, 'good', NOW).intervalDays).toBe(3);
    expect(computeNext(s, 'easy', NOW).intervalDays).toBe(7);
    expect(computeNext(s, 'hard', NOW).intervalDays).toBe(1);
    const again = computeNext(s, 'again', NOW);
    expect(again.intervalDays).toBeCloseTo(0.00694);
    expect(again.status).toBe('learning');
    expect(again.easeFactor).toBeCloseTo(2.3);
  });
  it('a learning card graduates on anything but again', () => {
    const s: ComponentState = { ...initialComponentState(NOW), status: 'learning', intervalDays: 0.00694 };
    expect(computeNext(s, 'good', NOW)).toMatchObject({ intervalDays: 2, status: 'review' });
    expect(computeNext(s, 'again', NOW).status).toBe('learning');
  });
  it('trivial pushes a card much further than easy', () => {
    const fresh = initialComponentState(NOW);
    expect(computeNext(fresh, 'trivial', NOW).intervalDays).toBe(21);
    const s = reviewState(10);
    expect(computeNext(s, 'trivial', NOW).intervalDays).toBeCloseTo(10 * 2.75 * 2.6);
    expect(computeNext(reviewState(300), 'trivial', NOW).intervalDays).toBe(DEFAULT_CONFIG.maxIntervalDays);
  });
  it('a review card grows by ease, with hard/easy multipliers', () => {
    const s = reviewState(10);
    expect(computeNext(s, 'good', NOW).intervalDays).toBeCloseTo(25);
    expect(computeNext(s, 'hard', NOW).intervalDays).toBeCloseTo(12);
    expect(computeNext(s, 'hard', NOW).easeFactor).toBeCloseTo(2.35);
    expect(computeNext(s, 'easy', NOW).intervalDays).toBeCloseTo(10 * 2.65 * 1.3);
    const again = computeNext(s, 'again', NOW);
    expect(again.status).toBe('relearning');
    expect(again.intervalDays).toBeCloseTo(0.00694);
  });
  it('caps the interval at the maximum', () => {
    expect(computeNext(reviewState(300), 'easy', NOW).intervalDays).toBe(DEFAULT_CONFIG.maxIntervalDays);
  });
  it('maintains counts: reviews, lapses, streak, last reviewed', () => {
    const s = reviewState(10);
    const good = computeNext(s, 'good', NOW);
    expect(good).toMatchObject({ reviewCount: 4, lapseCount: 0, streak: 4, lastReviewedAt: NOW.toISOString() });
    const again = computeNext(s, 'again', NOW);
    expect(again).toMatchObject({ reviewCount: 4, lapseCount: 1, streak: 0 });
  });
  it('due date is now plus the interval when mechanics are off', () => {
    const next = computeNext(reviewState(10), 'good', NOW);
    expect(new Date(next.dueAt).getTime() - NOW.getTime()).toBeCloseTo(25 * DAY_MS, -3);
  });
  it('previews describe exactly what next() would do', () => {
    const s = reviewState(10);
    const p = previewComponent(s, NOW);
    for (const r of RATINGS) expect(p[r]).toBe(getIntervalDisplay(computeNext(s, r, NOW).intervalDays));
  });
  it('legacy adapters agree with computeNext', () => {
    const legacy = calculateNextReview({ interval_days: 10, ease_factor: 2.5, status: 'review' }, 'good');
    expect(legacy.interval_days).toBeCloseTo(25);
    expect(legacy.status).toBe('review');
    expect(previewIntervals(null).good).toBe('3d');
  });
});

describe('Orbit mechanics', () => {
  it('growFromElapsed credits the interval that actually elapsed', () => {
    const late = reviewState(10, 2.5, 30); // scheduled 10 days, reviewed after 30
    expect(computeNext(late, 'good', NOW, DEFAULT_CONFIG, MECHANICS_OFF).intervalDays).toBeCloseTo(25);
    expect(computeNext(late, 'good', NOW, DEFAULT_CONFIG, MECHANICS_ORBIT).intervalDays).toBeCloseTo(75);
    const early = reviewState(10, 2.5, 2); // reviewed early: never shrinks
    expect(computeNext(early, 'good', NOW, DEFAULT_CONFIG, MECHANICS_ORBIT).intervalDays).toBeCloseTo(25);
  });
  it('retryDelayMinutes brings a failed card back within the session', () => {
    const next = computeNext(reviewState(10), 'again', NOW, DEFAULT_CONFIG, MECHANICS_ORBIT);
    expect(new Date(next.dueAt).getTime() - NOW.getTime()).toBe(10 * MINUTE_MS);
    expect(next.status).toBe('relearning');
  });
  it('jitter is deterministic, bounded, and only applies to intervals of a day or more', () => {
    const t = new Date(NOW.getTime() + 500); // millis % 1000 = 500 → half the max
    expect(jitterMinutes(t, 10)).toBe(5);
    expect(jitterMinutes(NOW, 10)).toBe(0);
    const next = computeNext(reviewState(10), 'good', t, DEFAULT_CONFIG, MECHANICS_ORBIT);
    const drift = new Date(next.dueAt).getTime() - (t.getTime() + next.intervalDays * DAY_MS);
    expect(drift).toBeGreaterThanOrEqual(0);
    expect(drift).toBeLessThanOrEqual(10 * MINUTE_MS);
    const again = computeNext(reviewState(10), 'again', t, DEFAULT_CONFIG, MECHANICS_ORBIT);
    expect(new Date(again.dueAt).getTime() - t.getTime()).toBe(10 * MINUTE_MS);
  });
  it('isDue honours the look-ahead', () => {
    const in10h = { dueAt: new Date(NOW.getTime() + 10 * 60 * MINUTE_MS).toISOString() };
    const in20h = { dueAt: new Date(NOW.getTime() + 20 * 60 * MINUTE_MS).toISOString() };
    expect(isDue(in10h, NOW, MECHANICS_OFF)).toBe(false);
    expect(isDue(in10h, NOW, MECHANICS_ORBIT)).toBe(true);
    expect(isDue(in20h, NOW, MECHANICS_ORBIT)).toBe(false);
  });
});

describe('display helpers', () => {
  it('formats intervals', () => {
    expect(getIntervalDisplay(0.00694)).toBe('10m');
    expect(getIntervalDisplay(0.5)).toBe('12h');
    expect(getIntervalDisplay(3)).toBe('3d');
    expect(getIntervalDisplay(14)).toBe('2w');
    expect(getIntervalDisplay(90)).toBe('3mo');
    expect(getIntervalDisplay(730)).toBe('2.0y');
  });
  it('formats relative due dates', () => {
    expect(getRelativeDueDate(null)).toBe('new');
    expect(getRelativeDueDate(NOW.toISOString(), NOW)).toBe('today');
    expect(getRelativeDueDate(new Date(NOW.getTime() + DAY_MS).toISOString(), NOW)).toBe('tomorrow');
    expect(getRelativeDueDate(new Date(NOW.getTime() - DAY_MS).toISOString(), NOW)).toBe('due');
  });
});
