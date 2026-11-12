"""Prepare a source SVG for the anatomy module: drop editor baggage and text, expand <use> clones
into real elements, and number every drawable (data-i) so parts can be assigned to them.

Usage: prep.py <src.svg> <out.svg> [--keep <id>] [--drop <id> ...]
  --keep <id>   keep only this element among its siblings (e.g. the front figure of a front/back pair)
  --drop <id>   remove an element (repeatable)
A mirrored <use> copy carries the same numbers as its original, so both sides share a part.
"""
import copy
import re
import sys
import xml.etree.ElementTree as ET

SVG = 'http://www.w3.org/2000/svg'
XLINK = 'http://www.w3.org/1999/xlink'
ET.register_namespace('', SVG)
ET.register_namespace('xlink', XLINK)
DRAWABLE = {'path', 'rect', 'circle', 'ellipse', 'polygon', 'polyline', 'line'}
JUNK_NS = ('sodipodi', 'inkscape', 'purl.org', 'creativecommons', 'w3.org/1999/02/22-rdf', 'ns.adobe', 'xml/1998')


def local(tag):
    return tag.split('}')[-1]


def junk(name):
    return name.startswith('{') and any(n in name for n in JUNK_NS)


def clean(el):
    for child in list(el):
        tag = child.tag
        if not isinstance(tag, str) or junk(tag) or local(tag) in ('metadata', 'title', 'desc', 'text', 'script', 'foreignObject', 'a', 'image'):
            el.remove(child)
            continue
        clean(child)
    for k in list(el.attrib):
        if junk(k) or k.lower().startswith('on'):
            del el.attrib[k]


def main():
    args = sys.argv[1:]
    src, out = args[0], args[1]
    keep = [args[i + 1] for i, a in enumerate(args) if a == '--keep']
    drop = [args[i + 1] for i, a in enumerate(args) if a == '--drop']
    root = ET.parse(src).getroot()
    clean(root)
    parent = {c: p for p in root.iter() for c in p}
    by_id = {e.get('id'): e for e in root.iter() if e.get('id')}
    for ident in keep:
        el = by_id[ident]
        for sib in list(parent[el]):
            if sib is not el and local(sib.tag) in {'g', 'use'} | DRAWABLE:
                parent[el].remove(sib)
    for ident in drop:
        el = by_id.get(ident)
        if el is not None:
            parent[el].remove(el)

    # Number the drawables outside <defs>, in document order.
    n = 0

    def number(el, in_defs):
        nonlocal n
        tag = local(el.tag)
        in_defs = in_defs or tag in ('defs', 'clipPath', 'mask', 'pattern', 'marker', 'symbol')
        if tag in DRAWABLE and not in_defs:
            el.set('data-i', str(n))
            n += 1
        for c in el:
            number(c, in_defs)

    number(root, False)

    # Expand <use> into a group holding a copy of what it points at.
    def expand(el):
        for i, child in enumerate(list(el)):
            if local(child.tag) == 'use':
                ref = (child.get('{%s}href' % XLINK) or child.get('href') or '').lstrip('#')
                target = by_id.get(ref)
                if target is None:
                    el.remove(child)
                    continue
                g = ET.Element('{%s}g' % SVG)
                t = child.get('transform') or ''
                x, y = child.get('x'), child.get('y')
                if x or y:
                    t = f'{t} translate({x or 0},{y or 0})'.strip()
                if t:
                    g.set('transform', t)
                if child.get('style'):
                    g.set('style', child.get('style'))
                dup = copy.deepcopy(target)
                for e in dup.iter():
                    e.attrib.pop('id', None)
                g.append(dup)
                el.remove(child)
                el.insert(i, g)
                expand(g)
            else:
                expand(child)

    expand(root)
    if not root.get('viewBox'):
        w = float(re.sub(r'[a-z%]+$', '', root.get('width', '100')))
        h = float(re.sub(r'[a-z%]+$', '', root.get('height', '100')))
        root.set('viewBox', f'0 0 {w} {h}')
    for k in ('width', 'height', 'x', 'y', 'style', 'version', 'enable-background', 'id'):
        root.attrib.pop(k, None)
    ET.ElementTree(root).write(out, encoding='unicode', xml_declaration=False)
    print(f'{out}: {n} drawables, viewBox {root.get("viewBox")}')


main()
