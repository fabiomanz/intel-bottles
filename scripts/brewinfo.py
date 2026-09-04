"""Ask Homebrew itself which formulae need bottles.

Do NOT infer this from `brew info --json=v2`'s bottle.stable.files. That field comes from
Formula#bottle_hash, which iterates EVERY tag in the bottle block (formula.rb: each_tag).
It only looks platform-filtered when formulae are loaded from the JSON API, because the API
loader pre-filters to usable tags. Under HOMEBREW_NO_INSTALL_FROM_API=1 -- which is exactly
how CI runs, since it needs the fork as a real git checkout -- every formula comes back with
a full tag list and therefore looks bottled. That silently reduced the whole pipeline to a
no-op.

Formula#bottled? is the authoritative check: it goes through bottle_specification.tag? ->
find_matching_tag, which includes the macOS older-version fallback, and it behaves the same
whether formulae came from the API or from a tap checkout.

Formula names are passed via HOMEBREW_FORMULAE because brew strips non-HOMEBREW_* variables
from the environment it hands to `brew ruby`.
"""

import os
import subprocess

_RUBY = """
ENV["HOMEBREW_FORMULAE"].to_s.split.each do |name|
  begin
    formula = Formula[name]
    puts "#{name}\\t#{formula.bottled? ? "bottled" : "needs"}\\t#{formula.pkg_version}"
  rescue StandardError
    puts "#{name}\\tmissing\\t"
  end
end
"""


def _run(names: list[str]) -> list[tuple[str, str, str]]:
    if not names:
        return []
    env = dict(os.environ)
    env["HOMEBREW_FORMULAE"] = " ".join(names)
    env["HOMEBREW_DEVELOPER"] = "1"
    proc = subprocess.run(
        ["brew", "ruby", "-e", _RUBY], capture_output=True, text=True, env=env
    )
    if proc.returncode != 0:
        raise RuntimeError(f"brew ruby failed:\n{proc.stderr}")

    rows = []
    for line in proc.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) == 3:
            rows.append((parts[0], parts[1], parts[2]))
    return rows


def classify(names: list[str]) -> tuple[list[str], list[str], list[str]]:
    """Return (needs_bottle, bottled, missing), preserving the given order."""
    status = {name: state for name, state, _ in _run(names)}
    needs, bottled, missing = [], [], []
    for name in names:
        short = name.split("/")[-1]
        state = status.get(short) or status.get(name)
        if state == "needs":
            needs.append(short)
        elif state == "bottled":
            bottled.append(short)
        else:
            missing.append(short)
    return needs, bottled, missing


def pkg_versions(names: list[str]) -> dict[str, str]:
    """formula -> pkg_version (version plus _revision), as currently defined."""
    return {
        name: version for name, state, version in _run(names) if state != "missing"
    }
