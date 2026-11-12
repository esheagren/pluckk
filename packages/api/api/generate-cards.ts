// POST /api/generate-cards
// Proxies Claude API calls with server-side API key

import type { VercelRequest, VercelResponse } from '@vercel/node';
import type { User as DbUser } from '../db/schema.js';
import { buildPersonaPrompt } from '../lib/prompts.js';
import { authenticateRequest, isAuthError } from '../lib/auth.js';
import type { GenerateCardsRequest, GeneratedCard } from '../lib/types.js';
import type { ClaudeResponse } from '../lib/claude-types.js';
import { CLAUDE_FAST_MODEL, CLAUDE_MODEL, extractJson, responseText } from '../lib/models.js';
import { checkTitles } from '../lib/wikipedia.js';

const CLAUDE_API_URL = 'https://api.anthropic.com/v1/messages';

type RefinementAction = 'rephrase' | 'simplify' | 'harder';

const REFINEMENT_INSTRUCTIONS: Record<RefinementAction, string> = {
  rephrase: 'Rephrase the question and answer differently while testing the same knowledge. Use different wording, framing, or angle.',
  simplify: 'Break this into a more atomic, easier-to-answer card. Simplify the language and narrow the scope.',
  harder: 'Make this card require deeper recall or application. Increase specificity, ask "why" or "how" instead of "what".',
};

/**
 * Handle single-card refinement requests
 */
async function handleRefineCard(
  res: VercelResponse,
  body: GenerateCardsRequest
): Promise<void> {
  const { refineCard: card, refinementAction, sourceSelection, sourceContext } = body;

  if (!card || !refinementAction || !['rephrase', 'simplify', 'harder'].includes(refinementAction)) {
    res.status(400).json({ error: 'Invalid refinement request' });
    return;
  }

  const action = refinementAction as RefinementAction;
  const systemPrompt = `You are refining a single spaced repetition flashcard. ${REFINEMENT_INSTRUCTIONS[action]}

Return ONLY valid JSON with the refined card in the exact same format as the input card. Preserve the style and tags. Do not add explanation.
Output format: {"card":{...}}`;

  let userMessage = `**Original card:**\n${JSON.stringify(card, null, 2)}`;
  if (sourceSelection) userMessage += `\n\n**Source text:** ${sourceSelection}`;
  if (sourceContext) userMessage += `\n\n**Surrounding context:** ${sourceContext}`;
  userMessage += '\n\nRefine this card according to the instructions.';

  try {
    const claudeResponse = await fetch(CLAUDE_API_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': process.env.CLAUDE_API_KEY || '',
        'anthropic-version': '2023-06-01',
      },
      body: JSON.stringify({
        model: CLAUDE_FAST_MODEL,
        max_tokens: 1000,
        system: systemPrompt,
        messages: [{ role: 'user', content: userMessage }],
      }),
    });

    if (!claudeResponse.ok) {
      const errorText = await claudeResponse.text();
      console.error('Claude API error:', claudeResponse.status, errorText);
      if (claudeResponse.status === 429) {
        res.status(429).json({ error: 'rate_limit', message: 'Too many requests, please try again later' });
        return;
      }
      res.status(500).json({ error: 'Failed to refine card' });
      return;
    }

    const data = await claudeResponse.json() as ClaudeResponse;
    const content = responseText(data);
    if (!content) {
      res.status(500).json({ error: 'Empty response from AI' });
      return;
    }

    const parsed = JSON.parse(extractJson(content)) as { card: GeneratedCard };
    if (!parsed.card) {
      res.status(500).json({ error: 'Invalid response format from AI' });
      return;
    }

    res.status(200).json({ card: parsed.card });
  } catch (error) {
    console.error('Error refining card:', error);
    if (error instanceof SyntaxError) {
      res.status(500).json({ error: 'Failed to parse AI response' });
      return;
    }
    res.status(500).json({ error: 'Internal server error' });
  }
}

/**
 * Build the system prompt from the user's learning profile
 * Learning profile adds personalization context
 */
