#!/bin/bash
# Installs the Kokoro speech engine where Earshot looks for it:
#   ~/Library/Application Support/Earshot/engine
# Needs uv (https://docs.astral.sh/uv/). Downloads ~400 MB (model + Python packages) once;
# after that the engine runs fully offline.
set -euo pipefail
SRC="$(cd "$(dirname "$0")/../engine" && pwd)"
DEST="$HOME/Library/Application Support/Earshot/engine"

command -v uv >/dev/null || { echo "Install uv first: brew install uv"; exit 1; }
mkdir -p "$DEST"
cp "$SRC/server.py" "$SRC/pyproject.toml" "$SRC/uv.lock" "$DEST/"
cd "$DEST"
uv sync --frozen
# Fetch the model, voices and the English text pipeline now, while online.
uv run python - <<'PY'
from mlx_audio.tts.utils import load_model
m = load_model("prince-canuma/Kokoro-82M")
for voice in ("af_heart", "bf_emma"):
    for _ in m.generate("Installed.", voice=voice, lang_code=voice[0]):
        pass
print("Kokoro engine ready")
PY
echo "Installed to $DEST — restart Earshot to use it."
