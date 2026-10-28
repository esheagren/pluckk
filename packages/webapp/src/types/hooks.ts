/**
 * Type definitions for custom React hooks
 */

import type { AuthUser as User } from '@pluckk/shared/api';
import type {
  CardReviewState,
  IntervalPreviews,
  NextReviewResult,
  Rating,
  RatingsMap,
} from '@pluckk/shared/scheduler';

// ============================================================================
// Database Types (matching Supabase schema)
// ============================================================================

/**
 * Folder row from database
 */
export interface Folder {
  id: string;
  user_id: string;
  name: string;
  sort_order: number | null;
  created_at: string;
  updated_at: string;
}

/**
 * Card row from database with optional folder relation
 */
export interface Card {
  id: string;
  user_id: string;
  question: string;
  answer: string;
  source_url: string | null;
  image_url: string | null;
  folder_id: string | null;
  folder?: Folder | null;
  source_selector: string | null;
  source_text_offset: number | null;
  created_at: string;
  updated_at: string;
  /** core-engine: the authored card; composites have several components */
  spec?: import('@pluckk/core/entities').CardSpec | null;
  provenance?: import('@pluckk/core/entities').Provenance | null;
  component_count?: number;
  /** Free-form tags (e.g. 'rework', 'image-on-question', 'src:…'); the API returns them on every card */
  tags?: string[] | null;
  /** Due date from card_review_state (optional, loaded separately) */
  due_at?: string | null;
}

/**
 * Card with review state (used in review sessions)
 */
export interface CardWithReviewState extends Card {
  review_state: CardReviewState | null;
  is_new: boolean;
  /** core-engine: which component of the card this queue entry is ('main', 'forward', 'p2'…) */
  component_id: string;
  /** Interval each rating would give, computed by the server for this component. */
  previews?: IntervalPreviews | null;
  is_due?: boolean;
  _againCard?: boolean;
}

// ============================================================================
// useAuth Types
// ============================================================================

/**
 * Return type for useAuth hook
 */
export interface UseAuthReturn {
  user: User | null;
  loading: boolean;
  signIn: () => Promise<void>;
  signOut: () => Promise<void>;
}

// ============================================================================
// useTheme Types
// ============================================================================

export type Theme = 'light' | 'dark';

/**
 * Return type for useTheme hook
 */
export interface UseThemeReturn {
  theme: Theme;
  setTheme: (theme: Theme) => void;
  toggleTheme: () => void;
  isDark: boolean;
}

// ============================================================================
// useProfile Types
// ============================================================================

/**
 * User profile data
 */
export interface Profile {
  id: string;
  username: string | null;
  display_name: string | null;
  bio: string | null;
  avatar_url: string | null;
  is_public: boolean;
  created_at: string;
}

/**
 * Learning profile for personalized card generation
 */
export type PrimaryCategory = 'student' | 'worker' | 'researcher';
export type StudentLevel = 'high_school' | 'college' | 'medical_school' | 'law_school' | 'graduate_school' | 'other';
export type WorkField = 'consulting' | 'engineering' | 'product' | 'finance' | 'marketing' | 'design' | 'sales' | 'operations' | 'legal' | 'healthcare' | 'education' | 'other';
export type YearsExperience = '1-2' | '3-5' | '6-10' | '10+';

// Technicality preference (1-4 scale)
// 1 = Intuitive (impressions, analogies)
// 2 = Conceptual (mechanisms, relationships)
// 3 = Detailed (specifics, numbers)
// 4 = Mathematical (formulas, precise values)
export type TechnicalityLevel = 1 | 2 | 3 | 4;

// Breadth preference (1-4 scale)
// 1 = Focused (exactly what was highlighted)
// 2 = Contextual (immediate context)
// 3 = Connected (related concepts)
// 4 = Exploratory (broader implications)
export type BreadthLevel = 1 | 2 | 3 | 4;

// Spaced repetition experience
export type SpacedRepExperience = 'none' | 'tried' | 'regular' | 'power_user';

export interface LearningProfile {
  onboardingCompleted: boolean;
  // Primary category
  primaryCategory: PrimaryCategory | null;
  // Student-specific
  studentLevel: StudentLevel | null;
  studentField: string | null; // For college, graduate, or other students
  // Worker-specific
  workFields: WorkField[]; // Multiple selection allowed
  workFieldOther: string | null; // If 'other' is selected
  workYearsExperience: YearsExperience | null;
  // Researcher-specific
  researchField: string | null;
  researchYearsExperience: YearsExperience | null;
  // Additional interests
  additionalInterests: string[];
  additionalInterestsOther: string | null;
  // Learning preferences
  spacedRepExperience: SpacedRepExperience | null;
  technicalityPreference: TechnicalityLevel | null;
  breadthPreference: BreadthLevel | null;
}

