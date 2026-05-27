#!/usr/bin/env bash
# install.sh — Install the Stride Lite plugin for Claude Code.
#
# Usage:
#   ./install.sh                # install into ~/.claude/plugins/stride-lite/
#   ./install.sh --force        # overwrite an existing install
#   ./install.sh --help         # show usage
#
# Targets Claude Code's plugin directory ($HOME/.claude/plugins/). Refuses to
# clobber an existing stride-lite/ install unless --force is given. Run from
# the cloned plugin repo root (the script copies the surrounding files into
# the install directory).

set -euo pipefail

FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --help|-h)
      cat <<'EOF'
Usage: install.sh [--force]

  (default)   Install Stride Lite to $HOME/.claude/plugins/stride-lite/
  --force     Overwrite an existing install at that path

Run from the cloned plugin repo root.
EOF
      exit 0
      ;;
    *)
      echo "install.sh: unknown argument: $arg" >&2
      echo "Run 'install.sh --help' for usage." >&2
      exit 1
      ;;
  esac
done

if [ -z "${HOME:-}" ]; then
  echo "install.sh: HOME is not set; cannot resolve install target" >&2
  exit 1
fi

# Resolve the directory containing this script — the source we copy from.
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="$HOME/.claude/plugins/stride-lite"

# Sanity check: the source dir must contain the plugin manifest.
if [ ! -f "$SRC_DIR/.claude-plugin/plugin.json" ]; then
  echo "install.sh: missing $SRC_DIR/.claude-plugin/plugin.json — run from the plugin repo root" >&2
  exit 1
fi

if [ -e "$TARGET_DIR" ] && [ "$FORCE" -ne 1 ]; then
  echo "install.sh: target already exists at $TARGET_DIR" >&2
  echo "Re-run with --force to overwrite." >&2
  exit 1
fi

echo "Installing Stride Lite to $TARGET_DIR..."

mkdir -p "$(dirname "$TARGET_DIR")"

if [ "$FORCE" -eq 1 ] && [ -e "$TARGET_DIR" ]; then
  echo "  --force: removing existing $TARGET_DIR"
  rm -rf "$TARGET_DIR"
fi

mkdir -p "$TARGET_DIR"

# Copy plugin contents into the target. Use cp -a to preserve file modes
# (the .sh files retain the executable bit). The . at the end of the source
# copies directory contents rather than the directory itself.
cp -a "$SRC_DIR/.claude-plugin" "$TARGET_DIR/"
cp -a "$SRC_DIR/commands" "$TARGET_DIR/"
cp -a "$SRC_DIR/skills" "$TARGET_DIR/"
cp -a "$SRC_DIR/agents" "$TARGET_DIR/"
cp -a "$SRC_DIR/lib" "$TARGET_DIR/"
cp -a "$SRC_DIR/README.md" "$TARGET_DIR/"
cp -a "$SRC_DIR/AGENTS.md" "$TARGET_DIR/"
cp -a "$SRC_DIR/LICENSE" "$TARGET_DIR/"
cp -a "$SRC_DIR/CHANGELOG.md" "$TARGET_DIR/"

echo ""
echo "Stride Lite installed successfully."
echo ""
echo "Installed:"
echo "  Commands: $(ls "$TARGET_DIR/commands"/*.md 2>/dev/null | wc -l | tr -d ' ') slash commands"
echo "  Skills:   $(ls -d "$TARGET_DIR/skills"/*/ 2>/dev/null | wc -l | tr -d ' ') skill directories"
echo "  Agents:   $(ls "$TARGET_DIR/agents"/*.md 2>/dev/null | wc -l | tr -d ' ') subagents"
echo "  Lib:      $(ls "$TARGET_DIR/lib"/*.md 2>/dev/null | wc -l | tr -d ' ') helper specs"
echo ""
echo "Next steps:"
echo "  1. Restart Claude Code (or run /plugin reload) so the new commands are picked up."
echo "  2. Try the new commands:"
echo "       /stride-lite:create-goal <prompt>"
echo "       /stride-lite:create-task <prompt>"
echo "  3. See ~/.claude/plugins/stride-lite/README.md for full usage."
