#!/usr/bin/env python3
"""Decide which formulae still need an Intel bottle, and group them into root build targets.

A "root" is a formula that no other unbottled target depends on. Building a root with
`brew install --build-bottle` builds its whole dependency chain into one Cellar in the
right order, so bottling everything the job built covers the dependencies for free --
no wave orchestration needed.

Heavy formulae (expensive, widely shared -- qtbase, qtwebengine, llvm ...) are forced to
be roots and built in an earlier stage, so the later stage pours them instead of
rebuilding them in every job that needs them.

Writes GitHub Actions outputs when $GITHUB_OUTPUT is set; otherwise prints a summary.
"""

import json
import os
import subprocess
import sys
from pathlib import Path

import brewinfo

REPO = Path(__file__).resolve().parent.parent
# A formula this many unbottled formulae depend on is worth building first, on its own.
SHARED_DEP_THRESHOLD = 5


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
    """Formulae Homebrew would compile from source on this platform.

    Asks brew directly (Formula#bottled?) rather than inspecting bottle.stable.files --
    see brewinfo.py for why that field is unusable under HOMEBREW_NO_INSTALL_FROM_API.
    """
    needs, _bottled, missing = brewinfo.classify(targets)
    if missing:
        print(
            f"note: no longer in homebrew-core: {', '.join(sorted(missing))}",
            file=sys.stderr,
        )
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
        deps[name] = {
            d.split("/")[-1] for d in rest.split() if d.split("/")[-1] in interesting
        }
    return deps


def main() -> None:
    targets = read_list(REPO / "targets.txt")
    if not targets:
        sys.exit("targets.txt is empty -- nothing to plan")

    missing = unbottled(targets)
    if not missing:
        emit([], [], missing, [])
        return

    deps = dependency_map(missing)

    # Anything that is a dependency of another unbottled target gets built for free.
    covered: set[str] = set()
    for children in deps.values():
        covered |= children

    # Widely shared dependencies are worth their own job in the first stage.
    dependent_count: dict[str, int] = {}
    for children in deps.values():
        for child in children:
            dependent_count[child] = dependent_count.get(child, 0) + 1

    heavy = set(read_list(REPO / "heavy.txt")) & set(missing)
    heavy |= {
        name
        for name, count in dependent_count.items()
        if count >= SHARED_DEP_THRESHOLD
    }

    roots = [f for f in missing if f not in covered or f in heavy]
    heavy_roots = sorted(f for f in roots if f in heavy)
    rest_roots = sorted(f for f in roots if f not in heavy)

    emit(heavy_roots, rest_roots, missing, sorted(covered - set(roots)))


def emit(heavy, rest, missing, free):
    summary = (
        f"{len(missing)} formulae still need a bottle\n"
        f"  stage 1 (shared/heavy): {len(heavy)} -> {', '.join(heavy) or '-'}\n"
        f"  stage 2 (roots):        {len(rest)} -> {', '.join(rest) or '-'}\n"
        f"  built as dependencies:  {len(free)}\n"
    )
    print(summary)

    github_output = os.environ.get("GITHUB_OUTPUT")
    if github_output:
        with open(github_output, "a") as fh:
            fh.write(f"heavy={json.dumps(heavy)}\n")
            fh.write(f"rest={json.dumps(rest)}\n")
            fh.write(f"missing_count={len(missing)}\n")
    step_summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if step_summary:
        with open(step_summary, "a") as fh:
            fh.write(f"## Bottle plan\n\n```\n{summary}```\n")


if __name__ == "__main__":
    main()
