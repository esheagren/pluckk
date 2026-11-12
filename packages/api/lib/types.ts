/**
 * Type definitions for API request/response types
 */

import type { VercelRequest, VercelResponse } from '@vercel/node';
import type { User as DbUser } from '../db/schema.js';

/**
 * Vercel API handler type
 */
export type ApiHandler = (
  req: VercelRequest,
  res: VercelResponse
) => Promise<void> | void;

/**
 * User profile from database
 */
export type PrimaryCategory = 'student' | 'worker' | 'researcher';
export type StudentLevel = 'high_school' | 'college' | 'medical_school' | 'law_school' | 'graduate_school' | 'other';
export type WorkField = 'consulting' | 'engineering' | 'product' | 'finance' | 'marketing' | 'design' | 'sales' | 'operations' | 'legal' | 'healthcare' | 'education' | 'other';
export type YearsExperience = '1-2' | '3-5' | '6-10' | '10+';
export type SpacedRepExperience = 'none' | 'tried' | 'regular' | 'power_user';
export type TechnicalityLevel = 1 | 2 | 3 | 4;
export type BreadthLevel = 1 | 2 | 3 | 4;

export interface UserProfile {
  id: string;
  email?: string;
  display_name?: string | null;
  avatar_url?: string | null;
  created_at?: string;
  updated_at?: string;
  mochi_api_key?: string | null;
  mochi_deck_id?: string | null;
  // Onboarding & learning profile
  onboarding_completed?: boolean;
  primary_category?: PrimaryCategory | null;
  student_level?: StudentLevel | null;
  student_field?: string | null;
  work_fields?: WorkField[] | null;
  work_field_other?: string | null;
  work_years_experience?: YearsExperience | null;
  research_field?: string | null;
  research_years_experience?: YearsExperience | null;
  additional_interests?: string[] | null;
  additional_interests_other?: string | null;
  // Learning preferences
  spaced_rep_experience?: SpacedRepExperience | null;
  technicality_preference?: TechnicalityLevel | null;
  breadth_preference?: BreadthLevel | null;
}

/**
 * Authentication result - success case
 */
export interface AuthSuccess {
  user: DbUser;
  profile: DbUser;
  error?: undefined;
  status?: undefined;
}

/**
 * Authentication result - error case
 */
export interface AuthError {
  error: string;
  status: number;
  user?: undefined;
  profile?: undefined;
}

/**
 * Combined authentication result type
 */
export type AuthResult = AuthSuccess | AuthError;

/**
 * Generate cards request body
 */
export interface GenerateCardsRequest {
  selection: string;
  context?: string;
  url?: string;
  title?: string;
  focusText?: string;
  customPrompt?: string;
  // Per-card refinement (when present, takes the refinement path instead of full generation)
  refineCard?: GeneratedCard;
  refinementAction?: 'rephrase' | 'simplify' | 'harder';
  sourceSelection?: string;
  sourceContext?: string;
}

/**
 * Page context for image-based card generation
 */
export interface PageContext {
  domContext: {
    headings: string[];
    visibleText: string;
    url: string;
    title: string;
  };
  viewportScreenshot?: {
    imageData: string;
    mimeType: string;
  };
}

/**
 * Generate cards from image request body
 */
export interface GenerateCardsFromImageRequest {
  imageData: string;
  mimeType: string;
  focusText?: string;
  pageContext?: PageContext;
}

/**
 * Generate image request body
 */
export interface GenerateImageRequest {
  question: string;
  answer: string;
  sourceUrl?: string;
  diagramPrompt?: string;
}

/**
 * Answer question request body
 */
export interface AnswerQuestionRequest {
  question: string;
  url?: string;
  title?: string;
}

/**
 * Send to Mochi request body
 */
export interface SendToMochiRequest {
  question: string;
  answer: string;
  sourceUrl?: string;
  imageData?: string;
  imageMimeType?: string;
}

/**
 * Attach Mochi image request body
 */
export interface AttachMochiImageRequest {
  cardId: string;
  imageData: string;
  imageMimeType: string;
  originalContent?: string;
}

/**
 * Checkout request body
 */
export interface CheckoutRequest {
  successUrl?: string;
  cancelUrl?: string;
}

/**
 * Portal request body
 */
export interface PortalRequest {
  returnUrl?: string;
}

/**
 * User settings update request body
 */
export interface UpdateUserSettingsRequest {
  mochiApiKey?: string | null;
  mochiDeckId?: string | null;
  displayName?: string | null;
  // Learning profile fields
  onboardingCompleted?: boolean;
  primaryCategory?: PrimaryCategory | null;
  studentLevel?: StudentLevel | null;
  studentField?: string | null;
  workFields?: WorkField[] | null;
  workFieldOther?: string | null;
  workYearsExperience?: YearsExperience | null;
  researchField?: string | null;
  researchYearsExperience?: YearsExperience | null;
  additionalInterests?: string[] | null;
  additionalInterestsOther?: string | null;
  // Learning preferences
  spacedRepExperience?: SpacedRepExperience | null;
  technicalityPreference?: TechnicalityLevel | null;
  breadthPreference?: BreadthLevel | null;
}

/**
 * Standard API success response
 */
export interface ApiSuccessResponse<T = unknown> {
  success: true;
  data?: T;
}

/**
 * Standard API error response
 */
export interface ApiErrorResponse {
  error: string;
  message?: string;
  code?: string;
  details?: string;
}

/**
 * Cards generation response
 */
export interface GenerateCardsSuccessResponse {
  cards: GeneratedCard[];
}

/**
 * Generated card from Claude (raw format before normalization)
 */
export interface GeneratedCard {
  style: string;
  question?: string;
  answer?: string;
  forward?: { question: string; answer: string };
  reverse?: { question: string; answer: string };
  text?: string;
  cloze_deletions?: string[];
  list_name?: string;
  items?: string[];
  prompts?: Array<{ question: string; answer: string }>;
  diagram_prompt?: string;
  rationale?: string;
  originalQuestion?: string;
  wasImproved?: boolean;
  /** The English Wikipedia article to read for more (exact title), checked against Wikipedia; null: none fits. */
  wikipedia?: string | null;
  tags?: {
    content_type?: string;
    domain?: string;
    technicality?: number; // 1-4 scale: 1=intuitive, 2=foundational, 3=college, 4=graduate
    [key: string]: string | number | undefined;
  };
}

/**
 * Image generation response
 */
export interface GenerateImageResponse {
  imageData: string;
  mimeType: string;
}

/**
 * Mochi card creation response
 */
export interface MochiCardResponse {
  id: string;
  content?: string;
  [key: string]: unknown;
}

/**
 * Mochi card from API (uses kebab-case keys)
 */
export interface MochiCard {
  id: string;
  content: string;
  'deck-id': string;
  name?: string;
  tags?: string[];
  'created-at'?: string;
  'updated-at'?: string;
  archived?: boolean;
  new?: boolean;
  pos?: string;
  'template-id'?: string;
  fields?: Record<string, { id: string; value: string }>;
}

/**
 * Mochi deck from API
 */
export interface MochiDeck {
  id: string;
  name: string;
  'parent-id'?: string | null;
  archived?: boolean;
  sort?: number;
}

/**
 * Import from Mochi request body
 */
export interface ImportFromMochiRequest {
  deckIds: string[];
  createFolders?: boolean;
}

/**
 * Import result summary
 */
export interface ImportResult {
  success: boolean;
  imported: number;
  skipped: number;
  foldersCreated: string[];
  errors: string[];
}
