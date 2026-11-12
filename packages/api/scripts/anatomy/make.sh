#!/bin/sh
# Rebuilds the anatomy module's figures from their source illustrations on Wikimedia Commons.
# Downloads the sources if they aren't here yet, prepares and measures each, then writes
# public/modules/anatomy/1/figures/*.js and CREDITS.md. Needs Google Chrome (to measure shapes).
set -e
cd "$(dirname "$0")"
if [ ! -d src ]; then
  python3 -I fetch.py "File:Muscles front and back.svg" "File:Human skeleton front - no labels.svg" \
    "File:Animal cell structure no text.svg" "File:Diagram of the human heart (no labels).svg" "File:Lobes of the brain NL.svg"
fi
mkdir -p work
python3 -I prep.py src/Muscles_front_and_back.svg work/muscles.svg --keep g4116
python3 -I prep.py src/Muscles_front_and_back.svg work/muscles-back.svg --keep g3613
python3 -I prep.py "src/Human_skeleton_front_-_no_labels.svg" work/skeleton.svg --drop layer4
python3 -I prep.py "src/Diagram_of_the_human_heart_(no_labels).svg" work/heart.svg
python3 -I prep.py src/Lobes_of_the_brain_NL.svg work/brain.svg
python3 -I prep.py src/Animal_cell_structure_no_text.svg work/cell.svg
for name in muscles muscles-back skeleton heart brain cell; do python3 -I probe.py "$name"; done
python3 -I build.py ../../public/modules/anatomy/1
node ../build-module-index.mjs
