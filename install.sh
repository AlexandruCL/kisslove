#!/usr/bin/env bash
# Install the kisslove Kiro setup onto this machine (macOS / Linux).
# Copies bundled agents, skills, steering, hooks, powers, and portable settings
# into ~/.kiro, backing up anything it would overwrite. Then installs the
# graphify CLI that the graphify skill + hook depend on.
#
# Usage:
#   ./install.sh                 # full install
#   SKIP_GRAPHIFY=1 ./install.sh # skip graphify CLI install
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE="$SCRIPT_DIR/.kiro"
TARGET="$HOME/.kiro"

echo "kisslove installer"
echo "  bundle: $BUNDLE"
echo "  target: $TARGET"

[ -d "$BUNDLE" ] || { echo "Bundle not found at $BUNDLE - run from repo root."; exit 1; }

# 1. Back up existing config we might overwrite
if [ -d "$TARGET" ]; then
  STAMP="$(date +%Y%m%d-%H%M%S)"
  BACKUP="$HOME/.kiro-backup-$STAMP"
  mkdir -p "$BACKUP"
  for d in agents skills steering hooks powers settings; do
    [ -d "$TARGET/$d" ] && cp -R "$TARGET/$d" "$BACKUP/$d"
  done
  echo "  backed up existing config -> $BACKUP"
fi

mkdir -p "$TARGET"

# 2. Merge the bundle into ~/.kiro (copy, never delete other content)
for d in agents skills steering hooks powers; do
  if [ -d "$BUNDLE/$d" ]; then
    mkdir -p "$TARGET/$d"
    cp -R "$BUNDLE/$d/." "$TARGET/$d/"
    echo "  installed $d/"
  fi
done

mkdir -p "$TARGET/settings"
for f in mcp.json cli.json; do
  if [ -f "$BUNDLE/settings/$f" ]; then
    if [ -f "$TARGET/settings/$f" ]; then
      echo "  settings/$f already exists - left untouched"
    else
      cp "$BUNDLE/settings/$f" "$TARGET/settings/$f"
      echo "  installed settings/$f"
    fi
  fi
done

# 3. graphify CLI
if [ "${SKIP_GRAPHIFY:-0}" != "1" ]; then
  echo ""
  echo "Installing graphify CLI (graphifyy)..."
  PY=""
  for c in python3 python; do command -v "$c" >/dev/null 2>&1 && { PY="$c"; break; }; done
  if [ -n "$PY" ]; then
    if command -v uv >/dev/null 2>&1; then
      uv tool install --upgrade graphifyy || "$PY" -m pip install --user graphifyy
    else
      "$PY" -m pip install --user graphifyy || "$PY" -m pip install --user --break-system-packages graphifyy
    fi
    echo "  graphify installed - verify: $PY -m graphify --version"
  else
    echo "  Python not found - install Python 3.10+ then: python3 -m pip install --user graphifyy"
  fi
else
  echo ""
  echo "Skipped graphify CLI install (SKIP_GRAPHIFY=1)."
fi

echo ""
echo "Done. Restart Kiro to pick up the new global agents, skills, and steering."
echo "In each project where you want the code graph: run  /graphify .  once."
