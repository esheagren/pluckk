import { useEffect, useMemo, useState, type JSX } from 'react';
import MermaidDiagram from '../../components/MermaidDiagram';
import { diagrams, cardFieldProcessing } from './architecture/diagrams';
import { useTheme } from '../../hooks/useTheme';

const STORAGE_PREFIX = 'pluckk_arch_';

function loadOverride(id: string): string | null {
  try { return localStorage.getItem(STORAGE_PREFIX + id); } catch { return null; }
}
function saveOverride(id: string, source: string | null): void {
  try {
    if (source === null) localStorage.removeItem(STORAGE_PREFIX + id);
    else localStorage.setItem(STORAGE_PREFIX + id, source);
  } catch { /* ignore */ }
}

/**
 * /admin/architecture — how Pluckk works, as editable UML (Mermaid). Admin-only (see AdminRoute).
 * Sources: src/pages/admin/architecture/diagrams.ts. In-page edits persist per browser
 * until "Reset"; use "Copy" to paste a revised diagram back into a conversation.
 */
export default function ArchitecturePage(): JSX.Element {
  const { isDark } = useTheme();
  const [activeId, setActiveId] = useState<string>(() => {
    const hash = window.location.hash.replace('#', '');
    return diagrams.some((d) => d.id === hash) ? hash : diagrams[0].id;
  });
  const [editing, setEditing] = useState(false);
  const [drafts, setDrafts] = useState<Record<string, string>>(() =>
    Object.fromEntries(diagrams.map((d) => [d.id, loadOverride(d.id) ?? d.source]))
  );
  const [copied, setCopied] = useState(false);

  const active = useMemo(() => diagrams.find((d) => d.id === activeId)!, [activeId]);
  const source = drafts[active.id];
  const isModified = source !== active.source;

  useEffect(() => { window.history.replaceState(null, '', `#${activeId}`); }, [activeId]);

  const update = (value: string): void => {
    setDrafts((prev) => ({ ...prev, [active.id]: value }));
    saveOverride(active.id, value === active.source ? null : value);
  };
  const reset = (): void => { update(active.source); };
  const copy = async (): Promise<void> => {
    try { await navigator.clipboard.writeText(source); setCopied(true); setTimeout(() => setCopied(false), 1500); } catch { /* ignore */ }
  };

  return (
    <div className="min-h-screen bg-gray-50 text-gray-800 dark:bg-dark-bg dark:text-gray-100">
      <div className="mx-auto max-w-6xl px-6 py-10">
        <a href="/" className="mb-6 inline-flex items-center gap-2 text-sm font-medium text-gray-500 transition-colors hover:text-gray-800 dark:text-gray-400 dark:hover:text-gray-200">
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><path d="M19 12H5M12 19l-7-7 7-7" /></svg>
          Back to app
        </a>

        <header className="mb-8">
          <h1 className="text-3xl font-semibold">How Pluckk works</h1>
          <p className="mt-2 max-w-3xl text-gray-500 dark:text-gray-400">
            Systems, the two user journeys (capturing and practising), and the card itself. Diagrams are
            Mermaid text — edit any of them in place, then copy the source to discuss changes.
          </p>
        </header>

        <nav className="mb-6 flex flex-wrap gap-2" aria-label="Views">
          {diagrams.map((d) => (
            <button
              key={d.id}
              onClick={() => { setActiveId(d.id); setEditing(false); }}
              className={`rounded-full border px-4 py-1.5 text-sm transition-colors ${
                d.id === activeId
                  ? 'border-gray-800 bg-gray-800 text-white dark:border-gray-200 dark:bg-gray-200 dark:text-gray-900'
                  : 'border-gray-300 text-gray-600 hover:border-gray-500 dark:border-gray-700 dark:text-gray-300 dark:hover:border-gray-400'
              }`}
            >
              {d.title}
              {drafts[d.id] !== d.source && <span className="ml-1 text-xs opacity-70">•</span>}
            </button>
          ))}
        </nav>

        <section className="rounded-2xl border border-gray-200 bg-white p-6 shadow-sm dark:border-dark-border dark:bg-dark-surface">
          <div className="mb-4 flex flex-wrap items-start justify-between gap-3">
            <div>
              <div className="flex items-center gap-2">
                <h2 className="text-xl font-semibold">{active.title}</h2>
                <span className="rounded-md bg-gray-100 px-2 py-0.5 text-xs uppercase tracking-wide text-gray-500 dark:bg-gray-800 dark:text-gray-400">{active.kind}</span>
                {isModified && <span className="rounded-md bg-amber-100 px-2 py-0.5 text-xs text-amber-800 dark:bg-amber-900 dark:text-amber-200">edited</span>}
              </div>
              <p className="mt-1 max-w-3xl text-sm text-gray-500 dark:text-gray-400">{active.summary}</p>
            </div>
            <div className="flex gap-2">
              <button onClick={() => setEditing((e) => !e)} className="rounded-lg border border-gray-300 px-3 py-1.5 text-sm hover:bg-gray-50 dark:border-gray-700 dark:hover:bg-gray-800">
                {editing ? 'Hide source' : 'Edit source'}
              </button>
              <button onClick={copy} className="rounded-lg border border-gray-300 px-3 py-1.5 text-sm hover:bg-gray-50 dark:border-gray-700 dark:hover:bg-gray-800">
                {copied ? 'Copied ✓' : 'Copy source'}
              </button>
              {isModified && (
                <button onClick={reset} className="rounded-lg border border-red-300 px-3 py-1.5 text-sm text-red-700 hover:bg-red-50 dark:border-red-800 dark:text-red-300 dark:hover:bg-red-950">
                  Reset
                </button>
              )}
            </div>
          </div>

          <div className={editing ? 'grid gap-6 lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]' : ''}>
            {editing && (
              <textarea
                value={source}
                onChange={(e) => update(e.target.value)}
                spellCheck={false}
                className="h-[70vh] w-full resize-y rounded-lg border border-gray-300 bg-gray-50 p-3 font-mono text-xs leading-relaxed text-gray-800 focus:outline-none focus:ring-2 focus:ring-gray-400 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-100"
              />
            )}
            <div className="min-w-0 rounded-lg bg-gray-50/60 p-4 dark:bg-gray-900/40">
              <MermaidDiagram id={active.id} source={source} dark={isDark} />
            </div>
          </div>
        </section>

        {active.id === 'card-model' && (
          <section className="mt-8 rounded-2xl border border-gray-200 bg-white p-6 shadow-sm dark:border-dark-border dark:bg-dark-surface">
            <h2 className="text-xl font-semibold">What is on a card, and what processes it</h2>
            <p className="mt-1 mb-4 text-sm text-gray-500 dark:text-gray-400">
              Each row is one part of a card: where it originates, what transforms it, and what reads it.
            </p>
            <div className="overflow-x-auto">
              <table className="w-full text-left text-sm">
                <thead>
                  <tr className="border-b border-gray-200 text-xs uppercase tracking-wide text-gray-500 dark:border-gray-700 dark:text-gray-400">
                    <th className="py-2 pr-4">Field</th>
                    <th className="py-2 pr-4">Origin</th>
                    <th className="py-2 pr-4">Processing</th>
                    <th className="py-2">Consumers</th>
                  </tr>
                </thead>
                <tbody>
                  {cardFieldProcessing.map((row) => (
                    <tr key={row.field} className="border-b border-gray-100 align-top dark:border-gray-800">
                      <td className="py-3 pr-4 font-mono text-xs text-gray-800 dark:text-gray-200">{row.field}</td>
                      <td className="py-3 pr-4 text-gray-600 dark:text-gray-300">{row.origin}</td>
                      <td className="py-3 pr-4 text-gray-600 dark:text-gray-300">{row.processing}</td>
                      <td className="py-3 text-gray-600 dark:text-gray-300">{row.consumers}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </section>
        )}

        <footer className="mt-8 text-xs text-gray-400 dark:text-gray-500">
          Sources: <code>packages/webapp/src/pages/admin/architecture/diagrams.ts</code>. In-page edits are stored in this browser only.
        </footer>
      </div>
    </div>
  );
}
