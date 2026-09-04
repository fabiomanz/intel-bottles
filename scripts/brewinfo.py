"""Shared `brew info --json=v2` helper that tolerates formulae upstream has removed.

`brew info` fails the ENTIRE invocation if any one name is unknown, so a single retired
formula (openssl@1.1, say) would otherwise take down a batch of 100. Formulae get retired
from homebrew-core steadily, so this has to degrade gracefully rather than abort: on
failure the batch is bisected until the unknown names are isolated and reported.
"""

import json
import subprocess

CHUNK = 100


def _chunk(names, size):
    for i in range(0, len(names), size):
        yield names[i : i + size]


def _query(names: list[str]) -> tuple[list[dict], list[str]]:
    proc = subprocess.run(
        ["brew", "info", "--json=v2", *names], capture_output=True, text=True
    )
    if proc.returncode == 0:
        return json.loads(proc.stdout)["formulae"], []
    if len(names) == 1:
        return [], names
    mid = len(names) // 2
    left, left_missing = _query(names[:mid])
    right, right_missing = _query(names[mid:])
    return left + right, left_missing + right_missing


def info(names: list[str]) -> tuple[list[dict], list[str]]:
    """Return (formulae, unknown_names). Unknown names are no longer in homebrew-core."""
    formulae: list[dict] = []
    missing: list[str] = []
    for batch in _chunk(list(names), CHUNK):
        found, gone = _query(batch)
        formulae.extend(found)
        missing.extend(gone)
    return formulae, missing


def has_usable_bottle(formula: dict) -> bool:
    """True if brew could pour this formula here.

    `brew info --json=v2` filters bottle.stable.files to what this machine can actually
    use -- exact tag, an older-macOS fallback, or :all -- so an empty dict means it would
    compile from source.
    """
    files = ((formula.get("bottle") or {}).get("stable") or {}).get("files") or {}
    return bool(files)
