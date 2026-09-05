# intel-bottles

Prebuilt Homebrew **bottles for Intel (x86_64) macOS**, built on GitHub Actions and consumed
through a fork of `homebrew-core`.

## Why

Homebrew moved Intel macOS to **Tier 3 in September 2026**: no CI, no new bottles. Support is
removed entirely in September 2027. The newest Intel bottles upstream are tagged `sonoma`
(macOS 14), so on macOS 26 every formula that has had a version bump since then compiles from
source — 72 of 368 installed formulae on the machine this was built for.

MacPorts cannot fill the gap either: its Tahoe x86_64 builder does not exist
([#73230](https://trac.macports.org/ticket/73230) — their build host can't run Tahoe natively).
Nix drops `x86_64-darwin` binaries at the end of 2026.

But GitHub still offers **`macos-26-intel`**, a GA standard runner (4 cores, 14 GB RAM, and in
practice ~160 GB free disk -- the 14 GB in GitHub's docs is not what the runner actually has),
free and unmetered on public repos, **until August 2027**. Homebrew dropped Intel over
maintainer burden, not hardware availability. So we build our own.

Bottles built there are tagged `tahoe` — an exact match for macOS 26 Intel.

## How it works

```
  plan            reads targets.txt, asks brew which formulae have no usable
   │              bottle, groups them into root build targets
   ├─ stage 1     shared + expensive roots (qtbase, openssl@3, qtwebengine, gcc …)
   │              built, bottled, published
   └─ stage 2     everything else — pours stage 1's output instead of rebuilding it
```

**Why roots, not one job per formula.** `brew install --build-bottle X` does *not* propagate
`--build-bottle` to X's dependencies — `install_dependency` in `formula_installer.rb` builds
its `FormulaInstaller` without it, so `brew bottle` would refuse them with *"Formula was not
installed with `--build-bottle`"*. So each job walks its root's chain in topological order
(`brew deps -n --include-build`) and explicitly builds only what still needs a bottle. One job
covers a whole subtree, and 72 formulae collapse to ~37 jobs.

**Why two stages.** Within a job the Cellar is shared, but across matrix jobs it is not.
Publishing the widely-shared roots first means stage 2 pours them. The planner auto-promotes
anything ≥5 other unbottled formulae depend on, so `qtbase` lands in stage 1 without being
listed anywhere.

**Consumption.** Bottle tarballs go to a rolling GitHub Release; `brew bottle --merge --write`
writes the matching `bottle do` blocks into a fork of `homebrew-core`, which the Mac points at
via `HOMEBREW_CORE_GIT_REMOTE`. Unqualified `brew install node` then just works, and no
`brew trust` is needed — brew still sees this as `homebrew/core`.

## Layout

| Path | Role |
|---|---|
| `targets.txt` | Formulae to keep bottled (all installed core formulae) |
| `heavy.txt` | Forced into stage 1: expensive or risky |
| `scripts/plan_targets.py` | Picks what needs building, splits into stages |
| `scripts/filter_unbottled.py` | Order-preserving "which of these lack a bottle here" |
| `scripts/build_root.sh` | Builds + bottles one root and its unbottled chain |
| `scripts/publish.sh` | Merges DSL into the fork, uploads release assets |
| `scripts/apply_manifest.py` | Splits the manifest into still-valid vs stale |
| `scripts/sync_fork.sh` | Rebuilds the fork as upstream + our blocks |
| `manifest/` | `*.bottle.json` — the source of truth for re-applying blocks |

## Runner assignment

`runners.json` decides which machine builds which formula. Everything uses the free
GitHub-hosted `macos-26-intel` unless listed under `assign`. Today only `qtwebengine` is
assigned elsewhere, because it cannot finish inside GitHub's hard 6-hour job ceiling.

```json
"assign": { "qtwebengine": "selfhosted" }
```

Moving a formula between runners is a one-line edit there; nothing else needs changing.

### Self-hosted runner

Register an Intel Mac with the labels `self-hosted, macOS, X64` (Settings -> Actions ->
Runners). The `selfhosted` profile gives it a 48-hour timeout, since self-hosted jobs are
not bound by the 6-hour limit.

**Security note:** GitHub advises against self-hosted runners on public repositories,
because a fork's pull request could otherwise run arbitrary code on your machine. That
attack does not apply here — no workflow in this repo has a `pull_request` trigger; they
are all `workflow_dispatch`, `schedule` or `workflow_call`. Keep it that way, or move the
repo private (which costs runner minutes for the GitHub-hosted jobs).

## Setup

1. **Fork homebrew-core** to `fabiomanz/homebrew-core` (keep the default branch `main`).
2. **Create this repo** as `fabiomanz/intel-bottles`, **public** — standard runners are only
   free on public repos.
3. **Add a secret `FORK_TOKEN`**: a fine-grained PAT with `contents: write` on
   `fabiomanz/homebrew-core`. Used to push rebuilt bottle blocks.
4. Run the **build bottles** workflow. First run is the expensive one; later runs only pick up
   what upstream has bumped.

## Client setup (the Intel Mac)

```sh
export HOMEBREW_NO_INSTALL_FROM_API=1
export HOMEBREW_CORE_GIT_REMOTE=https://github.com/fabiomanz/homebrew-core
brew update
```

Trade-off: this swaps the fast JSON API for a full local `homebrew-core` git checkout, so
`brew update` and `brew search` get slower.

### Verify

```sh
brew info --json=v2 tmux | jq '.formulae[0].bottle.stable.files'   # expect a "tahoe" entry
brew reinstall tmux 2>&1 | grep -E 'Pouring|Building'             # expect "Pouring"
jq .poured_from_bottle /usr/local/Cellar/tmux/*/INSTALL_RECEIPT.json
```

## Known limits

- **`qtwebengine` does not fit in a GitHub job.** Measured, not predicted: it ran **5h50m**
  before hitting `timeout-minutes: 350`, and GitHub's hard job ceiling is 6 hours, so there
  was no headroom to give it. Disk was never the problem (~160 GB free throughout) — it is
  purely CPU time on 4 cores, and a single Chromium build cannot be split across jobs. It is
  pinned to stage 1 with `allow_failure: true` so it cannot take the run down. `qt`, `pyside`
  and `qtwebview` depend on it and stay unbottled with it. The only real options are a larger
  runner (more cores; billed even on public repos) or a self-hosted Intel runner.
- **One `root_url` per bottle block.** Merging our `tahoe` bottle into a formula that still has
  upstream's `sonoma` bottle rewrites the block's single `root_url` to ours. Harmless here —
  an exact tag match wins, so macOS 26 Intel always picks `tahoe` — but that block's older tags
  would not resolve on an older machine.
- **Three formulae are out of scope**, being outside `homebrew-core`: `packer` (hashicorp/tap),
  `ttab` (mklement0/ttab), and `valgrind` (a `HEAD` build, which cannot be bottled at all).
- **August 2027**: `macos-15-intel` and `macos-26-intel` are the last x86_64 images GitHub will
  offer. After that this pipeline needs a self-hosted Intel runner.
