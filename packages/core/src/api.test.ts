import { describe, expect, it } from 'vitest';
import { cardSpecSchema, createCardBodySchema, parseBody, reviewSubmitBodySchema, sessionRequestBodySchema } from './api.js';

describe('api schemas', () => {
  it('accepts the legacy flat card body and the new spec body', () => {
    expect(parseBody(createCardBodySchema, { question: 'q', answer: 'a', source_url: 'https://x' }).ok).toBe(true);
    expect(parseBody(createCardBodySchema, { spec: { style: 'qa_bidirectional', forward: { question: 'f', answer: 'a' }, reverse: { question: 'r', answer: 'b' } } }).ok).toBe(true);
    const bad = parseBody(createCardBodySchema, { question: 'q' });
    expect(bad.ok).toBe(false);
    if (!bad.ok) expect(bad.error).toMatch(/spec or question\+answer/);
  });
  it('a simple spec may carry modules in its prompt, respond and reveal slots', () => {
    const spec = {
      style: 'qa', question: 'Click on Chengdu', answer: 'Chengdu',
      modules: { respond: { use: 'geo-map@1', props: { map: 'china-provinces', target: { lat: 30.67, lon: 104.07 } } },
                 reveal: [{ use: 'speak@1', props: { text: '成都', lang: 'zh-CN' } }] },
    };
    expect(cardSpecSchema.safeParse(spec).success).toBe(true);
    expect(cardSpecSchema.safeParse({ ...spec, modules: { prompt: [{ use: 'geo-map' }] } }).success).toBe(false);
  });
  it('rejects a spec with an unknown style or an empty list', () => {
    expect(cardSpecSchema.safeParse({ style: 'haiku', question: 'q', answer: 'a' }).success).toBe(false);
    expect(cardSpecSchema.safeParse({ style: 'cloze_list', listName: 'l', items: [], prompts: [] }).success).toBe(false);
  });
  it('review submit requires a uuid and a known rating; component and session are optional', () => {
    const ok = parseBody(reviewSubmitBodySchema, { card_id: '6b1a9f2e-1b2c-4d5e-8f90-abcdefabcdef', rating: 'good' });
    expect(ok.ok).toBe(true);
    const bad = parseBody(reviewSubmitBodySchema, { card_id: 'nope', rating: 'meh' });
    expect(bad.ok).toBe(false);
    if (!bad.ok) expect(bad.error).toMatch(/card_id/);
  });
  it('session request defaults the mode', () => {
    const r = parseBody(sessionRequestBodySchema, {});
    expect(r.ok && r.data.mode).toBe('scheduled');
  });
});
