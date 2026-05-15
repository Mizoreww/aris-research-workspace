# aris-research-workspace

A clean, multi-idea research workspace template built on top of [ARIS](https://github.com/wanshuiyin/Auto-claude-code-research-in-sleep) (Auto-claude-code-research-in-sleep). Each new research idea lives in its own isolated subfolder under `ideas/`, with phase-aligned subdirectories that map 1:1 to ARIS skill families (idea-discovery → experiment → results → paper → reviews).

## Layout

```
aris-research-workspace/
├── README.md              ← this file
├── CLAUDE.md.template     ← rendered to CLAUDE.md by bootstrap (gitignored)
├── .mcp.json.template     ← rendered to .mcp.json by bootstrap (gitignored)
├── scripts/
│   ├── bootstrap.sh       ← post-clone setup
│   ├── new-idea.sh <slug> ← scaffold a new idea
│   └── README.md
├── .aris/                 ← ARIS runtime state (mostly gitignored)
├── .claude/skills/        ← gitignored; rebuilt by bootstrap
└── ideas/
    └── <YYYY-MM-DD>_<slug>/
        ├── MANIFEST.md
        ├── idea/
        ├── experiment/{code,configs}
        ├── runs/             ← gitignored (training outputs)
        ├── results/{tables,plots}
        ├── paper/figures/ai_generated/
        └── reviews/
```

## Quickstart

```bash
git clone https://github.com/Mizoreww/aris-research-workspace.git aris-research-workspace
cd aris-research-workspace

# 1. Get ARIS source repo
git clone https://github.com/wanshuiyin/Auto-claude-code-research-in-sleep.git ~/Desktop/Auto-claude-code-research-in-sleep
export ARIS_REPO=~/Desktop/Auto-claude-code-research-in-sleep

# 2. One-shot bootstrap (renders .mcp.json + CLAUDE.md, links ARIS skills)
scripts/bootstrap.sh

# 3. Restart Claude Code (so .mcp.json takes effect)

# 4. Create your first idea
scripts/new-idea.sh joint-delta-statefree
cd ideas/$(date +%Y-%m-%d)_joint-delta-statefree
```

## Per-idea phase mapping

| Subfolder | Owning ARIS skills |
|---|---|
| `idea/` | idea-discovery, research-lit, novelty-check, research-refine |
| `experiment/` | experiment-plan, experiment-bridge, run-experiment |
| `runs/` | monitor-experiment, training-check, serverless-modal |
| `results/` | analyze-results, result-to-claim, ablation-planner |
| `paper/` | paper-plan, paper-write, paper-figure, paper-compile |
| `reviews/` | auto-review-loop, paper-claim-audit, rebuttal |

## License

MIT.
