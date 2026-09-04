#!/usr/bin/env python3
"""Print, in the order given, the formulae that have no bottle usable on this platform.

`brew info --json=v2` filters bottle.stable.files down to bottles this machine can
actually use (exact tag, an older-macOS fallback, or :all), so an empty dict means
"this would compile from source here" -- which is exactly what we want to bottle.
"""

import json
import subprocess
import sys


def chunked(seq, size):
    for i in range(0, len(seq), size):
        yield seq[i : i + size]


def main() -> None:
    names = [arg for arg in sys.argv[1:] if arg]
    if not names:
        return

    missing = set()
    for chunk in chunked(names, 100):
        proc = subprocess.run(
            ["brew", "info", "--json=v2", *chunk], capture_output=True, text=True
        )
        if proc.returncode != 0:
            sys.exit(f"brew info failed:\n{proc.stderr}")
        for formula in json.loads(proc.stdout)["formulae"]:
            files = ((formula.get("bottle") or {}).get("stable") or {}).get("files") or {}
            if not files:
                missing.add(formula["name"])

    # Preserve the caller's ordering -- it is topological and we must not disturb it.
    seen = set()
    for name in names:
        short = name.split("/")[-1]
        if short in missing and short not in seen:
            seen.add(short)
            print(short)


if __name__ == "__main__":
    main()
