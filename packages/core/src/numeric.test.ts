import { describe, expect, it } from 'vitest';
import { isPercentUnit, rateInterval } from './numeric.js';

describe('rateInterval', () => {
  it('rates a hit by how tight the range is, relative to the answer', () => {
    expect(rateInterval(34, 33, 35, 'GJ').rating).toBe('trivial');   // width 2/34
    expect(rateInterval(34, 30, 40, 'GJ').rating).toBe('easy');      // 10/34
    expect(rateInterval(34, 20, 50, 'GJ').rating).toBe('good');      // 30/34
    expect(rateInterval(34, 5, 100, 'GJ').rating).toBe('hard');      // 95/34
  });
  it('rates a miss by how far out it fell', () => {
    expect(rateInterval(34, 36, 40, 'GJ')).toMatchObject({ rating: 'hard', contained: false });   // 2/34 out
    expect(rateInterval(34, 50, 60, 'GJ')).toMatchObject({ rating: 'again', contained: false });
  });
  it('judges percentages in points', () => {
    expect(rateInterval(89, 87, 90, '%').rating).toBe('trivial');
    expect(rateInterval(89, 80, 95, '%').rating).toBe('good');
    expect(rateInterval(89, 50, 95, '%').rating).toBe('hard');
    expect(rateInterval(89, 90, 93, '%').rating).toBe('hard');      // 1 point out
    expect(rateInterval(89, 60, 75, '%').rating).toBe('again');
  });
  it('accepts bounds in either order and includes the ends', () => {
    expect(rateInterval(10, 12, 10, null)).toMatchObject({ contained: true, lower: 10, upper: 12 });
  });
  it('copes with an answer of zero', () => {
    expect(rateInterval(0, -0.5, 0.5, null).contained).toBe(true);
  });
  it('recognises percent units', () => {
    expect(isPercentUnit('%')).toBe(true);
    expect(isPercentUnit(' percent ')).toBe(true);
    expect(isPercentUnit('GJ')).toBe(false);
  });
});