export const STUDENT_LEVELS: { value: StudentLevel; label: string }[] = [
  { value: 'high_school', label: 'High School' },
  { value: 'college', label: 'College' },
  { value: 'medical_school', label: 'Medical School' },
  { value: 'law_school', label: 'Law School' },
  { value: 'graduate_school', label: 'Graduate School' },
  { value: 'other', label: 'Other' },
];

export const WORK_FIELDS: { value: WorkField; label: string }[] = [
  { value: 'consulting', label: 'Consulting' },
  { value: 'engineering', label: 'Engineering' },
  { value: 'product', label: 'Product' },
  { value: 'finance', label: 'Finance' },
  { value: 'marketing', label: 'Marketing' },
  { value: 'design', label: 'Design' },
  { value: 'sales', label: 'Sales' },
  { value: 'operations', label: 'Operations' },
  { value: 'legal', label: 'Legal' },
  { value: 'healthcare', label: 'Healthcare' },
  { value: 'education', label: 'Education' },
  { value: 'other', label: 'Other' },
];

export const YEARS_EXPERIENCE: { value: YearsExperience; label: string }[] = [
  { value: '1-2', label: '1-2 years' },
  { value: '3-5', label: '3-5 years' },
  { value: '6-10', label: '6-10 years' },
  { value: '10+', label: '10+ years' },
];

export const ADDITIONAL_INTERESTS = [
  'Science',
  'Math',
  'History',
  'Languages',
  'Arts',
  'Business',
  'Technology',
] as const;

export const SPACED_REP_EXPERIENCE: { value: SpacedRepExperience; label: string; description: string }[] = [
  { value: 'none', label: 'New to this', description: "I haven't used spaced repetition before" },
  { value: 'tried', label: 'Tried it', description: "I've experimented with Anki, Mochi, or similar" },
  { value: 'regular', label: 'Regular user', description: 'I use spaced repetition regularly' },
  { value: 'power_user', label: 'Power user', description: 'I optimize my card writing and review habits' },
];

// Technicality level examples (fallback examples for when API fails)
export const TECHNICALITY_EXAMPLES: { level: TechnicalityLevel; label: string; example: string }[] = [
  { level: 1, label: 'Intuitive', example: "ATP is like a rechargeable battery that gives your cells energy to do work" },
  { level: 2, label: 'Conceptual', example: "ATP (adenosine triphosphate) stores energy in its phosphate bonds. When the third phosphate is removed, energy is released to power cellular processes like muscle contraction" },
  { level: 3, label: 'Detailed', example: "ATP hydrolysis (ATP → ADP + Pi) releases ~30.5 kJ/mol under cellular conditions. This exergonic reaction is coupled to endergonic processes via enzymes like ATPases and kinases" },
  { level: 4, label: 'Technical', example: "ATP hydrolysis has ΔG°' = -30.5 kJ/mol, but actual cellular ΔG ranges from -50 to -65 kJ/mol due to mass action ratios. The γ-phosphate's high transfer potential derives from electrostatic repulsion, resonance stabilization of products, and solvation effects" },
];

// Breadth level configuration
export const BREADTH_LEVELS: { level: BreadthLevel; label: string; description: string }[] = [
  { level: 1, label: 'Laser', description: 'Exactly what you highlighted' },
  { level: 2, label: 'Narrow', description: 'Direct implications' },
  { level: 3, label: 'Medium', description: 'Related concepts' },
  { level: 4, label: 'Synthesizer', description: 'Broader connections' },
];

// Caffeine example questions for breadth demonstration
export const BREADTH_EXAMPLE_QUESTIONS: Record<BreadthLevel, { text: string; extended: boolean }[]> = {
  1: [
    { text: 'What does caffeine block?', extended: false },
  ],
  2: [
    { text: 'What does caffeine block?', extended: false },
    { text: 'Why does blocking adenosine make you feel alert?', extended: false },
  ],
  3: [
    { text: 'What does caffeine block?', extended: false },
    { text: 'Why does blocking adenosine make you feel alert?', extended: false },
    { text: "What is adenosine's normal role in the brain?", extended: true },
  ],
  4: [
    { text: 'What does caffeine block?', extended: false },
    { text: 'Why does blocking adenosine make you feel alert?', extended: false },
    { text: 'How does sleep pressure accumulate throughout the day?', extended: true },
    { text: 'Why does caffeine cause an energy crash later?', extended: true },
  ],
};

