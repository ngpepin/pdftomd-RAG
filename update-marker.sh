#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARKER_DIR="$SCRIPT_DIR/marker"

have() { command -v "$1" >/dev/null 2>&1; }
match_file() {
  local pattern="$1"
  local file="$2"
  if have rg; then
    rg -q "$pattern" "$file"
  else
    grep -Eq "$pattern" "$file"
  fi
}

if [ ! -d "$MARKER_DIR/.git" ]; then
  echo "Error: $MARKER_DIR is not a git repo. Run ./install.sh first." >&2
  exit 1
fi

echo "Checking marker repo status"
if [ -n "$(git -C "$MARKER_DIR" status --porcelain)" ]; then
  echo "Error: marker repo has local changes; aborting to avoid trampling." >&2
  git -C "$MARKER_DIR" status -sb
  exit 1
fi

echo "Updating marker repo in $MARKER_DIR"
git -C "$MARKER_DIR" fetch origin
git -C "$MARKER_DIR" pull --rebase

echo "Verifying marker entrypoints"
if ! match_file "^\\[tool\\.poetry\\.scripts\\]" "$MARKER_DIR/pyproject.toml"; then
  echo "Warning: [tool.poetry.scripts] not found in marker pyproject.toml" >&2
else
  if ! match_file "^marker\\s*=\\s*\"?marker\\." "$MARKER_DIR/pyproject.toml"; then
    echo "Warning: marker entrypoint not found in pyproject.toml" >&2
  fi
  if ! match_file "^marker_single\\s*=\\s*\"?marker\\." "$MARKER_DIR/pyproject.toml"; then
    echo "Warning: marker_single entrypoint not found in pyproject.toml" >&2
  fi
fi

echo "Validating wrapper script syntax"
bash -n "$SCRIPT_DIR/pdftomd.sh"
"$SCRIPT_DIR/pdftomd.sh" -h >/dev/null

echo "Marker update complete."
