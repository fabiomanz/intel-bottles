#!/usr/bin/env python3
"""Print, in the order given, the formulae that still need a bottle on this platform.

Order matters: callers pass a topologically sorted chain and build in the order printed.
Formulae upstream has retired are reported and dropped -- they cannot be built anyway.
"""

import sys

import brewinfo


def main() -> None:
    names = [arg for arg in sys.argv[1:] if arg]
    if not names:
        return

    needs, _bottled, missing = brewinfo.classify(names)
    if missing:
        print(f"note: skipping, not in homebrew-core: {', '.join(missing)}", file=sys.stderr)

    needed = set(needs)
    seen = set()
    for name in names:
        short = name.split("/")[-1]
        if short in needed and short not in seen:
            seen.add(short)
            print(short)


if __name__ == "__main__":
    main()
