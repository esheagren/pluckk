// Learning-science statistics from a person's own review history: their forgetting curve, how
// well their ratings predict their memory (calibration), and whether effortful retrieval leads
// to lasting memory. Pure; the API hands in each component's reviews in time order.

const DAY = 86400000;

export interface LoggedReview {
  /** One component's reviews share a key (its review state, or the card for older logs). */
  key: string;
  deck: string | null;
  rating: string;
  at: string | Date;
  /** The interval the review set, in days. */
  newInterval: number | null;
  mode: string;
  /** Time from the card appearing to the answer being revealed, when recorded. */
  revealMs?: number | null;
  /** Time from the card appearing to the rating (includes reading the answer). */
  responseMs?: number | null;
  /** Number cards: whether the 95% range caught the answer. */
  contained?: boolean | null;
}

export interface Rate { n: number; recalled: number; rate: number; lo: number; hi: number }

/** A proportion with its 95% Wilson interval, which stays honest for small n. */
export function wilson(recalled: number, n: number): Rate {
  if (n === 0) return { n, recalled, rate: 0, lo: 0, hi: 0 };
  const z = 1.96, p = recalled / n, z2 = z * z;
  const centre = (p + z2 / (2 * n)) / (1 + z2 / n);
  const half = (z * Math.sqrt((p * (1 - p)) / n + z2 / (4 * n * n))) / (1 + z2 / n);
  return { n, recalled, rate: p, lo: Math.max(0, centre - half), hi: Math.min(1, centre + half) };
}

export const ELAPSED_BUCKETS = [
  { label: '1 day', min: 0.5, max: 1.5 },
  { label: '2–3 days', min: 1.5, max: 3.5 },
  { label: '4–7 days', min: 3.5, max: 7.5 },
  { label: '8–14 days', min: 7.5, max: 14.5 },
  { label: '15–30 days', min: 14.5, max: 30.5 },
  { label: '31+ days', min: 30.5, max: Infinity },
];

export const OVERDUE_BUCKETS = [
  { label: 'early', min: 0, max: 0.85 },
  { label: 'on time', min: 0.85, max: 1.25 },
  { label: '1.25–2×', min: 1.25, max: 2 },
  { label: 'over 2×', min: 2, max: Infinity },
];

const RECALL_RATINGS = ['hard', 'good', 'easy', 'trivial'];

export interface LearningStats {
  forgetting: { deck: string | null; buckets: Array<{ label: string } & Rate> }[];
  overdue: Array<{ label: string } & Rate>;
  calibration: Array<{ rating: string } & Rate>;
  ranges: Rate | null;
  effort: {
    source: 'reveal' | 'response' | null;
    /** Among recalled cards: fast, middle and slow thirds of retrieval time, and how often each was recalled next time. */
    terciles: Array<{ label: string; medianSeconds: number } & Rate>;
    /** Median retrieval time at a card's 1st, 2nd, 3rd… review. */
    byReview: Array<{ review: number; medianSeconds: number; n: number }>;
  };
}

const median = (xs: number[]) => {
  if (!xs.length) return 0;
  const s = [...xs].sort((a, b) => a - b), m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
};

/**
 * reviews must be grouped by key and in time order within each key. Practice reviews (which don't
 * reschedule) are left out, and only spaced reviews (the previous review set a gap of a day or
 * more) feed the forgetting curve.
 */
