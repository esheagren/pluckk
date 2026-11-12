"""Build the anatomy module's figures: tag each named part in the prepared artwork and write one
script per figure (figures/<name>.js) for the module page to load.

Usage: build.py <out_dir>      (out_dir = .../public/modules/anatomy/1)
Needs work/<name>.svg (prep.py) and work/<name>.boxes.json (probe.py).
"""
import copy
import json
import os
import sys
import xml.etree.ElementTree as ET

here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, here)       # figures.py sits beside this script (python -I leaves it off the path)
from figures import FIGURES  # noqa: E402

SVG = 'http://www.w3.org/2000/svg'
ET.register_namespace('', SVG)
ET.register_namespace('xlink', 'http://www.w3.org/1999/xlink')
out_dir = sys.argv[1]
os.makedirs(os.path.join(out_dir, 'figures'), exist_ok=True)


def add_part(el, part):
    have = el.get('data-part', '').split()
    if part not in have:
        el.set('data-part', ' '.join(have + [part]))


credits = []
for name, spec in FIGURES.items():
    root = ET.parse(os.path.join(here, 'work', name + '.svg')).getroot()
    boxes = json.load(open(os.path.join(here, 'work', name + '.boxes.json')))
    style = {}
    for it in boxes['items']:
        style[it['i']] = (it['fill'] == 'none', it['stroke'] == 'none')
    parent = {c: p for p in root.iter() for c in p}
    by_num, by_id = {}, {}
    for el in root.iter():
        if el.get('data-i') is not None:
            by_num.setdefault(int(el.get('data-i')), []).append(el)
        if el.get('id'):
            by_id[el.get('id')] = el

    missing = []
    for part, (_, shapes) in spec['parts'].items():
        for s in shapes:
            found = by_num.get(s, []) if isinstance(s, int) else ([by_id[s]] if s in by_id else [])
            if not found:
                missing.append(f'{part}:{s}')
            for el in found:
                add_part(el, part)

    # Cut a shape into pieces: each piece is the shape again, clipped to its region.
    n_clip = 0
    for split in spec.get('splits', []):
        for el in by_num.get(split['shape'], []):
            p = parent[el]
            at = list(p).index(el)
            p.remove(el)
            for part, region in split['pieces']:
                n_clip += 1
                cid = f'cut{n_clip}'
                clip = ET.Element('{%s}clipPath' % SVG, {'id': cid})
                ET.SubElement(clip, '{%s}path' % SVG, {'d': region})
                piece = copy.deepcopy(el)
                piece.set('clip-path', f'url(#{cid})')
                add_part(piece, part)
                p.insert(at, clip)
                p.insert(at + 1, piece)
                at += 2

    # Mark every drawable, and those with no fill or no stroke (the page needs to know when it
    # repaints the figure as a mask).
    for el in root.iter():
        i = el.get('data-i')
        if i is None:
            continue
        del el.attrib['data-i']
        el.set('data-d', '')
        no_fill, no_stroke = style.get(int(i), (False, False))
        if no_fill:
            el.set('data-nf', '')
        if no_stroke:
            el.set('data-ns', '')

    drawn = [it['box'] for it in boxes['items'] if it['box'][2] > 0 or it['box'][3] > 0]     # not the shapes inside clip paths
    xs = [v for b in drawn for v in (b[0], b[0] + b[2])]
    ys = [v for b in drawn for v in (b[1], b[1] + b[3])]
    pad = (max(xs) - min(xs)) * 0.02
    view = [round(min(xs) - pad, 2), round(min(ys) - pad, 2), round(max(xs) - min(xs) + 2 * pad, 2), round(max(ys) - min(ys) + 2 * pad, 2)]
    root.set('viewBox', ' '.join(str(v) for v in view))
    markup = ET.tostring(root, encoding='unicode')
    title, author, licence, url = spec['credit']
    figure = {
        'name': name, 'title': spec['title'], 'view': view, 'height': spec['height'], 'caption': spec.get('caption'),
        'credit': f'{author} · {licence}', 'source': url,
        'parts': {part: label for part, (label, _) in spec['parts'].items()},
        'svg': markup,
    }
    path = os.path.join(out_dir, 'figures', name + '.js')
    with open(path, 'w') as f:
        f.write(f'// {spec["title"]}. Artwork: "{title}" by {author}, {licence}. {url}\n')
        f.write('// Built by scripts/anatomy/build.py: the artwork with each named part tagged (data-part).\n')
        f.write('window.AnatomyFigure = ' + json.dumps(figure, ensure_ascii=False) + ';\n')
    credits.append((spec['title'], title, author, licence, url))
    print(f'{name}: {len(spec["parts"])} parts, view {view}, {os.path.getsize(path) // 1024} KB' + (f'  MISSING {missing}' if missing else ''))

with open(os.path.join(out_dir, 'CREDITS.md'), 'w') as f:
    f.write('# Artwork in the anatomy module\n\n')
    f.write('The figures are adapted from illustrations on Wikimedia Commons: labels and editor data removed,\n'
            'mirrored halves expanded, and each named part tagged so it can be highlighted and clicked.\n'
            'Adaptations of CC BY-SA works are offered under the same licence.\n\n')
    f.write('| Figure | Source | Author | Licence |\n|---|---|---|---|\n')
    for fig_title, title, author, licence, url in credits:
        f.write(f'| {fig_title} | [{title}]({url}) | {author} | {licence} |\n')
print('CREDITS.md written')
