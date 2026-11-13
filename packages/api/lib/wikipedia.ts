// A card's Wikipedia article: the one to read for more on what the card teaches.
//
// The model that writes a card names one as it writes it (api/generate-cards.ts); checkTitles
// makes sure each name is a real article. For a card that has none yet, findArticle runs a
// small agent: Claude searches Wikipedia with a tool, looks at what comes back, and names the
// article that best covers the card's subject, or says none does. Either way the choice is
// stored on the card's spec, where the person can change it.

import Anthropic from '@anthropic-ai/sdk';

const WIKI_API = 'https://en.wikipedia.org/w/api.php';
const USER_AGENT = 'Pluckk/1.0 (https://pluckk.app; spaced-repetition app)';
const MODEL = process.env.WIKIPEDIA_AGENT_MODEL || 'claude-opus-5-5';
const MAX_TURNS = 6;

export interface CardForWikipedia {
  question: string;
  answer: string;
  /** The deck the card is in ("Education Policy"): says which sense of a name is meant. */
  deck?: string | null;
  /** Where the card came from: a book, a page title, a site. */
  source?: string | null;
}

/** A checked article: the title Wikipedia files it under, after redirects. */
export interface Article { title: string; description: string | null }

// ---------------------------------------------------------------- Wikipedia

async function wiki(params: Record<string, string>): Promise<Record<string, unknown>> {
  const url = `${WIKI_API}?${new URLSearchParams({ format: 'json', formatversion: '2', ...params })}`;
  const res = await fetch(url, { headers: { 'User-Agent': USER_AGENT } });
  if (!res.ok) throw new Error(`Wikipedia answered ${res.status}`);
  return (await res.json()) as Record<string, unknown>;
}

interface WikiPage { title: string; missing?: boolean; invalid?: boolean; description?: string; pageprops?: { disambiguation?: string } }

/**
 * Check titles against Wikipedia in one request: each maps to the article it names (following
 * redirects and normalisation), or null when there's no such article or it's a "may refer to"
 * page. Titles Wikipedia couldn't be asked about are left out of the map.
 */
export async function checkTitles(titles: string[]): Promise<Map<string, Article | null>> {
  const out = new Map<string, Article | null>();
  const wanted = [...new Set(titles.map((t) => t.trim()).filter(Boolean))].slice(0, 50);
  if (wanted.length === 0) return out;
  const data = await wiki({
    action: 'query', titles: wanted.join('|'), redirects: '1', prop: 'pageprops|description', ppprop: 'disambiguation',
  });
  const query = (data.query ?? {}) as { normalized?: { from: string; to: string }[]; redirects?: { from: string; to: string }[]; pages?: WikiPage[] };
  const step = new Map<string, string>();
  for (const n of [...(query.normalized ?? []), ...(query.redirects ?? [])]) step.set(n.from, n.to);
  const pages = new Map((query.pages ?? []).map((p) => [p.title, p]));
  for (const asked of wanted) {
    let title = asked;
    for (let hops = 0; hops < 3 && step.has(title); hops++) title = step.get(title)!;
    const page = pages.get(title);
    out.set(asked, !page || page.missing || page.invalid || page.pageprops?.disambiguation !== undefined
      ? null
      : { title: page.title, description: page.description ?? null });
  }
  return out;
}

/** Wikipedia's search, as the agent sees it: title, one-line description, a snippet of the text. */
async function search(query: string): Promise<string> {
  const data = await wiki({
    action: 'query', generator: 'search', gsrsearch: query, gsrlimit: '8',
    prop: 'description|pageprops|extracts', ppprop: 'disambiguation', exintro: '1', explaintext: '1', exsentences: '2', exlimit: '8',
  });
  const pages = (((data.query ?? {}) as { pages?: (WikiPage & { index?: number; extract?: string })[] }).pages ?? [])
    .sort((a, b) => (a.index ?? 0) - (b.index ?? 0));
  if (pages.length === 0) return 'No articles found.';
  return pages.map((p) => {
    const kind = p.pageprops?.disambiguation !== undefined ? ' [list of meanings, not an article]' : '';
    const desc = p.description ? ` (${p.description})` : '';
    return `- ${p.title}${desc}${kind}: ${(p.extract ?? '').replace(/\s+/g, ' ').slice(0, 300)}`;
  }).join('\n');
}