/**
 * Subscription data
 */
export interface Subscription {
  isPro: boolean;
  plan: string | null;
  status: string | null;
}

/**
 * Usage data
 */
export interface Usage {
  cardsThisMonth: number;
  limit: number;
}

/**
 * User settings
 */
export interface Settings {
  newCardsPerDay: number;
  emailNotifications: boolean;
}

/**
 * Profile update payload
 */
export interface ProfileUpdates {
  username?: string;
  display_name?: string;
  bio?: string;
  is_public?: boolean;
  settings?: Partial<Settings>;
}

/**
 * Username check result
 */
export interface UsernameCheckResult {
  available: boolean;
  reason?: 'too_short' | 'taken' | 'invalid' | 'error';
  message?: string;
}

/**
 * Return type for useProfile hook
 */
export interface UseProfileReturn {
  profile: Profile | null;
  subscription: Subscription | null;
  usage: Usage | null;
  settings: Settings | null;
  loading: boolean;
  saving: boolean;
  error: string | null;
  updateProfile: (updates: ProfileUpdates) => Promise<{ success?: boolean; error?: string }>;
  checkUsername: (username: string) => Promise<UsernameCheckResult>;
  refetch: () => Promise<void>;
}

// ============================================================================
// useCards Types
// ============================================================================

/**
 * Card updates payload
 */
export interface CardUpdates {
  question?: string;
  answer?: string;
  folder_id?: string | null;
}

/**
 * Operation result with optional error
 */
export interface OperationResult<T = unknown> {
  data?: T;
  error?: Error | unknown;
  success?: boolean;
}

/**
 * Return type for useCards hook
 */
export interface UseCardsReturn {
  cards: Card[];
  loading: boolean;
  refetch: () => Promise<void>;
  getShuffledCards: () => Card[];
  updateCard: (cardId: string, updates: CardUpdates) => Promise<OperationResult<Card>>;
  deleteCard: (cardId: string) => Promise<OperationResult<{ event_id?: string }>>;
  restoreCard: (eventId: string) => Promise<OperationResult>;
  moveCardToFolder: (cardId: string, folderId: string | null, folder?: Folder | null) => Promise<OperationResult<Card>>;
}

// ============================================================================
// useFolders Types
// ============================================================================

/**
 * Folder updates payload
 */
export interface FolderUpdates {
  name?: string;
  sort_order?: number;
}

/**
 * Return type for useFolders hook
 */
export interface UseFoldersReturn {
  folders: Folder[];
  loading: boolean;
  refetch: () => Promise<void>;
  createFolder: (name: string) => Promise<OperationResult<Folder>>;
  updateFolder: (folderId: string, updates: FolderUpdates) => Promise<OperationResult<Folder>>;
  deleteFolder: (folderId: string) => Promise<OperationResult>;
}

// ============================================================================
// usePublicProfile Types
// ============================================================================

/**
 * Public profile data
 */
export interface PublicProfile {
  username: string;
  display_name: string | null;
  bio: string | null;
  avatar_url: string | null;
  created_at: string;
}

/**
 * Profile stats
 */
export interface ProfileStats {
  totalCards: number;
  totalReviews: number;
  currentStreak: number;
  longestStreak: number;
}

/**
 * Activity data point
 */
export interface ActivityDataPoint {
  date: string;
  reviews: number;
  cardsCreated: number;
}

/**
 * Public card (limited info)
 */
export interface PublicCard {
  id: string;
  question: string;
  answer: string;
  created_at: string;
}

/**
 * Profile error
 */
export interface ProfileError {
  status?: number;
  message: string;
}

/**
 * Return type for usePublicProfile hook
 */
export interface UsePublicProfileReturn {
  profile: PublicProfile | null;
  stats: ProfileStats | null;
  activity: ActivityDataPoint[];
  publicCards: PublicCard[];
  loading: boolean;
  error: ProfileError | null;
  refetch: () => Promise<void>;
}

// ============================================================================
// useActivityStats Types
// ============================================================================

/**
 * Activity data map (date string -> activity counts)
 */
export interface ActivityDataMap {
  [date: string]: {
    reviews: number;
    cardsCreated: number;
  };
}

/**
 * Return type for useActivityStats hook
 */
export interface UseActivityStatsReturn {
  activityData: ActivityDataMap;
  loading: boolean;
  error: Error | unknown | null;
  refetch: () => Promise<void>;
}

