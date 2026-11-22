#!/usr/bin/env bash
# Copies (or updates) the openrouter addon into a Godot project.
#   scripts/install-godot.sh <project_dir>
set -euo pipefail
LIB="$(cd "$(dirname "$0")/.." && pwd)"
PROJ="${1:?usage: install-godot.sh <project_dir>}"
[ -f "$PROJ/project.godot" ] || { echo "$PROJ has no project.godot" >&2; exit 1; }
rm -rf "$PROJ/addons/openrouter"
mkdir -p "$PROJ/addons"
cp -R "$LIB/godot/addons/openrouter" "$PROJ/addons/openrouter"
git -C "$LIB" rev-parse --short HEAD > "$PROJ/addons/openrouter/VERSION" 2>/dev/null || true
echo "Installed addons/openrouter into $PROJ"
cat <<'MSG'
Next: add an autoload, e.g.  AI="*res://addons/openrouter/openrouter_client.gd"
and configure it at startup (see README "Godot").
MSG
