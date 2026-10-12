#!/usr/bin/env bash
# Build the dbpeek data engine for the Noctalia "DB Peek" plugin.
#
# Noctalia loads the plugin's .luau files directly (hot-reloaded during
# development), but the Go engine must be built once:
#
#   dbpeek/install.sh
#
# This only builds the engine to ~/.local/bin/dbpeek-engine. It never touches
# the plugin files.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$(dirname "$REPO_DIR")"
ENGINE_DIR="$REPO_DIR/engine"
OUT="${1:-$HOME/.local/bin/dbpeek-engine}"

if ! command -v go >/dev/null 2>&1; then
  echo "error: go is required to build the engine (install it with your package manager)" >&2
  exit 1
fi

echo "==> Building engine -> $OUT"
mkdir -p "$(dirname "$OUT")"
(cd "$ENGINE_DIR" && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o "$OUT" .)

echo
echo "Engine built. Now add this repo as a Noctalia plugin source and enable DB Peek:"
echo "  noctalia msg plugins source add dbpeek-dev path $SOURCE_DIR"
echo "  noctalia msg plugins enable fuiyooo/dbpeek"
echo
echo "Open the panel with:"
echo "  noctalia msg panel-toggle fuiyooo/dbpeek:peek"
echo
echo "Clear any configured engine_path in the plugin settings to use $OUT,"
echo "or point engine_path at it explicitly."
