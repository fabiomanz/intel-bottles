#!/usr/bin/env python3
"""Copy published bottle JSONs into manifest/, replacing older entries for the same formula.

The manifest is what sync_fork.sh replays onto upstream every night. A bottle that is
published but not recorded here has its block wiped by the next sync, and the following
build run rebuilds it from scratch. That went unnoticed for weeks: the workflow step that
recorded the manifest looked for bottles/*.bottle.json, but artifacts are downloaded
unmerged (one directory per job), so the glob matched nothing and the step silently did
nothing. Every daily run rebuilt the same ~90 formulae.

Only one entry per formula may exist. apply_manifest.py treats any entry whose version
trails upstream as a hold, so a leftover xz 5.8.3 next to xz 5.8.4 would pin the fork
back to 5.8.3.

usage: record_manifest.py <dir-with-published-jsons>
"""

import json
import shutil
import sys
from pathlib import Path

MANIFEST = Path(__file__).resolve().parent.parent / "manifest"


def formula_names(path: Path) -> set[str]:
    try:
        return {name.split("/")[-1] for name in json.loads(path.read_text())}
    except (OSError, json.JSONDecodeError):
        return set()


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    source = Path(sys.argv[1])
    published = sorted(source.glob("*.bottle.json"))
    if not published:
        print(f"no bottle JSONs in {source}, nothing to record")
        return

    MANIFEST.mkdir(exist_ok=True)
    existing = {path: formula_names(path) for path in MANIFEST.glob("*.bottle.json")}

    for json_path in published:
        names = formula_names(json_path)
        for old, old_names in list(existing.items()):
            if old.name != json_path.name and old_names & names:
                print(f"    replacing {old.name}")
                old.unlink()
                del existing[old]
        shutil.copy2(json_path, MANIFEST / json_path.name)
        existing[MANIFEST / json_path.name] = names
        print(f"==> recorded {json_path.name}")


if __name__ == "__main__":
    main()
