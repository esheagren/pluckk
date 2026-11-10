// Wire shapes for /api/v1, as zod schemas. The API validates requests against
// these; the client imports the inferred types. Wire keys are snake_case (the
// Supabase-era convention every client speaks); core values are camelCase — the
// converters at the bottom are the only place the two meet.

import { z } from 'zod';
import type { CardSpec, Provenance } from './entities.js';

// ---------------------------------------------------------------- primitives

export const ratingSchema = z.enum(['again', 'hard', 'good', 'easy', 'trivial']);
export const cardStatusSchema = z.enum(['new', 'learning', 'review', 'relearning', 'suspended']);
export const simpleStyleSchema = z.enum(['qa', 'cloze', 'explanation', 'application', 'diagram']);

const qaSchema = z.object({ question: z.string().min(1), answer: z.string().min(1) });

const numericSchema = z.object({
  value: z.number(),
  lower: z.number().nullish(),
  upper: z.number().nullish(),
  unit: z.string().nullish(),
  precision: z.number().int().nullish(),
});

const moduleUseSchema = z.object({
  // A built-in module ("geo-map@1") or one of the user's own ("me/gradient-descent@2").
  use: z.string().regex(/^(me\/)?[a-z0-9-]+@\d+$/, 'use is "<module id>@<major version>" or "me/<slug>@<version>"'),
  props: z.record(z.string(), z.unknown()).optional(),
});

export const modulesSchema = z.object({
  prompt: z.array(moduleUseSchema).max(4).optional(),
  respond: moduleUseSchema.nullish(),
  reveal: z.array(moduleUseSchema).max(4).optional(),
});

/** Card spec, wire form (camelCase inside the spec object — it is stored as JSON verbatim). */
export const cardSpecSchema: z.ZodType<CardSpec> = z.discriminatedUnion('style', [
  z.object({
    style: simpleStyleSchema,
    question: z.string().min(1),
    answer: z.string().min(1),
    // written: the answer is typed out in full and checked by a model against the card's answer.
    answerType: z.enum(['text', 'numeric', 'written']).optional(),
    numeric: numericSchema.nullish(),
    modules: modulesSchema.nullish(),
  }),
  z.object({ style: z.literal('qa_bidirectional'), forward: qaSchema, reverse: qaSchema }),
  z.object({ style: z.literal('cloze_list'), listName: z.string(), items: z.array(z.string()), prompts: z.array(qaSchema).min(1) }),
]) as z.ZodType<CardSpec>;

export const textQuoteSelectorSchema = z.object({
  type: z.literal('TextQuote'),
  exact: z.string(),
  prefix: z.string().nullish(),
  suffix: z.string().nullish(),
});

export const provenanceSchema: z.ZodType<Provenance> = z.object({
  identifier: z.string().min(1),
  url: z.string().nullish(),
  title: z.string().nullish(),
  containerTitle: z.string().nullish(),
  selector: textQuoteSelectorSchema.nullish(),
  selection: z.string().nullish(),
  context: z.string().nullish(),
});

// ---------------------------------------------------------------- cards

/** POST cards. Either the new form (spec + provenance) or the legacy flat form; both snake_case at the top level. */
export const createCardBodySchema = z.object({
  // new form
  spec: cardSpecSchema.optional(),
  provenance: provenanceSchema.nullish(),
  capture_key: z.string().nullish(),
  // legacy flat form
  question: z.string().optional(),
  answer: z.string().optional(),
  style: z.string().nullish(),
  answer_type: z.string().nullish(),
  numeric_answer: z.number().nullish(),
  numeric_lower: z.number().nullish(),
  numeric_upper: z.number().nullish(),
  numeric_unit: z.string().nullish(),
  numeric_precision: z.number().int().nullish(),
  source_url: z.string().nullish(),
  source_title: z.string().nullish(),
  source_selection: z.string().nullish(),
  source_context: z.string().nullish(),
  source_selector: z.string().nullish(),
  source_text_offset: z.number().int().nullish(),
  // common
  folder_id: z.string().uuid().nullish(),
  tags: z.array(z.string()).nullish(),
  image_url: z.string().nullish(),
  modules: modulesSchema.nullish(),
}).refine((b) => b.spec || (b.question && b.answer), { message: 'spec or question+answer required' });
export type CreateCardBody = z.infer<typeof createCardBodySchema>;

