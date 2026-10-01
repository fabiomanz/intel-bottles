#!/usr/bin/env python3
"""Before publish.sh commits to the fork: keep only the upstream swaps that got a bottle.

release_holds.sh replaced every held formula with upstream's newer version in the working
tree. For the ones this publish released, that newer file (now carrying our bottle block)
is exactly what the fork should get, and they are no longer held. Every other swapped file
is reverted, so the fork still never offers a version it has no bottle for.

usage: settle_holds.py <staging-dir> <core-repo>
"""

import json
import subprocess
import sys
from pathlib import Path

HOLDS_NAME = ".intel-bottles-holds"


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    staging, core = Path(sys.argv[1]), Path(sys.argv[2])
    holds = core / HOLDS_NAME
    if not holds.exists():
        return

    published = set()
    for path in staging.glob("*.bottle.json"):
        published |= {name.split("/")[-1] for name in json.loads(path.read_text())}

    kept_lines = []
    for line in holds.read_text().splitlines():
        fields = line.split("\t")
        if line.startswith("#") or len(fields) < 2:
            kept_lines.append(line)
            continue
        name, formula_path = fields[0], fields[1]
        if name in published:
            print(f"    {name}: released from hold at {fields[-1]}")
            continue
        kept_lines.append(line)
        subprocess.run(
            ["git", "-C", str(core), "checkout", "--", formula_path],
            check=False,
            stderr=subprocess.DEVNULL,
        )
    holds.write_text("\n".join(kept_lines) + "\n")


if __name__ == "__main__":
    main()
