#!/usr/bin/env python3
"""Decide which formulae need bottles and schedule them by dependency level.

Ordering is the whole point. In an earlier design every unbottled formula was built
concurrently, so six qt* jobs each spent ~70 minutes rebuilding qtbase from source before
touching their own (tiny) build -- qtquicktimeline took 97 minutes, qtbase itself took 83.
Publishing qtbase first means those jobs pour it instead.

So formulae are grouped into waves by dependency depth: wave 0 is everything with no
unbottled dependency, wave 1 is everything whose unbottled dependencies are all in wave 0,
and so on. Each wave publishes before the next starts, so every job builds exactly one
formula and pours the rest.

Emits wave0..waveN as GitHub Actions outputs, each a JSON array of matrix entries.
"""

import json
import os
import subprocess
import sys
from pathlib import Path

import brewinfo

REPO = Path(__file__).resolve().parent.parent
MAX_WAVES = 5  # anything deeper folds into the last wave and rebuilds its own deps


def brew(*args: str) -> str:
    proc = subprocess.run(["brew", *args], capture_output=True, text=True)
    if proc.returncode != 0:
        sys.exit(f"brew {' '.join(args)} failed:\n{proc.stderr}")
    return proc.stdout


def read_list(path: Path) -> list[str]:
    if not path.exists():
        return []
    return [
        line.strip()
        for line in path.read_text().splitlines()
        if line.strip() and not line.startswith("#")
    ]


def unbottled(targets: list[str]) -> list[str]:
    """Formulae Homebrew would compile from source here.

    Asks brew directly (Formula#bottled?); see brewinfo.py for why bottle.stable.files
    cannot be used under HOMEBREW_NO_INSTALL_FROM_API.
    """
    needs, _bottled, missing = brewinfo.classify(targets)
    if missing:
        print(f"note: no longer in homebrew-core: {', '.join(sorted(missing))}", file=sys.stderr)
    return needs


def dependency_map(formulae: list[str]) -> dict[str, set[str]]:
    """formula -> its dependencies, restricted to the set we care about."""
    if not formulae:
        return {}
    out = brew("deps", "--include-build", "--full-name", "--for-each", *formulae)
    interesting = set(formulae)
    deps: dict[str, set[str]] = {}
    for line in out.splitlines():
        if ":" not in line:
            continue
        name, _, rest = line.partition(":")
        name = name.strip().split("/")[-1]
        if name not in interesting:
            continue
        deps[name] = {d.split("/")[-1] for d in rest.split() if d.split("/")[-1] in interesting}
    return deps


def runner_for(name: str) -> dict:
    """Matrix entry for a formula: which runner builds it, and its timeout."""
    config = json.loads((REPO / "runners.json").read_text())
    profile_name = config.get("assign", {}).get(name, "default")
    profile = config["profiles"][profile_name]
    return {
        "formula": name,
        "labels": profile["labels"],
        "timeout": profile["timeout"],
        "profile": profile_name,
    }


def levels(deps: dict[str, set[str]]) -> dict[str, int]:
    """Dependency depth per formula. Cycles, if any, land in the final wave."""
    level: dict[str, int] = {}
    remaining = dict(deps)
    while remaining:
        ready = [n for n, children in remaining.items() if all(c in level for c in children)]
        if not ready:  # cycle -- schedule the rest last and let them build their own deps
            for n in remaining:
                level[n] = MAX_WAVES - 1
            break
        for n in ready:
            level[n] = min(
                max([level[c] for c in remaining[n]] + [-1]) + 1, MAX_WAVES - 1
            )
        for n in ready:
            remaining.pop(n)
    return level


def main() -> None:
    targets = read_list(REPO / "targets.txt")
    if not targets:
        sys.exit("targets.txt is empty -- nothing to plan")

    missing = unbottled(targets)
    if not missing:
        emit({}, [])
        return

    deps = dependency_map(missing)

    excluded = set(read_list(REPO / "exclude.txt"))
    if excluded:
        blocked = {n for n, c in deps.items() if c & excluded} | (excluded & set(missing))
        if blocked:
            print(f"note: excluded from building: {', '.join(sorted(blocked))}", file=sys.stderr)
        missing = [m for m in missing if m not in blocked]
        deps = {k: v - blocked for k, v in deps.items() if k not in blocked}

    depth = levels(deps)
    waves: dict[int, list[str]] = {}
    for name in missing:
        waves.setdefault(depth.get(name, 0), []).append(name)

    emit(waves, missing)


def emit(waves: dict[int, list[str]], missing: list[str]) -> None:
    lines = [f"{len(missing)} formulae need a bottle, in {len(waves)} wave(s)"]
    for index in range(MAX_WAVES):
        names = sorted(waves.get(index, []))
        if names:
            shown = ", ".join(names[:8]) + (" …" if len(names) > 8 else "")
            lines.append(f"  wave {index} ({len(names):2d}): {shown}")
    summary = "\n".join(lines) + "\n"
    print(summary)

    github_output = os.environ.get("GITHUB_OUTPUT")
    if github_output:
        with open(github_output, "a") as fh:
            for index in range(MAX_WAVES):
                entries = [runner_for(n) for n in sorted(waves.get(index, []))]
                fh.write(f"wave{index}={json.dumps(entries)}\n")
            fh.write(f"missing_count={len(missing)}\n")
    step_summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if step_summary:
        with open(step_summary, "a") as fh:
            fh.write(f"## Bottle plan\n\n```\n{summary}```\n")


if __name__ == "__main__":
    main()
