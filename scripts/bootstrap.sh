#!/usr/bin/env bash
# scripts/bootstrap.sh — one-shot setup after `git clone`.
#
# Prereq:
#   1. ARIS source repo cloned somewhere
#   2. $ARIS_REPO env var pointing at it
#
# What this does:
#   1. Render .mcp.json from .mcp.json.template via envsubst
#   2. Rebuild .claude/skills/ via install_aris.sh --reconcile
#   3. Print "restart Claude Code" reminder

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

if [[ -z "${ARIS_REPO:-}" ]]; then
  cat <<'MSG' >&2
Error: ARIS_REPO is not set.

Set it to the local clone of the ARIS source repo, e.g.:

  git clone <ARIS source URL> ~/Desktop/Auto-claude-code-research-in-sleep
  export ARIS_REPO=~/Desktop/Auto-claude-code-research-in-sleep

Then re-run: scripts/bootstrap.sh
MSG
  exit 2
fi

if [[ ! -d "$ARIS_REPO" ]]; then
  echo "Error: \$ARIS_REPO ($ARIS_REPO) does not exist." >&2
  exit 2
fi

if [[ ! -x "$ARIS_REPO/tools/install_aris.sh" ]]; then
  echo "Error: $ARIS_REPO/tools/install_aris.sh not found or not executable." >&2
  exit 2
fi

if ! command -v envsubst >/dev/null 2>&1; then
  echo "Error: envsubst not found. Install gettext (e.g. apt install gettext-base)." >&2
  exit 2
fi

WORKSPACE="$REPO_ROOT"
export ARIS_REPO WORKSPACE

echo "[bootstrap] rendering .mcp.json from template..."
envsubst '${ARIS_REPO} ${WORKSPACE}' < .mcp.json.template > .mcp.json

if [[ ! -f CLAUDE.md ]]; then
  echo "[bootstrap] materializing CLAUDE.md from template..."
  cp CLAUDE.md.template CLAUDE.md
else
  echo "[bootstrap] CLAUDE.md exists; leaving local edits in place."
fi

echo "[bootstrap] reconciling ARIS skills..."
bash "$ARIS_REPO/tools/install_aris.sh" "$REPO_ROOT"

cat <<'MSG'

[bootstrap] Done.

Next:
  - Restart Claude Code so the new .mcp.json takes effect.
  - Try: scripts/new-idea.sh my-first-idea
MSG
