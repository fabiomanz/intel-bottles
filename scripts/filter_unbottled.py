#!/usr/bin/env python3
"""Print, in the order given, the formulae that have no bottle usable on this platform.

Order matters: callers pass a topologically sorted chain and build in the order printed.
Formulae upstream has retired are silently dropped -- they cannot be built anyway.
"""

import sys

import brewinfo


def main() -> None:
    names = [arg for arg in sys.argv[1:] if arg]
    if not names:
        return

    formulae, gone = brewinfo.info(names)
    if gone:
        print(f"note: skipping, not in homebrew-core: {', '.join(gone)}", file=sys.stderr)

    needs_bottle = {
        formula["name"] for formula in formulae if not brewinfo.has_usable_bottle(formula)
    }

    seen = set()
    for name in names:
        short = name.split("/")[-1]
        if short in needs_bottle and short not in seen:
            seen.add(short)
            print(short)


if __name__ == "__main__":
    main()
