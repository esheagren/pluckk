import { describe, expect, it } from 'vitest';
import { learningStats, wilson, type LoggedReview } from './learning.js';

const t0 = new Date('2026-10-01T09:00:00Z').getTime();
const day = 86400000;
const r = (key: string, dayN: number, rating: string, newInterval: number, extra: Partial<LoggedReview> = {}): LoggedReview =>
  ({ key, deck: 'D', rating, at: new Date(t0 + dayN * day).toISOString(), newInterval, mode: 'standard', ...extra });

describe('wilson interval', () => {
  it('brackets the rate and stays inside 0–1', () => {
    const w = wilson(9, 10);
    expect(w.rate).toBe(0.9);
    expect(w.lo).toBeGreaterThan(0.5);
    expect(w.hi).toBeLessThanOrEqual(1);
    expect(wilson(0, 0).n).toBe(0);
  });
});

describe('learning stats', () => {
  const reviews = [
    r('a', 0, 'good', 3), r('a', 3, 'good', 8), r('a', 11, 'again', 0.007), r('a', 11.01, 'good', 1), r('a', 12, 'easy', 10),
    r('b', 0, 'easy', 7), r('b', 7, 'good', 18), r('b', 25, 'good', 40),
    r('c', 0, 'good', 3, { mode: 'practice' }),
  ];
  const s = learningStats(reviews);

  it('puts spaced reviews in elapsed-time buckets', () => {
    const all = s.forgetting[0].buckets;
    expect(all.find((b) => b.label === '2–3 days')!.n).toBe(1);       // a: day 0 → 3
    expect(all.find((b) => b.label === '8–14 days')!).toMatchObject({ n: 1, recalled: 0 });  // a: 3 → 11, forgot
    expect(all.find((b) => b.label === '15–30 days')!.n).toBe(1);     // b: 7 → 25
  });

  it('skips practice and same-day relearning steps', () => {
    const total = s.forgetting[0].buckets.reduce((x, b) => x + b.n, 0);
    expect(total).toBe(5);   // a: 3, 11, 12 (after the day-long relearning gap); b: 7, 25
  });

  it('calibrates each rating against the next review', () => {
    const good = s.calibration.find((c) => c.rating === 'good')!;
    expect(good.n).toBe(4);          // a 0, a 3, a 11.01, b 7
    expect(good.recalled).toBe(3);   // a 3 → again at 11
    expect(s.calibration.find((c) => c.rating === 'easy')!.n).toBe(1);
  });
});
