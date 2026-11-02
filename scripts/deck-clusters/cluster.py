"""Dry run: embed every card outside Spanish and Art locally, cluster into topic decks, draft names.
Moves nothing. Writes proposal.json for review."""
import os, sys, json, hashlib, sqlite3, importlib.util, collections, urllib.request
import numpy as np
os.environ.setdefault("HF_HUB_OFFLINE", "1")
from sentence_transformers import SentenceTransformer
from sklearn.cluster import KMeans
from sklearn.metrics import silhouette_score

spec = importlib.util.spec_from_file_location("p", "/Users/erik/Documents/AI/skills/pluckk-cards/scripts/pluckk.py")
p = importlib.util.module_from_spec(spec); argv = sys.argv; sys.argv = ["x"]
try: spec.loader.exec_module(p)
except SystemExit: pass
sys.argv = argv

KEEP = {"Spanish Top 5000", "Art · Artists"}
cards = [c for c in p.call("GET", "/cards") if ((c.get("folder") or {}).get("name") or "Unfiled") not in KEEP]
seen = set(); cards = [c for c in cards if not (c["id"] in seen or seen.add(c["id"]))]
print(len(cards), "cards to sort", file=sys.stderr)

import re
def text(c):
    # A leading "Book title: " groups cards by where they came from, not what they're about.
    q = re.sub(r"^[^:?]{3,60}: ", "", c["question"].strip())
    return f"{q}\n{c['answer'].strip().split(chr(10))[0]}"

store = os.path.expanduser("~/Library/Application Support/Pluckk/card-embeddings.sqlite")
db = sqlite3.connect(store)
db.execute("create table if not exists embeddings (card_id text primary key, text_hash text, vector blob)")
have = {r[0]: (r[1], r[2]) for r in db.execute("select card_id, text_hash, vector from embeddings")}
todo = [c for c in cards if have.get(c["id"], (None,))[0] != hashlib.sha1(text(c).encode()).hexdigest()]
if todo:
    model = SentenceTransformer("nomic-ai/nomic-embed-text-v1.5", trust_remote_code=True)
    vecs = model.encode(["clustering: " + text(c) for c in todo], batch_size=32, normalize_embeddings=True, show_progress_bar=False)
    db.executemany("insert or replace into embeddings values (?,?,?)",
                   [(c["id"], hashlib.sha1(text(c).encode()).hexdigest(), v.astype(np.float32).tobytes()) for c, v in zip(todo, vecs)])
    db.commit()
print(len(todo), "newly embedded", file=sys.stderr)
have = {r[0]: r[1] for r in db.execute("select card_id, vector from embeddings")}
X = np.stack([np.frombuffer(have[c["id"]], dtype=np.float32) for c in cards])

scores = {}
for k in range(6, 11):
    km = KMeans(n_clusters=k, n_init=10, random_state=0).fit(X)
    scores[k] = (silhouette_score(X, km.labels_), km)
print("silhouette by k:", {k: round(v[0], 3) for k, v in scores.items()}, file=sys.stderr)
k = int(sys.argv[1]) if len(sys.argv) > 1 else 8
km = scores[k][1]

def name(questions):
    prompt = ("These flashcard questions belong to one deck. Give the deck a short, specific name of 1 to 4 words "
              "(like 'Energy & materials' or 'Child development'). Reply with the name only.\n\n" + "\n".join("- " + q for q in questions))
    req = urllib.request.Request("http://localhost:11434/api/generate", data=json.dumps(
        {"model": "qwen2.5:3b", "prompt": prompt, "stream": False, "options": {"temperature": 0}}).encode(),
        headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=120))["response"].strip().strip('"').split("\n")[0][:40]

decks = []
for i in range(k):
    idx = np.where(km.labels_ == i)[0]
    dist = np.linalg.norm(X[idx] - km.cluster_centers_[i], axis=1)
    central = [cards[j] for j in idx[np.argsort(dist)]]
    sources = collections.Counter(((c.get("folder") or {}).get("name") or "Unfiled") for c in central)
    decks.append({"name": "", "count": len(idx),
                  "from": sources.most_common(4), "examples": [text(c).split(chr(10))[0][:90] for c in central[:8]],
                  "card_ids": [c["id"] for c in central]})
decks.sort(key=lambda d: -d["count"])
json.dump({"k": k, "decks": decks}, open("proposal.json", "w"), indent=1, ensure_ascii=False)
for d in decks:
    print(f"\n## {decks.index(d)+1} — {d['count']} cards  (from {', '.join(f'{n} {c}' for n, c in d['from'])})")
    for e in d["examples"]: print("   ·", e)
