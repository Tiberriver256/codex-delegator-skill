# AGENTS.md

This repo requires Agent Skills validation to run before every commit.

## Required pre-commit hook
The hook must execute:

```sh
uv run scripts/validate-skills-ref.py
```

## Setup
1) Ensure `uv` is installed.
2) Create `.git/hooks/pre-commit` with the contents below.
3) Make it executable: `chmod +x .git/hooks/pre-commit`.

```sh
#!/bin/sh
set -e

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

uv run scripts/validate-skills-ref.py
```

## Notes
- The hook is a local git file and is **not** versioned; it must be created after each clone.
- The validation script uses the `agentskills` CLI from the `skills-ref` package and will auto-download dependencies on first run.
- You can run it manually at any time with `uv run scripts/validate-skills-ref.py`.
