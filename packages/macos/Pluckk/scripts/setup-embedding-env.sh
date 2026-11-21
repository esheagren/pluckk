#!/bin/sh
# The Mac app files new cards into topic decks and finds related cards with a local embedding
# model (nomic-embed-text-v1.5, run by sentence-transformers). This makes the Python environment
# it uses, in Application Support so iCloud Drive never offloads it. Needs uv (https://docs.astral.sh/uv/).
set -e
ENV="$HOME/Library/Application Support/Pluckk/python-env"
uv venv "$ENV" --python 3.13
uv pip install --python "$ENV/bin/python" numpy torch sentence-transformers einops
echo "Ready: $ENV"
