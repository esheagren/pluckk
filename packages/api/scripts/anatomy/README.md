# Building the anatomy figures

The anatomy module (`public/modules/anatomy/1`) shows real anatomical illustrations with named
parts that can be tinted and clicked. The illustrations come from Wikimedia Commons; these scripts
turn each one into a figure the module can load. `sh make.sh` does the whole thing.

| Script | What it does |
|---|---|
| `fetch.py` | Downloads the source illustrations into `src/`, with their licence details |
| `prep.py` | Strips editor data and text, expands mirrored `<use>` copies into real shapes, and numbers every shape |
| `probe.py` | Measures every shape with headless Chrome (box, fill, group) into `work/<name>.boxes.json` |
| `label.py` | Renders a figure with each shape's number on it, to work out which shapes make a part |
| `info.py` | Lists a figure's shapes or named groups as text |
| `figures.py` | The mapping: which shapes (by number or by the source's own ids) make up each named part |
| `build.py` | Tags the parts in the artwork and writes `figures/<name>.js` and `CREDITS.md` |

`src/` and `work/` are scratch folders and aren't committed.

## Adding or fixing a part

1. `python3 -I label.py <figure> /tmp/out.png --tint` and find the shape numbers (add `x y w h` to
   zoom in, `--only 12,13` to paint particular shapes red).
2. Add the part to `figures.py`. Use the source's group ids where it has them (the skeleton and
   heart do); numbers otherwise. A fill and its outline are often separate shapes: list both.
3. `sh make.sh`, then look at the result (the Modules page in the Mac app previews it).

Two things the artwork doesn't do for you:

- **One shape, two muscles.** Where the artist drew two parts as one shape with a line across it
  (the deltoid and the upper chest), `splits` in `figures.py` cuts the shape along that line.
- **Shapes behind other shapes.** The module tints a part only where it shows, by repainting the
  whole figure as a mask, so overlapping shapes need no special handling here.

## Licences

Sources are public domain or CC BY-SA. Adapted CC BY-SA figures stay under CC BY-SA, and every
figure credits its author in the module and in `CREDITS.md`, which `build.py` writes.
