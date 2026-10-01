#!/usr/bin/env bash
set -euo pipefail
# Restores the former interface with a normal commit; preserves all database data.
cd "$(dirname "$0")/.."
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo 'Le dépôt contient des modifications non enregistrées. Enregistre-les avant le retour arrière.' >&2
  exit 1
fi
git restore --source=4c33a5373324d2758969c3500ea7e77284ba33cc -- index.html sw.js
python3 - <<'PY'
from pathlib import Path
p=Path('sw.js');p.write_text(p.read_text().replace("pointage-collectif-v10", "pointage-collectif-retour-20261001"))
PY
git add index.html sw.js
git commit -m 'Restore interface saved before annual catalogue changes'
echo 'Ancienne interface restaurée localement. Publier ce commit pour la remettre en ligne.'
