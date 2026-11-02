# Topic decks

Cards outside the pinned decks (Spanish Top 5000, Art · Artists) are sorted into topic decks by
clustering local embeddings (nomic-embed-text-v1.5 via sentence-transformers, run with the
bookshelf corpus's Python). Embeddings live in `~/Library/Application Support/Pluckk/card-embeddings.sqlite`,
one per card, redone only when a card's text changes; deck centroids in `deck-centroids.json` next to it.

- `cluster.py [k]`: dry run. Embeds what's missing, clusters, writes `proposal.json`. Moves nothing.
- `apply.py`: creates the decks from an approved proposal, moves cards, removes emptied decks,
  saves the centroids. Names and the daily-limit total are set at the top.
- New cards: the Mac app (`DeckFiler.swift`) files any unfiled card into its nearest deck at launch
  and every half hour. Re-sorting is only done on request, matching new clusters to old decks.
