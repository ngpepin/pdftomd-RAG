#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARKER_DIR="$SCRIPT_DIR/marker"
MARKER_REPO="https://github.com/VikParuchuri/marker.git"
MARKER_VENV="$MARKER_DIR/venv"
CONF_FILE="$SCRIPT_DIR/pdftomd.conf"
CONF_PUB="$SCRIPT_DIR/pdftomd.conf.pub"
FORCE_CONF=false

have() { command -v "$1" >/dev/null 2>&1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)
      FORCE_CONF=true
      shift
      ;;
    -h|--help)
      echo "Usage: $(basename "$0") [--force]"
      echo "  --force   overwrite pdftomd.conf by copying pdftomd.conf.pub before updating paths"
      exit 0
      ;;
    *)
      echo "Error: Unknown option '$1'" >&2
      exit 1
      ;;
  esac
done

if [ -d "$MARKER_DIR/.git" ]; then
  echo "Updating existing marker repo in $MARKER_DIR"
  git -C "$MARKER_DIR" pull --rebase
elif [ -e "$MARKER_DIR" ]; then
  echo "Error: $MARKER_DIR exists but is not a git repo." >&2
  exit 1
else
  echo "Cloning marker into $MARKER_DIR"
  git clone --depth 1 "$MARKER_REPO" "$MARKER_DIR"
fi

if ! have python3; then
  echo "Error: python3 is required to create the marker venv." >&2
  exit 1
fi

echo "Setting up marker venv in $MARKER_VENV"
if [ ! -d "$MARKER_VENV" ]; then
  python3 -m venv "$MARKER_VENV"
fi

# shellcheck disable=SC1090
source "$MARKER_VENV/bin/activate"
python -m pip install --upgrade pip setuptools wheel

echo "Installing marker dependencies"
python -m pip install -e "$MARKER_DIR"

set_conf_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  if rg -q "^${key}=" "$file"; then
    # Replace the first matching line, preserving trailing comments.
    perl -0777 -i -pe "s|^${key}=.*?$|${key}=${value}|m" "$file"
  else
    echo "${key}=${value}" >>"$file"
  fi
}

if [ "$FORCE_CONF" = true ]; then
  if [ -f "$CONF_PUB" ]; then
    echo "Forcing pdftomd.conf from pdftomd.conf.pub"
    cp "$CONF_PUB" "$CONF_FILE"
  else
    echo "Error: pdftomd.conf.pub not found; cannot --force." >&2
    exit 1
  fi
elif [ -f "$CONF_FILE" ]; then
  echo "Updating pdftomd.conf with installed marker paths"
else
  if [ -f "$CONF_PUB" ]; then
    echo "Creating pdftomd.conf from pdftomd.conf.pub"
    cp "$CONF_PUB" "$CONF_FILE"
  else
    echo "Creating minimal pdftomd.conf"
    cat >"$CONF_FILE" <<EOF
#!/bin/bash
MARKER_DIRECTORY="$MARKER_DIR"
MARKER_VENV="venv"
MARKER_RESULTS="$MARKER_DIR/venv/lib/python3.10/site-packages/conversion_results"
EOF
  fi
fi

set_conf_value "$CONF_FILE" "MARKER_DIRECTORY" "\"$MARKER_DIR\""
set_conf_value "$CONF_FILE" "MARKER_VENV" "\"venv\""
set_conf_value "$CONF_FILE" "MARKER_RESULTS" "\"$MARKER_DIR/venv/lib/python3.10/site-packages/conversion_results\""
set_conf_value "$CONF_FILE" "OCR_SCRIPT" "\"$SCRIPT_DIR/ocr-pdf/ocr-pdf.sh\""

echo "Marker install complete."