function buildSystemPrompt(profile?: DbUser): string {
  // Build persona prompt from learning profile
  // DB columns are plain text/int; the persona builder wants the literal unions.
  // Values were validated on write in /api/user/me, so the cast is safe.
  const personaPrompt = buildPersonaPrompt({
    primaryCategory: profile?.primaryCategory,
    studentLevel: profile?.studentLevel,
    studentField: profile?.studentField,
    workFields: profile?.workFields,
    workFieldOther: profile?.workFieldOther,
    workYearsExperience: profile?.workYearsExperience,
    researchField: profile?.researchField,
    researchYearsExperience: profile?.researchYearsExperience,
    additionalInterests: profile?.additionalInterests,
    additionalInterestsOther: profile?.additionalInterestsOther,
    spacedRepExperience: profile?.spacedRepExperience,
    technicalityPreference: profile?.technicalityPreference,
    breadthPreference: profile?.breadthPreference,
  } as Parameters<typeof buildPersonaPrompt>[0]);
  const diagramStyle = `
7. **diagram** - For STRUCTURAL or COMPARATIVE knowledge that benefits from visual representation.
   When to use: taxonomies, hierarchies, system architectures, X vs Y comparisons, process flows
   The diagram_prompt describes what image to generate - be specific about layout, relationships, and visual structure.
   Example:
   {"style":"diagram","question":"What are the two main branches of supervised learning?","answer":"Classification (predicts categories) and Regression (predicts continuous values)","diagram_prompt":"A tree diagram with 'Supervised Learning' at the top, branching into two nodes: 'Classification' (with examples: spam detection, image recognition) and 'Regression' (with examples: price prediction, temperature forecasting)","tags":{"content_type":"concept","domain":"machine_learning","technicality":2}}
`;

  return `You are a spaced repetition card generator. Create cards that produce durable understanding through retrieval practice.
${personaPrompt}

**Card Styles (choose the most appropriate for each piece of knowledge):**

1. **qa** - Direct factual question for single facts
   Example:
   {"style":"qa","question":"What type of chicken parts are used in stock?","answer":"Bones","tags":{"content_type":"fact","domain":"cooking","technicality":1}}

2. **qa_bidirectional** - For DEFINITIONS where both directions are useful. Generates forward (term→definition) and reverse (definition→term). Counts as ONE card toward the 4-8 target.
   ALWAYS use this style when the text defines a term, concept, or introduces vocabulary.
   Example:
   {"style":"qa_bidirectional","forward":{"question":"What is photosynthesis?","answer":"The process by which plants convert light energy into chemical energy"},"reverse":{"question":"What biological process describes plants converting light energy into chemical energy?","answer":"Photosynthesis"},"tags":{"content_type":"definition","domain":"biology","technicality":2}}

3. **cloze** - Single fill-in-the-blank for key terms or relationships
   Example:
   {"style":"cloze","question":"The mitochondria is the ___ of the cell","answer":"powerhouse","tags":{"content_type":"fact","domain":"biology","technicality":1}}

4. **cloze_list** - For CLOSED LISTS with fixed, known members. Creates N+1 clozes: one per item PLUS a final "recall all" card. Counts as ONE card in UI but expands to N+1 on save.
   For N items: first N prompts each occlude ONE item, final prompt occludes ALL items.
   Example (3 items → 4 prompts):
   {"style":"cloze_list","list_name":"Primary colors","items":["red","blue","yellow"],"prompts":[{"question":"Primary colors: ___, blue, yellow","answer":"red"},{"question":"Primary colors: red, ___, yellow","answer":"blue"},{"question":"Primary colors: red, blue, ___","answer":"yellow"},{"question":"Primary colors: ___, ___, ___","answer":"red, blue, yellow"}],"tags":{"content_type":"list","domain":"art","technicality":1}}

5. **explanation** - "Why" or "How" questions connecting facts to deeper meaning
   Example:
   {"style":"explanation","question":"Why are bones used instead of meat for making stock?","answer":"Bones contain collagen which converts to gelatin, giving the stock body and richness","tags":{"content_type":"concept","domain":"cooking","technicality":2}}

6. **application** - Connect knowledge to real-world situations or decision-making
   Example:
   {"style":"application","question":"When cooking a savory dish with water, what should you consider using instead?","answer":"Stock, as it adds depth and flavor","tags":{"content_type":"procedure","domain":"cooking","technicality":1}}
${diagramStyle}
**Tags (always include all three):**
- content_type: "definition" | "fact" | "concept" | "procedure" | "list"
- domain: infer from context (e.g., "biology", "cooking", "programming", "machine_learning", "history")
- technicality: 1 | 2 | 3 | 4
  - 1 = Intuitive (early high school or before): simple analogies, everyday language, no jargon
  - 2 = Foundational (high school): basic terminology, concepts explained accessibly
  - 3 = College: technical terminology, specific details, assumes foundational knowledge
  - 4 = Graduate: expert precision, formulas, quantitative details, assumes deep background

**Critical Rules:**
- Generate 4-8 cards total depending on the complexity and richness of the source material (qa_bidirectional and cloze_list each count as ONE card)
- ALWAYS use qa_bidirectional when text contains a definition (X is Y, X means Y, X refers to Y)
- Use cloze_list for enumerated lists with fixed membership
- Cover the key concepts thoroughly - aim for comprehensive extraction of learnable facts
- Tags help organization - always include content_type, domain, and technicality

**Wikipedia (every card):**
Give each card a "wikipedia" field: the exact title of the English Wikipedia article a learner should read to go further on that card's subject, the idea, thing, person, event or place it teaches. Choose the article whose main subject it is, or the closest broader article that covers it well (the parent concept, the theory, the work it comes from). Name the subject, don't echo the card's words: a card about signalling identity through beliefs wants an article on signalling or belief, not one that merely shares a word with it. Use null when you're not confident such an article exists.

**Output Format:**
Return ONLY valid JSON, no markdown code blocks:
{"cards":[...]}`;
}


