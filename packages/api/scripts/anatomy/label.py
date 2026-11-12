"""Render a prepared figure (or a crop of it) with each drawable's number on it, to work out which
shapes make up which part. Usage: label.py <name> <out.png> [x y w h] [--min AREA] [--only i,j,k] [--tint]
  --min   skip shapes whose box is smaller than this (in figure units squared)
  --only  show numbers only for these shapes, and paint them red
  --tint  give each numbered shape its own colour, so neighbours can be told apart"""
import colorsys
import json
import os
import subprocess
import sys

here = os.path.dirname(os.path.abspath(__file__))
args = sys.argv[1:]
name, out = args[0], args[1]
nums = [a for a in args[2:] if a.replace('.', '').replace('-', '').isdigit()]
data = json.load(open(os.path.join(here, 'work', name + '.boxes.json')))
vb = [float(v) for v in (nums[:4] if len(nums) >= 4 else data['viewBox'].split())]
min_area = float(args[args.index('--min') + 1]) if '--min' in args else 0
only = set(int(v) for v in args[args.index('--only') + 1].split(',')) if '--only' in args else None
tint = '--tint' in args
svg = open(os.path.join(here, 'work', name + '.svg')).read()
W = 1500
H = round(W * vb[3] / vb[2])
if H > 1900:
    W = round(W * 1900 / H); H = 1900
font = vb[2] / 95
labels, css = [], []
seen = set()
for it in data['items']:
    x, y, w, h = it['box']
    cx, cy = x + w / 2, y + h / 2
    if not (vb[0] <= cx <= vb[0] + vb[2] and vb[1] <= cy <= vb[1] + vb[3]):
        continue
    if only is not None:
        if it['i'] not in only:
            continue
    elif w * h < min_area:
        continue
    if tint and it['fill'] != 'none':
        r, g, b = colorsys.hsv_to_rgb((it['i'] * 0.381966) % 1, 0.45, 0.95)
        css.append(f'[data-i="{it["i"]}"]{{fill:rgb({int(r*255)},{int(g*255)},{int(b*255)}) !important}}')
    if only is not None:
        css.append(f'[data-i="{it["i"]}"]{{fill:#e02020 !important;stroke:#800 !important}}')
    key = (it['i'], round(cx / font / 2), round(cy / font / 2))
    if key in seen:
        continue
    seen.add(key)
    labels.append(f'<text x="{cx:.2f}" y="{cy + font * 0.35:.2f}" font-size="{font:.3f}" text-anchor="middle" '
                  f'font-family="Helvetica" font-weight="700" fill="#000" stroke="#fff" stroke-width="{font * 0.22:.3f}" paint-order="stroke">{it["i"]}</text>')
svg = svg.replace('</svg>', ''.join(labels) + '</svg>')
page = os.path.join(here, 'work', f'.label-{os.getpid()}.html')
open(page, 'w').write(f'''<!doctype html><meta charset="utf-8"><style>body{{margin:0;background:#fff}}{"".join(css)}</style>
<div id="host">{svg}</div><script>const s=document.querySelector('#host svg');s.setAttribute('viewBox','{vb[0]} {vb[1]} {vb[2]} {vb[3]}');
s.setAttribute('width',{W});s.setAttribute('height',{H});</script>''')
subprocess.run(['/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', '--headless=new', '--disable-gpu', '--hide-scrollbars',
                f'--user-data-dir={here}/.chrome-profile', f'--window-size={W},{H}', '--virtual-time-budget=3000',
                f'--screenshot={out}', 'file://' + page], capture_output=True, timeout=120)
os.remove(page)
print(out, f'{W}x{H}', len(labels), 'labels')
