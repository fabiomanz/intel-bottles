#!/usr/bin/env python3
"""Plan how to rebuild the fork as: upstream, held back to what we have bottles for.

The fork is never hand-edited. It is hard-reset onto upstream and this plan is replayed,
so merge conflicts are structurally impossible.

VERSION HOLD: when upstream bumps a formula past the version we hold a bottle for, we do
NOT let that new version through. Doing so would leave the formula with no usable bottle
until CI catches up, and a `brew upgrade` in that window compiles it on the local machine
-- exactly what this project exists to avoid. Instead the formula file is restored to the
revision we bottled (recorded by `brew bottle --json` as tap_git_revision/tap_git_path)
and our bottle block is re-applied. The machine therefore only ever sees versions that
have a bottle, and picks up the new version a day later once CI has built one.

Emits a tab-separated plan on stdout:
    RESTORE <revision> <path> <name> <held_version> <upstream_version>
    APPLY   <json_path>
Restores must be applied before the APPLY merges.
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
            formula = payload.get("formula") or {}
            entries.append(
                {
                    "json": path,
                    "name": full_name.split("/")[-1],
                    "version": formula.get("pkg_version"),
                    "revision": formula.get("tap_git_revision"),
                    "path": formula.get("tap_git_path"),
                }
            )

    if not entries:
        print("manifest is empty", file=sys.stderr)
        return

    upstream = brewinfo.pkg_versions(sorted({e["name"] for e in entries}))

    current, held, dropped = [], [], []
    for entry in entries:
        now = upstream.get(entry["name"])
        if now is None:
            dropped.append((entry["name"], "no longer in homebrew-core"))
        elif now == entry["version"]:
            current.append(entry)
        elif entry["revision"] and entry["path"]:
            held.append((entry, now))
        else:
            dropped.append((entry["name"], "bottled before revisions were recorded"))

    for entry, now in held:
        print(
            "\t".join(
                [
                    "RESTORE",
                    entry["revision"],
                    entry["path"],
                    entry["name"],
                    entry["version"],
                    now,
                ]
            )
        )
    for entry in current + [e for e, _ in held]:
        print(f"APPLY\t{entry['json']}")

    print(
        f"\n{len(current)} at upstream version, {len(held)} held back, {len(dropped)} dropped",
        file=sys.stderr,
    )
    for entry, now in held:
        print(
            f"  hold: {entry['name']} stays at {entry['version']} (upstream {now}) "
            f"until CI bottles it",
            file=sys.stderr,
        )
    for name, why in dropped:
        print(f"  drop: {name} -- {why}", file=sys.stderr)


if __name__ == "__main__":
    main()
