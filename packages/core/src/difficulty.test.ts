import { describe, expect, it } from 'vitest';
import { difficultyScore, gatedNewPerDay, isLeechLapse, learningCap } from './difficulty.js';

const now = new Date('2026-11-05T12:00:00Z');
const at = (daysAgo: number) => new Date(now.getTime() - daysAgo * 86400000).toISOString();
const many = (rating: string, n: number, daysAgo = 0) => Array.from({ length: n }, () => ({ rating, at: at(daysAgo) }));

describe('difficulty score', () => {
  it('runs from 0 (all trivial) to 100 (all again)', () => {
    expect(difficultyScore(many('trivial', 10), now)).toBe(0);
    expect(difficultyScore(many('again', 10), now)).toBe(100);
    expect(difficultyScore(many('good', 10), now)).toBe(20);
  });
  it('needs a few reviews before it says anything', () => {
    expect(difficultyScore(many('again', 4), now)).toBeNull();
  });
  it('weights recent reviews more', () => {
    const recentFails = [...many('again', 5, 0), ...many('easy', 5, 60)];
    const oldFails = [...many('again', 5, 60), ...many('easy', 5, 0)];
    expect(difficultyScore(recentFails, now)!).toBeGreaterThan(80);
    expect(difficultyScore(oldFails, now)!).toBeLessThan(20);
  });
  it('ignores ratings it does not know', () => {
    expect(difficultyScore([...many('again', 5), { rating: 'meh', at: at(0) }], now)).toBe(100);
  });
});

describe('learning cap', () => {
  it('leaves easy decks alone', () => {
    expect(learningCap(null, 5)).toBeNull();
    expect(learningCap(8, 21)).toBeNull();
  });
  it('shrinks smoothly as the deck gets harder, never below 3', () => {
    expect(learningCap(15, 5)).toBe(70);
    expect(learningCap(40, 1)).toBe(7);     // an ordinary deck at 1 a day: about a week's worth
    expect(learningCap(50, 5)).toBe(24);
    expect(learningCap(80, 5)).toBe(4);
    expect(learningCap(84, 5)).toBe(3);
    expect(learningCap(99, 20)).toBe(3);
    expect(learningCap(40, 5)!).toBeGreaterThan(learningCap(60, 5)!);
  });
});

describe('gated limit', () => {
  it('is the deck limit when there is no cap', () => {
    expect(gatedNewPerDay(5, 0, null, 40)).toBe(5);
  });
  it('lets new cards in only while the deck is under its cap', () => {
    expect(gatedNewPerDay(5, 0, 3, 5)).toBe(0);
    expect(gatedNewPerDay(5, 0, 3, 1)).toBe(2);
    expect(gatedNewPerDay(5, 2, 3, 3)).toBe(2);   // two already introduced today stay counted
    expect(gatedNewPerDay(5, 0, 30, 0)).toBe(5);  // never past the deck's own limit
  });
});

describe('leech', () => {
  it('flags at the 4th lapse and every second one after', () => {
    expect(isLeechLapse(2, 3)).toBe(false);
    expect(isLeechLapse(3, 4)).toBe(true);
    expect(isLeechLapse(4, 5)).toBe(false);
    expect(isLeechLapse(5, 6)).toBe(true);
    expect(isLeechLapse(4, 4)).toBe(false);   // no new lapse this review
  });
});
