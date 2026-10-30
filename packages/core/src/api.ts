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

/** Card spec, wire form (camelCase inside the spec object — it is stored as JSON verbatim). */
export const cardSpecSchema: z.ZodType<CardSpec> = z.discriminatedUnion('style', [
  z.object({
    style: simpleStyleSchema,
    question: z.string().min(1),
    answer: z.string().min(1),
    answerType: z.enum(['text', 'numeric']).optional(),
    numeric: numericSchema.nullish(),
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
});
export type PatchCardBody = z.infer<typeof patchCardBodySchema>;

// ---------------------------------------------------------------- review

/** POST review. `new_state` is the legacy client-computed state; once step 3 lands the server computes it and ignores the field. */
export const reviewSubmitBodySchema = z.object({
  card_id: z.string().uuid(),
  component_id: z.string().min(1).optional(),
  rating: ratingSchema,
  session_id: z.string().nullish(),
  response_time_ms: z.number().int().nonnegative().nullish(),
  algorithm_version: z.string().nullish(),
  new_state: z.object({
    status: cardStatusSchema,
    due_at: z.string(),
    interval_days: z.number(),
    ease_factor: z.number(),
  }).optional(),
});
export type ReviewSubmitBody = z.infer<typeof reviewSubmitBodySchema>;

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
