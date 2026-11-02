// Number cards: you answer with a range you're 95% sure holds the answer, and the range sets the
// rating. Catching the answer with a tight range is strong recall; a wide range or a miss is weak.
import type { Rating } from './entities.js';

/** The confidence a number card asks for. */
export const INTERVAL_CONFIDENCE = 0.95;

export interface IntervalOutcome {
  rating: Rating;
  contained: boolean;
  lower: number;
  upper: number;
  /** Width of the range, and how far outside it the answer fell, both relative to the answer's scale. */
  relativeWidth: number;
  relativeMiss: number;
}

/** Percentages are judged in points of 100; everything else relative to the answer's size. */
export function isPercentUnit(unit: string | null | undefined): boolean {
  return !!unit && /^(%|percent|pct|percentage points?|pp)$/i.test(unit.trim());
}

// Upper limits of relative width for each rating on a hit, and the relative miss that's still "Hard".
const THRESHOLDS = {
  percent: { trivial: 0.03, easy: 0.08, good: 0.2, nearMiss: 0.05 },
  magnitude: { trivial: 0.1, easy: 0.3, good: 1.0, nearMiss: 0.25 },
};

export function rateInterval(answer: number, lower: number, upper: number, unit?: string | null): IntervalOutcome {
  const lo = Math.min(lower, upper);
  const hi = Math.max(lower, upper);
  const contained = answer >= lo && answer <= hi;
  const percent = isPercentUnit(unit);
  const scale = percent ? 100 : Math.abs(answer) || Math.max(Math.abs(lo), Math.abs(hi), 1);
  const relativeWidth = (hi - lo) / scale;
  const relativeMiss = contained ? 0 : Math.min(Math.abs(answer - lo), Math.abs(answer - hi)) / scale;
  const t = percent ? THRESHOLDS.percent : THRESHOLDS.magnitude;

  let rating: Rating;
  if (!contained) rating = relativeMiss <= t.nearMiss ? 'hard' : 'again';
  else if (relativeWidth <= t.trivial) rating = 'trivial';
  else if (relativeWidth <= t.easy) rating = 'easy';
  else if (relativeWidth <= t.good) rating = 'good';
  else rating = 'hard';
  return { rating, contained, lower: lo, upper: hi, relativeWidth, relativeMiss };
}