/**
 * The articles the model named, checked against Wikipedia: each becomes the title Wikipedia
 * files it under, or null when there's no such article. If Wikipedia can't be asked, the field
 * is dropped, and the Wikipedia agent looks when the card is first opened.
 */
async function settleWikipedia(cards: GeneratedCard[]): Promise<void> {
  const named = cards.map((c) => (typeof c.wikipedia === 'string' ? c.wikipedia.trim() : '')).filter(Boolean);
  let checked: Map<string, { title: string } | null> | null = null;
  try {
    checked = named.length ? await checkTitles(named) : new Map();
  } catch (error) {
    console.error('Checking Wikipedia titles failed:', error);
  }
  for (const card of cards) {
    const name = typeof card.wikipedia === 'string' ? card.wikipedia.trim() : '';
    if (!checked) { delete card.wikipedia; continue; }
    if (!name) { card.wikipedia = card.wikipedia === null ? null : undefined; continue; }
    const article = checked.get(name);
    if (article === undefined) delete card.wikipedia;
    else card.wikipedia = article?.title ?? null;
  }
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

  if (req.method !== 'POST') {
    res.status(405).json({ error: 'Method not allowed' });
    return;
  }

  // Authenticate user
  const authResult = await authenticateRequest(req);
  if (isAuthError(authResult)) {
    res.status(authResult.status).json({ error: authResult.error });
    return;
  }

  const { profile } = authResult;


  // Parse request body
  const body = req.body as GenerateCardsRequest;

  // Refinement mode: refine a single card instead of generating a batch
  if (body.refineCard && body.refinementAction) {
    await handleRefineCard(res, body);
    return;
  }

  const { selection, context, url, title, focusText, customPrompt } = body;

  if (!selection) {
    res.status(400).json({ error: 'Missing selection text' });
    return;
  }

  // Build user message
  let userMessage = `**Selection:** ${selection}

**Context:** ${context || 'No additional context'}

**Source URL:** ${url || 'Unknown'}
**Page Title:** ${title || 'Unknown'}

Generate 4-8 spaced repetition cards for the highlighted selection, depending on the complexity and richness of the content.`;

  if (focusText) {
    userMessage += `\n\n**Focus:** Please focus the cards on: ${focusText}`;
  }

  // Determine if user is Pro (for diagram feature access)

  // Use custom prompt or build based on subscription status and learning profile
  const systemPrompt = customPrompt || buildSystemPrompt(profile);

  try {
    // Call Claude API with server-side key
    const claudeResponse = await fetch(CLAUDE_API_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': process.env.CLAUDE_API_KEY || '',
        'anthropic-version': '2023-06-01'
      },
      body: JSON.stringify({
        model: CLAUDE_MODEL,
        max_tokens: 4000,
        system: systemPrompt,
        messages: [
          {
            role: 'user',
            content: userMessage
          }
        ]
      })
    });

    if (!claudeResponse.ok) {
      const errorText = await claudeResponse.text();
      console.error('Claude API error:', claudeResponse.status, errorText);

      if (claudeResponse.status === 401) {
        res.status(500).json({ error: 'API configuration error' });
        return;
      }
      if (claudeResponse.status === 429) {
        res.status(429).json({ error: 'rate_limit', message: 'Too many requests, please try again later' });
        return;
      }

      res.status(500).json({ error: 'Failed to generate cards' });
      return;
    }

    const data = await claudeResponse.json() as ClaudeResponse;

    const content = responseText(data);
    if (!content) {
      res.status(500).json({ error: 'Empty response from AI' });
      return;
    }

    const parsed = JSON.parse(extractJson(content)) as { cards: GeneratedCard[] };

    if (!parsed.cards || !Array.isArray(parsed.cards)) {
      res.status(500).json({ error: 'Invalid response format from AI' });
      return;
    }
    await settleWikipedia(parsed.cards);
    res.status(200).json({
      cards: parsed.cards
    });

  } catch (error) {
    console.error('Error generating cards:', error);

    if (error instanceof SyntaxError) {
      res.status(500).json({ error: 'Failed to parse AI response' });
      return;
    }

    res.status(500).json({ error: 'Internal server error' });
  }
}
