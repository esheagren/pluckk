"""Measure a prepared figure with headless Chrome: every numbered drawable's box (in the figure's
own units), its fill, and each named group's box. Writes work/<name>.boxes.json.
Usage: probe.py <name>"""
import json
import os
import re
import subprocess
import sys

here = os.path.dirname(os.path.abspath(__file__))
name = sys.argv[1]
svg = open(os.path.join(here, 'work', name + '.svg')).read()
page = os.path.join(here, 'work', f'.probe-{name}.html')
html = '''<!doctype html><meta charset="utf-8"><body style="margin:0">
<div id="host" style="width:1200px">%s</div><pre id="out"></pre>
<script>
const svg = document.querySelector('#host svg');
svg.setAttribute('width', 1200);
const inv = svg.getScreenCTM().inverse();
const pt = (x, y) => { const p = svg.createSVGPoint(); p.x = x; p.y = y; return p.matrixTransform(inv); };
const box = (el) => { const r = el.getBoundingClientRect(); const a = pt(r.left, r.top), b = pt(r.right, r.bottom);
  return [a.x, a.y, b.x - a.x, b.y - a.y].map(v => Math.round(v * 100) / 100); };
const ids = (el) => { const out = []; for (let p = el.parentElement; p && p !== svg; p = p.parentElement) if (p.id) out.unshift(p.id); return out; };
const items = [...svg.querySelectorAll('[data-i]')].map(el => { const cs = getComputedStyle(el);
  return { i: +el.dataset.i, id: el.id || null, box: box(el), fill: cs.fill, stroke: cs.stroke, groups: ids(el), cls: el.getAttribute('class') }; });
const groups = [...svg.querySelectorAll('g[id]')].map(g => ({ id: g.id, box: box(g), n: g.querySelectorAll('[data-i]').length, parent: ids(g) }));
document.getElementById('out').textContent = 'JSON>>' + JSON.stringify({ viewBox: svg.getAttribute('viewBox'), items, groups }) + '<<JSON';
</script>''' % svg
open(page, 'w').write(html)
dom = subprocess.run(['/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', '--headless=new', '--disable-gpu',
                      f'--user-data-dir={here}/.chrome-profile', '--window-size=1300,2600', '--virtual-time-budget=4000',
                      '--dump-dom', 'file://' + page], capture_output=True, text=True, timeout=120).stdout
os.remove(page)
m = re.search(r'JSON&gt;&gt;(.*?)&lt;&lt;JSON', dom, re.S)
if not m:
    sys.exit('no data came back from Chrome')
import html as htmllib
data = json.loads(htmllib.unescape(m.group(1)))
json.dump(data, open(os.path.join(here, 'work', name + '.boxes.json'), 'w'))
xs = [b for it in data['items'] for b in (it['box'][0], it['box'][0] + it['box'][2])]
ys = [b for it in data['items'] for b in (it['box'][1], it['box'][1] + it['box'][3])]
print(f"{name}: {len(data['items'])} drawables, {len(data['groups'])} named groups, viewBox {data['viewBox']}, "
      f"content x {min(xs):.1f}..{max(xs):.1f}, y {min(ys):.1f}..{max(ys):.1f}")
