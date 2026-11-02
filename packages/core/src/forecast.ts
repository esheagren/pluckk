// How many cards each coming day will ask for: reviews of cards already seen, reviews of cards
// still to be introduced, and the new cards themselves. It replays the scheduler assuming every
// review is rated Good, and new cards arriving at each deck's daily limit.
import type { ComponentState } from './entities.js';
import { defaultScheduler, type Scheduler } from './scheduler/index.js';
import { DAY_MS } from './scheduler/constants.js';

export interface ForecastDeck {
  /** Cards not yet seen in this deck. */
  unseen: number;
  /** New cards a day. */
  perDay: number;
  /** New cards already introduced today. */
  usedToday: number;
}

export interface ForecastInput {
  /** Every component reviewed at least once (paused decks left out). */
  states: ComponentState[];
  decks: ForecastDeck[];
  days: number;
  /** Midnight at the start of today, in the person's own time zone. */
  start: Date;
  now: Date;
  scheduler?: Scheduler;
}

export interface ForecastDay {
  day: number;
  /** Reviews of cards seen before today. */
  reviews: number;
  /** Reviews of cards introduced from today on. */
  learned: number;
  /** New cards introduced that day. */
  newCards: number;
}

export function forecastWorkload(input: ForecastInput): ForecastDay[] {
  const scheduler = input.scheduler ?? defaultScheduler;
  const start = input.start.getTime();
  const out: ForecastDay[] = Array.from({ length: input.days }, (_, day) => ({ day, reviews: 0, learned: 0, newCards: 0 }));

  // Follow one card forward, review by review, until it's due past the horizon. Overdue reviews
  // fall on today.
  const follow = (state: ComponentState, key: 'reviews' | 'learned', times: number) => {
    let s = state;
    for (let step = 0; step < 500; step++) {
      const due = Date.parse(s.dueAt);
      const day = Math.max(0, Math.floor((due - start) / DAY_MS));
      if (day >= input.days) return;
      out[day][key] += times;
      s = scheduler.next(s, 'good', new Date(Math.max(due, input.now.getTime())));
    }
  };

  for (const state of input.states) follow(state, 'reviews', 1);

  for (const deck of input.decks) {
    let left = deck.unseen;
    for (let day = 0; day < input.days && left > 0; day++) {
      const n = Math.min(left, Math.max(0, deck.perDay - (day === 0 ? deck.usedToday : 0)));
      if (n === 0) continue;
      left -= n;
      out[day].newCards += n;
      // Cards introduced the same day follow the same path, so one stands for all of them.
      const at = day === 0 ? input.now : new Date(start + day * DAY_MS + 12 * 3600 * 1000);
      follow(scheduler.next(scheduler.initial(at), 'good', at), 'learned', n);
    }
  }
  return out;
}