export function learningStats(reviews: LoggedReview[]): LearningStats {
  const byKey = new Map<string, LoggedReview[]>();
  for (const r of reviews) {
    if (r.mode === 'practice') continue;
    const list = byKey.get(r.key) ?? [];
    list.push(r);
    byKey.set(r.key, list);
  }

  const curve = new Map<string | null, number[][]>();   // deck → per bucket [n, recalled]
  const all: number[][] = ELAPSED_BUCKETS.map(() => [0, 0]);
  const overdue: number[][] = OVERDUE_BUCKETS.map(() => [0, 0]);
  const calibration = new Map<string, number[]>(RECALL_RATINGS.map((r) => [r, [0, 0]]));
  let rangesN = 0, rangesCaught = 0;
  const timed: Array<{ seconds: number; recalledNext: boolean; source: 'reveal' | 'response' }> = [];
  const byReview = new Map<number, number[]>();
  let revealCount = 0;

  for (const list of byKey.values()) {
    list.forEach((r, i) => {
      const prev = list[i - 1], next = list[i + 1];
      const recalled = r.rating !== 'again';
      if (r.mode === 'numeric_interval' && r.contained != null) { rangesN++; if (r.contained) rangesCaught++; }
      if (prev && (prev.newInterval ?? 0) >= 1) {
        const elapsed = (new Date(r.at).getTime() - new Date(prev.at).getTime()) / DAY;
        const b = ELAPSED_BUCKETS.findIndex((x) => elapsed >= x.min && elapsed < x.max);
        if (b >= 0) {
          const deck = curve.get(r.deck) ?? ELAPSED_BUCKETS.map(() => [0, 0]);
          deck[b][0]++; all[b][0]++;
          if (recalled) { deck[b][1]++; all[b][1]++; }
          curve.set(r.deck, deck);
        }
        const ratio = elapsed / (prev.newInterval ?? 1);
        const o = OVERDUE_BUCKETS.findIndex((x) => ratio >= x.min && ratio < x.max);
        if (o >= 0) { overdue[o][0]++; if (recalled) overdue[o][1]++; }
      }
      if (next && RECALL_RATINGS.includes(r.rating) && (r.newInterval ?? 0) >= 1) {
        const c = calibration.get(r.rating)!;
        c[0]++;
        if (next.rating !== 'again') c[1]++;
      }
      const ms = r.revealMs ?? r.responseMs ?? null;
      if (r.revealMs != null) revealCount++;
      if (ms != null && ms >= 300 && ms <= 120000) {
        const seconds = ms / 1000;
        const slot = byReview.get(i + 1) ?? [];
        slot.push(seconds);
        byReview.set(i + 1, slot);
        if (recalled && next && (r.newInterval ?? 0) >= 1) {
          timed.push({ seconds, recalledNext: next.rating !== 'again', source: r.revealMs != null ? 'reveal' : 'response' });
        }
      }
    });
  }

  // Prefer time-to-reveal once there's enough of it; until then, time on the card stands in.
  const source: 'reveal' | 'response' | null = revealCount >= 30 ? 'reveal' : timed.length ? 'response' : null;
  const usable = timed.filter((t) => source === 'reveal' ? t.source === 'reveal' : true).sort((a, b) => a.seconds - b.seconds);
  const third = Math.floor(usable.length / 3);
  const terciles = usable.length >= 30
    ? [['fast', usable.slice(0, third)], ['middle', usable.slice(third, 2 * third)], ['slow', usable.slice(2 * third)]].map(([label, xs]) => {
        const group = xs as typeof usable;
        return { label: label as string, medianSeconds: median(group.map((x) => x.seconds)),
                 ...wilson(group.filter((x) => x.recalledNext).length, group.length) };
      })
    : [];

  const decks = [...curve.entries()]
    .map(([deck, buckets]) => ({ deck, buckets: ELAPSED_BUCKETS.map((b, i) => ({ label: b.label, ...wilson(buckets[i][1], buckets[i][0]) })) }))
    .sort((a, b) => b.buckets.reduce((s, x) => s + x.n, 0) - a.buckets.reduce((s, x) => s + x.n, 0));

  return {
    forgetting: [{ deck: '__all__', buckets: ELAPSED_BUCKETS.map((b, i) => ({ label: b.label, ...wilson(all[i][1], all[i][0]) })) }, ...decks],
    overdue: OVERDUE_BUCKETS.map((b, i) => ({ label: b.label, ...wilson(overdue[i][1], overdue[i][0]) })),
    calibration: RECALL_RATINGS.map((r) => ({ rating: r, ...wilson(calibration.get(r)![1], calibration.get(r)![0]) })),
    ranges: rangesN ? wilson(rangesCaught, rangesN) : null,
    effort: {
      source,
      terciles,
      byReview: [...byReview.entries()].filter(([n]) => n <= 8).sort((a, b) => a[0] - b[0])
        .map(([review, xs]) => ({ review, medianSeconds: Math.round(median(xs) * 10) / 10, n: xs.length })),
    },
  };
}
