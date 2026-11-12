"""List a figure's drawables: number, fill, stroke, box, groups. Usage: info.py <name> [i,j,k | all] [--groups]"""
import json
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
data = json.load(open(os.path.join(here, 'work', sys.argv[1] + '.boxes.json')))
want = sys.argv[2] if len(sys.argv) > 2 else 'all'
if '--groups' in sys.argv:
    for g in data['groups']:
        b = g['box']
        print(f"{g['id']:28} n={g['n']:3} x={b[0]:6.1f} y={b[1]:6.1f} w={b[2]:6.1f} h={b[3]:6.1f}  in {'/'.join(g['parent'])}")
    sys.exit()
ids = None if want == 'all' else set(int(v) for v in want.split(','))
seen = set()
for it in data['items']:
    if ids is not None and it['i'] not in ids:
        continue
    b = it['box']
    side = 'R' if (it['i'] in seen) else ' '
    seen.add(it['i'])
    print(f"{it['i']:4}{side} fill={it['fill'][:22]:22} stroke={it['stroke'][:18]:18} x={b[0]:6.1f} y={b[1]:6.1f} w={b[2]:6.1f} h={b[3]:6.1f} id={it['id']} cls={it['cls']} g={'/'.join(it['groups'][-2:])}")
