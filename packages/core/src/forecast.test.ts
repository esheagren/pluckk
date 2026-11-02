import { describe, expect, it } from 'vitest';
import { forecastWorkload } from './forecast.js';
import { initialComponentState } from './scheduler/index.js';

const START = new Date('2026-11-02T05:00:00.000Z');   // midnight, UTC−5
const NOW = new Date('2026-11-02T15:00:00.000Z');
const reviewed = (dueInDays: number, interval = 10) => ({
  ...initialComponentState(NOW), status: 'review' as const, intervalDays: interval, reviewCount: 3,
  dueAt: new Date(START.getTime() + dueInDays * 86400000 + 3600000).toISOString(), lastReviewedAt: NOW.toISOString(),
});

describe('forecastWorkload', () => {
  it('puts overdue reviews on today and follows each card forward', () => {
    const days = forecastWorkload({ states: [reviewed(-3), reviewed(2)], decks: [], days: 30, start: START, now: NOW });
    expect(days[0].reviews).toBe(1);
    expect(days[2].reviews).toBe(1);
    expect(days.reduce((s, d) => s + d.reviews, 0)).toBeGreaterThan(2);    // each comes back later
  });
  it('introduces new cards at the daily limit, less what today already used', () => {
    const days = forecastWorkload({ states: [], decks: [{ unseen: 12, perDay: 5, usedToday: 3 }], days: 10, start: START, now: NOW });
    expect(days.slice(0, 4).map((d) => d.newCards)).toEqual([2, 5, 5, 0]);
    expect(days.reduce((s, d) => s + d.learned, 0)).toBeGreaterThan(0);
  });
  it('stops at the horizon', () => {
    expect(forecastWorkload({ states: [reviewed(40)], decks: [], days: 30, start: START, now: NOW }).every((d) => d.reviews === 0)).toBe(true);
  });
});
