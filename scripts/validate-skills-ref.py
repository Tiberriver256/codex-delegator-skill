#!/usr/bin/env python3
# /// script
# dependencies = ["skills-ref"]
# ///
"""Run skills-ref validation for this repo."""

from __future__ import annotations

import pathlib
import re
import subprocess
import sys


def _parse_frontmatter(text: str) -> dict[str, str]:
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return {}
    frontmatter: dict[str, str] = {}
    for line in lines[1:]:
        if line.strip() == "---":
            break
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        frontmatter[key.strip()] = value.strip().strip('"').strip("'")
    return frontmatter


def _manual_lint(repo_root: pathlib.Path) -> list[str]:
    errors: list[str] = []
    skill_path = repo_root / "SKILL.md"
    if not skill_path.exists():
        return ["SKILL.md is missing."]

    text = skill_path.read_text(encoding="utf-8")
    lines = text.splitlines()

    if len(lines) > 500:
        errors.append(f"SKILL.md should be 500 lines or fewer (found {len(lines)}).")

    if "utilities/common-roles" in text:
        errors.append("SKILL.md references utilities/common-roles/, but the directory is common-roles/.")

    frontmatter = _parse_frontmatter(text)
    skill_name = frontmatter.get("name")
    if skill_name and skill_name != repo_root.name:
        errors.append(f"Frontmatter name '{skill_name}' must match folder name '{repo_root.name}'.")

    common_roles_dir = repo_root / "common-roles"
    if not common_roles_dir.is_dir():
        errors.append("Missing common-roles/ directory.")

    # Validate listed roles exist.
    roles: list[str] = []
    in_roles_table = False
    for line in lines:
        if line.strip() == "### Available Roles":
            in_roles_table = True
            continue
        if in_roles_table and line.startswith("### "):
            break
        if in_roles_table:
            roles.extend(re.findall(r"`([^`]+)`", line))

    for role in roles:
        role_file = common_roles_dir / f"{role}.md"
        if not role_file.exists():
            errors.append(f"Role listed in SKILL.md missing: common-roles/{role}.md")

    # Validate references/ paths mentioned inline.
    for ref in set(re.findall(r"`(references/[^`]+)`", text)):
        ref_path = repo_root / ref
        if not ref_path.exists():
            errors.append(f"Referenced file not found: {ref}")

    if "delegate.how-to.md" in text and not (repo_root / "delegate.how-to.md").exists():
        errors.append("SKILL.md references delegate.how-to.md, but the file does not exist.")

    return errors


def main() -> int:
    repo_root = pathlib.Path(__file__).resolve().parents[1]
    result = subprocess.run(["agentskills", "validate", str(repo_root)])
    manual_errors = _manual_lint(repo_root)
    if manual_errors:
        print("Manual lint failures:", file=sys.stderr)
        for error in manual_errors:
            print(f"  - {error}", file=sys.stderr)
    return 1 if result.returncode != 0 or manual_errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
