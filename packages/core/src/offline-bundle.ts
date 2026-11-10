// Entry for the Mac app's copy of the engine (JavaScriptCore): JSON in, JSON out.
import { dealOffline, offlineToday, rateOffline, type Snapshot } from './offline.js';
import type { Rating } from './entities.js';

const api = {
  deal(snapshot: string, opts: string, now: string): string {
    return JSON.stringify(dealOffline(JSON.parse(snapshot) as Snapshot, JSON.parse(opts), new Date(now)));
  },
  /** Returns { snapshot, state, previews }: the snapshot comes back changed. */
  rate(snapshot: string, cardId: string, componentId: string, rating: string, now: string): string {
    const snap = JSON.parse(snapshot) as Snapshot;
    const r = rateOffline(snap, cardId, componentId, rating as Rating, new Date(now));
    return JSON.stringify({ snapshot: snap, ...r });
  },
  today(snapshot: string, now: string): string {
    return JSON.stringify(offlineToday(JSON.parse(snapshot) as Snapshot, new Date(now)));
  },
};
(globalThis as unknown as { PluckkCore: typeof api }).PluckkCore = api;
