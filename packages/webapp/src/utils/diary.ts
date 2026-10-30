// Human-readable lines for a card's diary (the card_events list).
import type { CardEventRow } from '@pluckk/shared/api';

const RATING_WORD: Record<string, string> = { again: 'Again', hard: 'Hard', good: 'Good', easy: 'Easy', trivial: 'Trivial' };

function componentName(id?: string): string {
  if (!id || id === 'main') return '';
  if (id === 'forward') return 'forward direction';
  if (id === 'reverse') return 'reverse direction';
  const m = /^p(\d+)$/.exec(id);
  return m ? `prompt ${Number(m[1]) + 1}` : id;
}

function interval(days?: number): string {
  if (days == null) return '';
  if (days < 1) return `${Math.round(days * 24 * 60)}m`;
  if (days < 30) return `${Math.round(days)}d`;
  if (days < 365) return `${Math.round(days / 30)}mo`;
  return `${(days / 365).toFixed(1)}y`;
}

export function summariseEvent(e: CardEventRow, folderName?: (id: string | null) => string | null): string {
  switch (e.type) {
    case 'card.ingest': {
      const src = e.provenance?.containerTitle ?? e.provenance?.title ?? (e.provenance?.identifier?.startsWith('app:') ? e.provenance.identifier.slice(4) : null);
      return src ? `Created from ${src}` : 'Created';
    }
    case 'card.review': {
      const comp = componentName(e.component_id);
      return `Rated ${RATING_WORD[e.rating ?? ''] ?? e.rating}${comp ? ` · ${comp}` : ''}`;
    }
    case 'card.reschedule': {
      const comp = componentName(e.component_id);
      const s = e.state;
      return `Schedule set to ${s ? `${s.status}, next in ${interval(s.interval_days)}` : 'a new value'}${comp ? ` · ${comp}` : ''}`;
    }
    case 'card.setDeleted': return e.is_deleted ? 'Deleted' : 'Restored';
    case 'card.setSpec': return 'Edited';
    case 'card.setFolder': return e.folder_id ? `Moved to ${folderName?.(e.folder_id) ?? 'a deck'}` : 'Removed from its deck';
    case 'card.setTags': return `Tags: ${(e.tags ?? []).join(', ') || 'none'}`;
    case 'card.setImage': return e.image_url ? 'Image attached' : 'Image removed';
    case 'card.setProvenance': return 'Source updated';
    default: return (e as { type: string }).type;
  }
}

export function formatWhen(iso: string): string {
  const d = new Date(iso);
  const now = new Date();
  const sameDay = d.toDateString() === now.toDateString();
  const time = d.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
  if (sameDay) return `Today ${time}`;
  return `${d.toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: d.getFullYear() === now.getFullYear() ? undefined : 'numeric' })} ${time}`;
}