export const patchCardBodySchema = z.object({
  spec: cardSpecSchema.optional(),
  provenance: provenanceSchema.nullish(),
  question: z.string().optional(),
  answer: z.string().optional(),
  style: z.string().nullish(),
  folder_id: z.string().uuid().nullish(),
  tags: z.array(z.string()).nullish(),
  image_url: z.string().nullish(),
  source_url: z.string().nullish(),
  source_title: z.string().nullish(),
  // Turning a card into a number card, or back: answer_type 'numeric' with its value and unit.
  answer_type: z.string().nullish(),
  numeric_answer: z.number().nullish(),
  numeric_unit: z.string().nullish(),
  // A simple card's modules (see CardModules); null removes them all.
  modules: modulesSchema.nullish(),
});
export type PatchCardBody = z.infer<typeof patchCardBodySchema>;

// ---------------------------------------------------------------- review

/** POST review. `new_state` is the legacy client-computed state; once step 3 lands the server computes it and ignores the field. */
const intervalSchema = z.object({ lower: z.number().finite(), upper: z.number().finite() });

/** POST review. A number card can send its range instead of (or as well as) a rating. */
export const reviewSubmitBodySchema = z.object({
  card_id: z.string().uuid(),
  component_id: z.string().min(1).optional(),
  rating: ratingSchema.optional(),
  interval: intervalSchema.optional(),
  session_id: z.string().nullish(),
  response_time_ms: z.number().int().nonnegative().nullish(),
  // Time from the card appearing to the answer being revealed: how long retrieval took.
  reveal_ms: z.number().int().nonnegative().nullish(),
  // When the rating happened, for one made offline and sent later (ISO). Omitted means now.
  at: z.string().datetime({ offset: true }).nullish(),
  // Off-schedule practice: logged, but due dates stay put (an "again" brings the card back tomorrow).
  practice: z.boolean().optional(),
  algorithm_version: z.string().nullish(),
  new_state: z.object({
    status: cardStatusSchema,
    due_at: z.string(),
    interval_days: z.number(),
    ease_factor: z.number(),
  }).optional(),
});
export type ReviewSubmitBody = z.infer<typeof reviewSubmitBodySchema>;

/** POST review/practice: cards to practise now, whatever their schedule. */
export const practiceBodySchema = z.object({
  folder_id: z.string().uuid().nullish(),      // a deck; null is unfiled; omitted with card_ids
  card_ids: z.array(z.string().uuid()).max(500).optional(),
  filter: z.enum(['all', 'learned', 'missed']).optional(),   // missed: rated again or hard in the last 30 days
  size: z.number().int().min(1).max(500).optional(),
}).refine((b) => b.card_ids?.length || b.folder_id !== undefined, { message: 'folder_id or card_ids required' });
export type PracticeBody = z.infer<typeof practiceBodySchema>;

/** POST review/score: what a range would be rated, without recording anything. */
export const intervalScoreBodySchema = z.object({ card_id: z.string().uuid(), interval: intervalSchema });

export const reviewUndoBodySchema = z.object({ event_id: z.string().uuid() });
export type ReviewUndoBody = z.infer<typeof reviewUndoBodySchema>;

export const sessionRequestBodySchema = z.object({
  mode: z.enum(['scheduled', 'focus', 'backlog', 'ahead']).default('scheduled'),
  size: z.number().int().positive().max(500).optional(),
  folder_id: z.string().uuid().nullish(),
  mix: z.array(z.object({ folder_id: z.string().uuid().nullable(), pct: z.number().nonnegative() })).optional(),
});
export type SessionRequestBody = z.infer<typeof sessionRequestBodySchema>;

export const settingsPatchBodySchema = z.object({
  session_size: z.number().int().positive().max(500).optional(),
  default_new_per_day: z.number().int().nonnegative().optional(),
});
export type SettingsPatchBody = z.infer<typeof settingsPatchBodySchema>;

// ---------------------------------------------------------------- folders

export const folderBodySchema = z.object({
  name: z.string().min(1).optional(),
  weight: z.number().nonnegative().nullish(),
  is_paused: z.boolean().optional(),
  new_per_day: z.number().int().nonnegative().nullish(),
});
export type FolderBody = z.infer<typeof folderBodySchema>;

// ---------------------------------------------------------------- helpers

export type ParseResult<T> = { ok: true; data: T } | { ok: false; error: string };

/** Parse a request body; the error string is what the API returns as `{ error }`. */
export function parseBody<T>(schema: z.ZodType<T>, body: unknown): ParseResult<T> {
  const r = schema.safeParse(body ?? {});
  if (r.success) return { ok: true, data: r.data };
  const first = r.error.issues[0];
  return { ok: false, error: first ? `${first.path.join('.') || 'body'}: ${first.message}` : 'Invalid body' };
}