// ---------------------------------------------------------------- the agent

const SYSTEM = `You find the English Wikipedia article a learner should read to go further on a flashcard.

Read the card and work out its subject: the idea, thing, person, event or place it teaches. Search Wikipedia for that subject (by its proper name or the term itself, not by copying the card's wording), look at what comes back, search again with other terms if nothing fits, then call choose_article.

Choose the article whose main subject is the card's subject, or the closest broader article that covers it substantially (the parent concept, the theory, the work it comes from). Use the deck and source to tell which sense of a name is meant. An article that only shares words with the card is wrong: a card about signalling identity through beliefs is not about the Signal messaging app. If no article covers the subject well, choose none; that is better than a loose match.`;

const tools: Anthropic.Beta.BetaTool[] = [
  {
    name: 'search_wikipedia',
    description: 'Search English Wikipedia. Returns up to 8 articles with their one-line description and opening sentences. Lists of meanings are marked and are not articles.',
    strict: true,
    input_schema: {
      type: 'object',
      properties: { query: { type: 'string', description: 'A few words naming the subject, as a Wikipedia title would' } },
      required: ['query'],
      additionalProperties: false,
    },
  },
  {
    name: 'choose_article',
    description: 'Give the answer: the exact title of the article to read, or null when no article covers the card\'s subject well. Ends the task.',
    strict: true,
    input_schema: {
      type: 'object',
      properties: {
        title: { type: ['string', 'null'], description: 'Exact article title as Wikipedia shows it, or null' },
      },
      required: ['title'],
      additionalProperties: false,
    },
  },
];

function describe(card: CardForWikipedia): string {
  return [
    `Question: ${card.question}`,
    `Answer: ${card.answer}`,
    card.deck ? `Deck: ${card.deck}` : null,
    card.source ? `Source: ${card.source}` : null,
  ].filter(Boolean).join('\n');
}

/**
 * Find the article for a card. Resolves to the article, or null when the agent judged that none
 * fits. Throws if Claude or Wikipedia can't be reached, so a failure isn't stored as "none".
 */
export async function findArticle(card: CardForWikipedia): Promise<Article | null> {
  const client = new Anthropic({ apiKey: process.env.CLAUDE_API_KEY });
  const messages: Anthropic.Beta.BetaMessageParam[] = [
    { role: 'user', content: `${describe(card)}\n\nFind this card's Wikipedia article. Use search_wikipedia, then choose_article.` },
  ];

  for (let turn = 0; turn < MAX_TURNS; turn++) {
    const response = await client.beta.messages.create({
      model: MODEL,
      max_tokens: 4000,
      system: SYSTEM,
      tools,
      messages,
      output_config: { effort: 'low' },
      betas: ['server-side-fallback-2026-07-01'],
      fallbacks: 'default',
    });
    if (response.stop_reason === 'refusal') return null;
    // The whole turn goes back unchanged, thinking blocks included.
    messages.push({ role: 'assistant', content: response.content });
    const calls = response.content.filter((b): b is Anthropic.Beta.BetaToolUseBlock => b.type === 'tool_use');
    if (calls.length === 0) {
      messages.push({ role: 'user', content: 'Finish by calling choose_article.' });
      continue;
    }

    const results: Anthropic.Beta.BetaToolResultBlockParam[] = [];
    for (const call of calls) {
      const input = call.input as { query?: string; title?: string | null };
      if (call.name === 'choose_article') {
        if (input.title == null) return null;
        // Only a real article counts: a typo, or a list of meanings, goes back to be fixed.
        const checked = (await checkTitles([input.title])).get(input.title.trim());
        if (checked) return checked;
        results.push({ type: 'tool_result', tool_use_id: call.id, is_error: true,
          content: `"${input.title}" isn't an article on English Wikipedia (missing, or a list of meanings). Search again, or choose null.` });
      } else if (call.name === 'search_wikipedia') {
        results.push({ type: 'tool_result', tool_use_id: call.id, content: await search(String(input.query ?? '')) });
      } else {
        results.push({ type: 'tool_result', tool_use_id: call.id, is_error: true, content: `No tool called ${call.name}.` });
      }
    }
    messages.push({ role: 'user', content: results });
  }
  return null;
}
