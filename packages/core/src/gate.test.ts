import { describe, expect, it } from 'vitest';
import { sessionEarnsPass } from './gate.js';

describe('sessionEarnsPass', () => {
  it('a four-minute session with ten cards earns a window', () => {
    expect(sessionEarnsPass(4, 10)).toBe(true);
    expect(sessionEarnsPass(8, 30)).toBe(true);
  });

  it('a shorter session does not', () => {
    expect(sessionEarnsPass(1, 20)).toBe(false);
    expect(sessionEarnsPass(3, 20)).toBe(false);
  });

  it('nor does a timer left running with little done', () => {
    expect(sessionEarnsPass(8, 0)).toBe(false);
    expect(sessionEarnsPass(8, 9)).toBe(false);
  });
});
