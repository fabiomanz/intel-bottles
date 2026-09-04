#!/usr/bin/env python3
"""Split the bottle manifest into what still applies and what has gone stale.

The fork is rebuilt by hard-resetting onto upstream homebrew-core and then re-applying our
bottle blocks, so nothing is ever hand-edited and merge conflicts are impossible. A stored
bottle only applies while the formula's version is unchanged; once upstream bumps it, the
bottle is stale and that formula needs rebuilding.

Prints the paths of the applicable JSON files on stdout (feed them to
`brew bottle --merge --write --no-commit`), and reports the stale ones as the rebuild queue.
"""

import json
import sys
from pathlib import Path

import brewinfo

MANIFEST = Path(__file__).resolve().parent.parent / "manifest"


def main() -> None:
    entries = []
    for path in sorted(MANIFEST.glob("*.bottle.json")):
        try:
            data = json.loads(path.read_text())
        except json.JSONDecodeError:
            print(f"skipping unreadable {path.name}", file=sys.stderr)
            continue
        for full_name, payload in data.items():
            name = full_name.split("/")[-1]
            bottled = (payload.get("formula") or {}).get("pkg_version")
            entries.append((path, name, bottled))

    if not entries:
        print("manifest is empty", file=sys.stderr)
        return

    versions = brewinfo.pkg_versions(sorted({name for _, name, _ in entries}))

    applicable, stale = [], []
    for path, name, bottled in entries:
        upstream = versions.get(name)
        if upstream is None:
            stale.append((name, bottled, "no longer in homebrew-core"))
        elif upstream == bottled:
            applicable.append(path)
        else:
            stale.append((name, bottled, f"upstream is now {upstream}"))

    for path in sorted(set(applicable)):
        print(path)

    print(
        f"\n{len(set(applicable))} bottle block(s) still apply, {len(stale)} stale",
        file=sys.stderr,
    )
    for name, bottled, why in stale:
        print(f"  stale: {name} (bottled {bottled}) -- {why}", file=sys.stderr)


if __name__ == "__main__":
    main()
