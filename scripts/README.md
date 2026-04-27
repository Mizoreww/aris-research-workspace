# scripts/

| Script | Purpose |
|---|---|
| `bootstrap.sh` | Run once after `git clone`. Renders `.mcp.json` from template, materializes `CLAUDE.md` from template, rebuilds `.claude/skills/`. Requires `$ARIS_REPO` env var. |
| `new-idea.sh <slug>` | Scaffold a new idea folder at `ideas/<today>_<slug>/` with the phase-aligned subtree (idea/experiment/runs/results/paper/reviews) and a starter `MANIFEST.md`. |

## Quickstart

```bash
git clone <this repo URL>
cd aris-research-workspace
git clone <ARIS source repo URL> ~/Desktop/Auto-claude-code-research-in-sleep
export ARIS_REPO=~/Desktop/Auto-claude-code-research-in-sleep
scripts/bootstrap.sh
scripts/new-idea.sh my-first-idea
```