// ============================================================================
// useReviewState Types
// ============================================================================

/**
 * Saved session data for persistence
 */
export interface SavedSession {
  /** "cardId|componentId" keys in deal order. */
  items: string[];
  currentIndex: number;
  timestamp: number;
  /** Which session config dealt these cards; a saved Mix session must not resume inside a Focus session. */
  configKey?: string;
}

/**
 * Restored session data
 */
export interface RestoredSession {
  cards: CardWithReviewState[];
  index: number;
}

/**
 * Review submission result
 */
export interface ReviewSubmitResult {
  success?: boolean;
  error?: string | Error | unknown;
  /** @deprecated the server schedules now; see `state` */
  newState?: NextReviewResult;
  /** The component's state after the rating, as the server stored it. */
  state?: CardReviewState;
}

/**
 * Return type for useReviewState hook
 */
/** Review-mixer session request (mirrors POST /api/v1/review/session). */
export interface SessionConfig {
  mode: 'scheduled' | 'focus' | 'backlog';
  folderId?: string | null;      // focus/backlog (null = unfiled)
  size?: number;                 // omit → server default
  mix?: Array<{ folder_id: string | null; pct: number }>;
}

export interface SessionMeta {
  mode: string;
  per_folder: Record<string, { due: number; new: number; dealt: number }>;
  due_total: number;
  backlog_remaining?: number;
}

export interface UseReviewStateReturn {
  sessionMeta: SessionMeta | null;
  dueCards: CardWithReviewState[];
  currentCard: CardWithReviewState | null;
  currentIndex: number;
  loading: boolean;
  isComplete: boolean;
  totalCards: number;
  reviewedCount: number;
  totalNewCards: number;
  newCardsAvailableToday: number;
  newCardsPerDay: number;
  getIntervalPreviews: () => IntervalPreviews | null;
  submitReview: (rating: Rating) => Promise<ReviewSubmitResult>;
  /** Undo the last rating (server-side compensating event). Resolves true when the queue was restored. */
  undoLastReview: () => Promise<boolean>;
  canUndo: boolean;
  skipCard: () => void;
  removeCard: (cardId: string) => void;
  restart: () => void;
  startNewCardsSession: (ignoreLimit?: boolean) => Promise<void>;
  refetch: (forceRefresh?: boolean) => Promise<void>;
  RATINGS: RatingsMap;
}

// ============================================================================
// Page Props Types
// ============================================================================

/**
 * Props for ReviewPage
 */
export interface ReviewPageProps {
  userId: string | undefined;
  onUpdateCard?: (cardId: string, updates: CardUpdates) => Promise<OperationResult>;
  onDeleteCard?: (cardId: string) => Promise<OperationResult>;
}

/**
 * Props for LandingPage
 */
export interface LandingPageProps {
  onSignIn: () => void;
}

/**
 * Props for CardsPage
 */
export interface CardsPageProps {
  cards: Card[];
  loading: boolean;
  onUpdateCard?: (cardId: string, updates: CardUpdates) => Promise<OperationResult<Card>>;
  onDeleteCard?: (cardId: string) => Promise<OperationResult<{ event_id?: string }>>;
  /** Undo a delete by the event id the delete returned; the card list is refetched. */
  onRestoreCard?: (eventId: string) => Promise<OperationResult>;
  onMoveCardToFolder?: (cardId: string, folderId: string | null) => Promise<OperationResult<Card>>;
  folders: Folder[];
  foldersLoading: boolean;
  onCreateFolder: (name: string) => Promise<OperationResult<Folder>>;
  onUpdateFolder: (folderId: string, updates: FolderUpdates) => Promise<OperationResult<Folder>>;
  onDeleteFolder: (folderId: string) => Promise<OperationResult>;
}

/**
 * Props for SettingsPage
 */
export interface SettingsPageProps {
  user: User | null;
  onSignOut: () => void;
}

/**
 * Props for ProfilePage
 */
export interface ProfilePageProps {
  user: User | null;
}

/**
 * Mochi deck from API (for import)
 */
export interface MochiDeck {
  id: string;
  name: string;
  'parent-id'?: string | null;
}

/**
 * Import result from Mochi
 */
export interface MochiImportResult {
  success: boolean;
  imported: number;
  skipped: number;
  foldersCreated: string[];
  errors: string[];
}

/**
 * Status message
 */
export interface StatusMessage {
  type: 'success' | 'error' | '';
  message: string;
}
