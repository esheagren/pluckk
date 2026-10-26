// GET/PATCH /api/user/me
// Returns current user info, usage stats, settings, and profile
// PATCH updates user settings (Mochi config) and profile fields

import type { VercelRequest, VercelResponse } from '@vercel/node';
import { eq } from 'drizzle-orm';
import { authenticateRequest, isAuthError } from '../../lib/auth.js';
import { getDb, schema } from '../../lib/db.js';
import type { UpdateUserSettingsRequest } from '../../lib/types.js';

// Admins are named by email in the server-only ADMIN_EMAILS env var (comma-separated), so the
// list never appears in the public repo or the webapp bundle.
function isAdminEmail(email: string | null | undefined): boolean {
  if (!email) return false;
  const admins = (process.env.ADMIN_EMAILS || '')
    .split(',')
    .map((e) => e.trim().toLowerCase())
    .filter(Boolean);
  return admins.includes(email.toLowerCase());
}

// Basic HTML tag sanitization to prevent XSS
function sanitizeText(text: string | null | undefined): string | null {
  if (!text) return null;
  // Remove all HTML tags
  return text.replace(/<[^>]*>/g, '').trim();
}

export default async function handler(
  req: VercelRequest,
  res: VercelResponse
): Promise<void> {
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    res.status(200).end();
    return;
  }

  // Authenticate user
  const authResult = await authenticateRequest(req);
  if (isAuthError(authResult)) {
    res.status(authResult.status).json({ error: authResult.error });
    return;
  }

  const { user, profile } = authResult;

  // GET - Return user info, profile, and settings
  if (req.method === 'GET') {
    res.status(200).json({
      user: {
        id: user.id,
        email: user.email,
        displayName: profile.displayName || null,
        avatarUrl: profile.avatarUrl || null,
        createdAt: profile.createdAt,
        isAdmin: isAdminEmail(user.email)
      },
      settings: {
        mochiApiKey: profile.mochiApiKey || null,
        mochiDeckId: profile.mochiDeckId || null
      },
      learningProfile: {
        onboardingCompleted: profile.onboardingCompleted ?? false,
        primaryCategory: profile.primaryCategory || null,
        studentLevel: profile.studentLevel || null,
        studentField: profile.studentField || null,
        workFields: profile.workFields || [],
        workFieldOther: profile.workFieldOther || null,
        workYearsExperience: profile.workYearsExperience || null,
        researchField: profile.researchField || null,
        researchYearsExperience: profile.researchYearsExperience || null,
        additionalInterests: profile.additionalInterests || [],
        additionalInterestsOther: profile.additionalInterestsOther || null,
        spacedRepExperience: profile.spacedRepExperience || null,
        technicalityPreference: profile.technicalityPreference || null,
        breadthPreference: profile.breadthPreference || null
      }
    });
    return;
  }

  // PATCH - Update user settings and profile
  if (req.method === 'PATCH') {
    const {
      mochiApiKey, mochiDeckId, displayName,
      onboardingCompleted, primaryCategory, studentLevel, studentField,
      workFields, workFieldOther, workYearsExperience,
      researchField, researchYearsExperience,
      additionalInterests, additionalInterestsOther,
      spacedRepExperience, technicalityPreference, breadthPreference
    } = req.body as UpdateUserSettingsRequest;

    const updates: Record<string, unknown> = {};

    // Mochi settings
    if (mochiApiKey !== undefined) {
      updates.mochi_api_key = mochiApiKey || null;
    }
    if (mochiDeckId !== undefined) {
      updates.mochi_deck_id = mochiDeckId || null;
    }

    if (displayName !== undefined) {
      const sanitized = sanitizeText(displayName);
      updates.display_name = sanitized ? sanitized.slice(0, 100) : null;
    }

    // Learning profile fields
    if (onboardingCompleted !== undefined) {
      updates.onboarding_completed = Boolean(onboardingCompleted);
    }

    if (primaryCategory !== undefined) {
      const validCategories = ['student', 'worker', 'researcher'];
      if (primaryCategory === null || validCategories.includes(primaryCategory)) {
        updates.primary_category = primaryCategory;
      }
    }

    if (studentLevel !== undefined) {
      const validLevels = ['high_school', 'college', 'medical_school', 'law_school', 'graduate_school', 'other'];
      if (studentLevel === null || validLevels.includes(studentLevel)) {
        updates.student_level = studentLevel;
      }
    }

    if (studentField !== undefined) {
      const sanitized = sanitizeText(studentField);
      updates.student_field = sanitized ? sanitized.slice(0, 100) : null;
    }

    if (workFields !== undefined) {
      const validFields = ['consulting', 'engineering', 'product', 'finance', 'marketing', 'design', 'sales', 'operations', 'legal', 'healthcare', 'education', 'other'];
      if (workFields === null) {
        updates.work_fields = null;
      } else if (Array.isArray(workFields)) {
        updates.work_fields = workFields.filter(f => validFields.includes(f)).slice(0, 5);
      }
    }

    if (workFieldOther !== undefined) {
      const sanitized = sanitizeText(workFieldOther);
      updates.work_field_other = sanitized ? sanitized.slice(0, 100) : null;
    }

    if (workYearsExperience !== undefined) {
      const validYears = ['1-2', '3-5', '6-10', '10+'];
      if (workYearsExperience === null || validYears.includes(workYearsExperience)) {
        updates.work_years_experience = workYearsExperience;
      }
    }

    if (researchField !== undefined) {
      const sanitized = sanitizeText(researchField);
      updates.research_field = sanitized ? sanitized.slice(0, 200) : null;
    }

    if (researchYearsExperience !== undefined) {
      const validYears = ['1-2', '3-5', '6-10', '10+'];
      if (researchYearsExperience === null || validYears.includes(researchYearsExperience)) {
        updates.research_years_experience = researchYearsExperience;
      }
    }

    if (additionalInterests !== undefined) {
      if (additionalInterests === null) {
        updates.additional_interests = null;
      } else if (Array.isArray(additionalInterests)) {
        updates.additional_interests = additionalInterests
          .map(d => sanitizeText(d))
          .filter((d): d is string => d !== null && d.length > 0)
          .slice(0, 10);
      }
    }

    if (additionalInterestsOther !== undefined) {
      const sanitized = sanitizeText(additionalInterestsOther);
      updates.additional_interests_other = sanitized ? sanitized.slice(0, 200) : null;
    }

    // Learning preferences
    if (spacedRepExperience !== undefined) {
      const validOptions = ['none', 'tried', 'regular', 'power_user'];
      if (spacedRepExperience === null || validOptions.includes(spacedRepExperience)) {
        updates.spaced_rep_experience = spacedRepExperience;
      }
    }

    if (technicalityPreference !== undefined) {
      if (technicalityPreference === null || (technicalityPreference >= 1 && technicalityPreference <= 4)) {
        updates.technicality_preference = technicalityPreference;
      }
    }

    if (breadthPreference !== undefined) {
      if (breadthPreference === null || (breadthPreference >= 1 && breadthPreference <= 4)) {
        updates.breadth_preference = breadthPreference;
      }
    }

    if (Object.keys(updates).length === 0) {
      res.status(400).json({ error: 'No settings to update' });
      return;
    }

    // `updates` is keyed by snake_case column names; map to schema properties.
    const toCamel = (k: string) => k.replace(/_([a-z])/g, (_, c: string) => c.toUpperCase());
    const set = Object.fromEntries(Object.entries(updates).map(([k, v]) => [toCamel(k), v]));
    try {
      await getDb().update(schema.users).set(set).where(eq(schema.users.id, user.id));
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      console.error('Error updating user settings:', message, JSON.stringify(updates));
      res.status(500).json({ error: 'Failed to update settings', details: message });
      return;
    }

    res.status(200).json({ success: true, updated: Object.keys(updates) });
    return;
  }

  res.status(405).json({ error: 'Method not allowed' });
}
