import { describe, expect, it } from 'vitest';
import { dealOffline, offlineItem, rateOffline, type Snapshot } from './offline.js';

const now = new Date('2026-11-10T12:00:00Z');
const snap = (): Snapshot => ({
  takenAt: now.toISOString(),
  cards: [
    { id: 'a', folderId: 'f', folderName: 'Deck', createdAt: '2026-10-01T00:00:00Z', spec: { style: 'qa', question: 'Q a', answer: 'A a' }, tags: [], imageUrl: null, provenance: null, sourceUrl: null },
    { id: 'b', folderId: 'f', folderName: 'Deck', createdAt: '2026-10-02T00:00:00Z', spec: { style: 'qa', question: 'Q b', answer: 'A b', modules: { prompt: [{ use: 'speak@1', props: { text: 'hola' } }] } }, tags: [], imageUrl: null, provenance: null, sourceUrl: null },
    { id: 'c', folderId: 'f', folderName: 'Deck', createdAt: '2026-10-03T00:00:00Z', spec: { style: 'qa', question: 'Q c', answer: 'A c' }, tags: [], imageUrl: null, provenance: null, sourceUrl: null },
  ],
  states: [
    { cardId: 'a', componentId: 'main', status: 'review', dueAt: '2026-11-09T00:00:00Z', intervalDays: 3, easeFactor: 2.5, stepIndex: 0, reviewCount: 2, lapseCount: 0, streak: 2, lastReviewedAt: '2026-11-06T00:00:00Z' },
    { cardId: 'c', componentId: 'main', status: 'review', dueAt: '2026-12-01T00:00:00Z', intervalDays: 20, easeFactor: 2.5, stepIndex: 0, reviewCount: 3, lapseCount: 0, streak: 3, lastReviewedAt: '2026-11-01T00:00:00Z' },
  ],
  folders: [{ id: 'f', name: 'Deck', weight: null, isPaused: false, newPerDay: 1 }],
  newToday: {},
  defaultNewPerDay: 3,
  sessionSize: 50,
  userModuleBase: null,
});

describe('offline practice', () => {
  it('deals what is due and the day\'s new cards, not what is not due', () => {
    const ids = dealOffline(snap(), {}, now).map((i) => i!.card_id).sort();
    expect(ids).toEqual(['a', 'b']);
  });
  it('builds items in the API\'s shape, with module sources', () => {
    const item = offlineItem(snap(), 'b', 'main', now)!;
    expect(item.is_new).toBe(true);
    expect(item.modules?.prompt?.[0]).toMatchObject({ use: 'speak@1', src: '/modules/speak/1/index.html' });
  });
  it('rating moves the card on and counts new cards against the day', () => {
    const s = snap();
    const r = rateOffline(s, 'b', 'main', 'good', now);
    expect(r.state.status).toBe('review');
    expect(new Date(r.state.dueAt).getTime()).toBeGreaterThan(now.getTime());
    expect(s.newToday.f).toBe(1);
    expect(dealOffline(s, {}, now).map((i) => i!.card_id)).toEqual(['a']);
  });
});
