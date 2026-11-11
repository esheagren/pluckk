import { describe, expect, it } from 'vitest';
import { studyDayStart } from './day.js';

const NY = 'America/New_York';

describe('studyDayStart', () => {
  it('before 5pm, the day began at 5pm yesterday', () => {
    // 10:00 EST on Nov 10 = 15:00 UTC; yesterday 5pm EST = Nov 9 22:00 UTC.
    expect(studyDayStart(new Date('2026-11-10T15:00:00Z'), NY).toISOString()).toBe('2026-11-09T22:00:00.000Z');
  });

  it('after 5pm, the day began at 5pm today, even past midnight UTC', () => {
    // 20:30 EST on Nov 10 = 01:30 UTC on Nov 11; today 5pm EST = Nov 10 22:00 UTC.
    expect(studyDayStart(new Date('2026-11-11T01:30:00Z'), NY).toISOString()).toBe('2026-11-10T22:00:00.000Z');
  });

  it('exactly 5pm starts a new day', () => {
    expect(studyDayStart(new Date('2026-11-10T22:00:00Z'), NY).toISOString()).toBe('2026-11-10T22:00:00.000Z');
  });

  it('follows daylight time', () => {
    // 18:00 EDT on Jul 1 = 22:00 UTC; 5pm EDT = 21:00 UTC.
    expect(studyDayStart(new Date('2026-07-01T22:00:00Z'), NY).toISOString()).toBe('2026-07-01T21:00:00.000Z');
  });

  it('takes another zone and hour', () => {
    // 03:00 in London (GMT) with a 4am start: the day began at 4am the day before.
    expect(studyDayStart(new Date('2026-01-15T03:00:00Z'), 'Europe/London', 4).toISOString()).toBe('2026-01-14T04:00:00.000Z');
  });
});
