import json,sys,importlib.util,sqlite3,os,collections,numpy as np
from concurrent.futures import ThreadPoolExecutor
spec=importlib.util.spec_from_file_location("p","/Users/erik/Documents/AI/skills/pluckk-cards/scripts/pluckk.py");p=importlib.util.module_from_spec(spec);sys.argv=["x"]
try: spec.loader.exec_module(p)
except SystemExit: pass
NAMES=["The World in Numbers","Societies & Cultural Evolution","Risk, Reasoning & Learning","Energy","Georgian History","Retrieval & RAG","Machine Learning Basics","Georgian Food"]
OLD=["AI/ML","Book Ideas","Consulting","History","How the World Really Works"]
prop=json.load(open('proposal.json'))
cards={c['id']:c for c in p.call('GET','/cards')}
db=sqlite3.connect(os.path.expanduser("~/Library/Application Support/Pluckk/card-embeddings.sqlite"))
vec={r[0]:np.frombuffer(r[1],dtype=np.float32) for r in db.execute("select card_id,vector from embeddings")}
cent=[np.mean([vec[i] for i in d['card_ids']],axis=0) for d in prop['decks']]
assign={}
for i,d in enumerate(prop['decks']):
    for cid in d['card_ids']:
        c=cards[cid]; k=i
        if i>=3 and (c.get('folder') or {}).get('name')=='Book Ideas':   # strays: nearest of the three main decks
            k=int(np.argmax([float(np.dot(vec[cid],x)/np.linalg.norm(x)) for x in cent[:3]]))
        assign[cid]=k
# daily limits: the old decks' 16, shared by unseen cards, at least 1 each
unseen=collections.Counter(assign[cid] for cid in assign if cards[cid].get('due_at') is None)
total=16; w=[max(unseen.get(i,0),1) for i in range(8)]
exact=[total*x/sum(w) for x in w]; lim=[max(1,int(e)) for e in exact]
for i in sorted(range(8),key=lambda i:-(exact[i]-int(exact[i]))):
    if sum(lim)>=total: break
    lim[i]+=1
existing={f['name']:f for f in p.call('GET','/folders')}
ids=[]
for name,l in zip(NAMES,lim):
    f=existing.get(name) or p.call('POST','/folders',{'name':name,'new_per_day':l})
    ids.append(f['id'])
print('decks', list(zip(NAMES,lim,[sum(1 for v in assign.values() if v==i) for i in range(8)])))
def move(item):
    cid,k=item
    if cards[cid].get('folder_id')==ids[k]: return 0
    p.call('PATCH',f'/cards/{cid}',{'folder_id':ids[k]}); return 1
with ThreadPoolExecutor(6) as ex: moved=sum(ex.map(move,assign.items()))
print('moved',moved)
after=collections.Counter(((c.get('folder') or {}).get('name') or 'Unfiled') for c in p.call('GET','/cards'))
print('now', dict(after))
for name in OLD:
    f=existing.get(name)
    if f and after.get(name,0)==0:
        p.call('DELETE',f"/folders/{f['id']}"); print('removed empty deck',name)
    elif f: print('NOT removed (still has cards):',name,after.get(name))
cdir=os.path.expanduser("~/Library/Application Support/Pluckk")
json.dump({"model":"nomic-ai/nomic-embed-text-v1.5","decks":[{"folder_id":ids[i],"name":NAMES[i],"centroid":(cent[i]/np.linalg.norm(cent[i])).tolist()} for i in range(8)]},
          open(os.path.join(cdir,"deck-centroids.json"),"w"))
print('centroids saved')
