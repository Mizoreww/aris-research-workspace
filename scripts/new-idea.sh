#!/usr/bin/env bash
# scripts/new-idea.sh — scaffold a new idea folder under ideas/<YYYY-MM-DD>_<slug>/
#
# Usage:
#   scripts/new-idea.sh <kebab-slug>
#
# Example:
#   scripts/new-idea.sh joint-delta-statefree

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <kebab-slug>" >&2
  exit 2
fi

SLUG="$1"

# Validate kebab-case: lowercase letters/digits, hyphens between, no leading/trailing hyphen
if ! [[ "$SLUG" =~ ^[a-z][a-z0-9]*(-[a-z0-9]+)*$ ]]; then
  echo "Error: slug must be kebab-case (lowercase letters, digits, hyphens). Got: '$SLUG'" >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATE="$(date +%Y-%m-%d)"
TARGET="$REPO_ROOT/ideas/${DATE}_${SLUG}"

if [[ -e "$TARGET" ]]; then
  echo "Error: $TARGET already exists." >&2
  exit 1
fi

mkdir -p "$TARGET"/{idea,experiment/code,experiment/configs,runs,results/tables,results/plots,paper/figures/ai_generated,reviews}

# Drop .gitkeep in every empty leaf so git tracks structure
for d in idea experiment/code experiment/configs runs results/tables results/plots paper/figures/ai_generated reviews; do
  touch "$TARGET/$d/.gitkeep"
done

cat > "$TARGET/MANIFEST.md" <<EOF
# Idea Manifest: ${SLUG}

- **slug:** ${SLUG}
- **created:** ${DATE}
- **status:** idea-stage
- **workspace:** aris-research-workspace

## Phase tracking

| Phase | Status | Last update | Notes |
|---|---|---|---|
| idea | not started | ${DATE} | |
| experiment | not started | | |
| results | not started | | |
| paper | not started | | |
| reviews | not started | | |

## Subdirectories

- \`idea/\` — idea-discovery markdown outputs
- \`experiment/\` — experiment plan, code, configs
- \`runs/\` — training outputs (gitignored except runs/README.md)
- \`results/\` — analyze-results products
- \`paper/\` — LaTeX, figures, refs
- \`reviews/\` — auto-review-loop / rebuttal outputs
EOF

cat > "$TARGET/runs/README.md" <<'EOF'
# Runs

Each subdirectory under `runs/` is one training/inference run. Naming convention:

- `<run_id>/` where `<run_id>` is `YYYY-MM-DD_<short-tag>` (e.g. `2026-04-28_baseline-seed0`)
- Inside: `logs/`, `checkpoints/`, `wandb/`, `config.yaml` (snapshot)

`runs/*` is gitignored except this README. Track key results by copying summaries into `../results/`.

If runs live on a remote machine, record the path here:

| run_id | machine | absolute path |
|---|---|---|
| (example) 2026-04-28_baseline-seed0 | H100 / L20X / local | /path/on/that/box |
EOF

echo "Created idea folder: $TARGET"
echo "$TARGET"
