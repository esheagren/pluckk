// Entry for the Mac app's copy of the engine (JavaScriptCore). The snapshot is loaded once and kept
// here; deal/rate/today take and return JSON strings.
import { dealOffline, offlineToday, rateOffline, type Snapshot } from './offline.js';
import type { Rating } from './entities.js';

let snap: Snapshot | null = null;
const need = () => { if (!snap) throw new Error('No offline copy loaded'); return snap; };

const api = {
  load(json: string): number { snap = JSON.parse(json) as Snapshot; return snap.cards.length; },
  deal(opts: string, now: string): string { return JSON.stringify(dealOffline(need(), JSON.parse(opts), new Date(now))); },
  rate(cardId: string, componentId: string, rating: string, now: string): string {
    return JSON.stringify(rateOffline(need(), cardId, componentId, rating as Rating, new Date(now)));
  },
  today(now: string): string { return JSON.stringify(offlineToday(need(), new Date(now))); },
};
(globalThis as unknown as { PluckkCore: typeof api }).PluckkCore = api;
