#!/usr/bin/env python3
"""Remove staged bottles that should not be published (again).

Each publish job downloads every bottle artifact of the run so far, not only its own
stage's. That is what lets a run recover from a lost publish: on 2026-09-30 GitHub failed
to acquire a runner for "publish wave0" five times, nothing from wave 0 was released, and
every later job rebuilt those formulae from source. With the sweep, the next stage's
publish picks them up.

The sweep must not republish what an earlier stage already released, so a staged
(json, tarball) pair is kept only when the fork, as it stands now:
  - still has no usable bottle for that formula, and
  - defines the same version the bottle was built from. A sync that moved the formula
    on mid-run would otherwise get a block for a tarball that its URL no longer names.

usage: drop_published.py <staging-dir>
"""

import json
import sys
from pathlib import Path

import brewinfo


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    staging = Path(sys.argv[1])

    pairs = {}
    for json_path in sorted(staging.glob("*.bottle.json")):
        data = json.loads(json_path.read_text())
        full_name, payload = next(iter(data.items()))
        pairs[json_path] = (full_name.split("/")[-1], payload["formula"]["pkg_version"])
    if not pairs:
        return

    names = sorted({name for name, _ in pairs.values()})
    needs, _bottled, _missing = brewinfo.classify(names)
    needs = set(needs)
    current = brewinfo.pkg_versions(names)

    for json_path, (name, version) in pairs.items():
        if name not in needs:
            reason = "already bottled in the fork"
        elif current.get(name) != version:
            reason = f"fork is now at {current.get(name)}"
        else:
            continue
        print(f"==> {name} {version}: {reason}, not publishing")
        json_path.unlink()
        json_path.with_suffix(".tar.gz").unlink(missing_ok=True)


if __name__ == "__main__":
    main()
