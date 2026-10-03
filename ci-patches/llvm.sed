# Applied by build_root.sh to the build runner's copy of llvm.rb, never to the fork.
#
# When bottling, llvm builds itself four times: a stage-1 clang, an instrumented stage-2
# clang, a training build of LLVM with it to collect a PGO profile, then the real build
# with that profile and ThinLTO. On a 4-core macos-26-intel runner that does not fit in
# GitHub's 6-hour job limit (cut off at 350 minutes twice, still in the third build).
# llvm@22 has no PGO step, builds the same projects once, and takes 3-4 hours.
#
# Turning PGO off gives one plain build like llvm@22. The bottle has the same contents;
# clang and libLLVM are just not profile-optimized, so they run somewhat slower.
s/^([[:space:]]*pgo_build = ).*/\1false # intel-bottles: PGO bootstrap exceeds GitHub's 6-hour job limit/

# One of llvm's patches is a GitHub compare URL, which GitHub renders on the fly. Around
# 2026-10-02 it started abbreviating the `index` hashes to 15 characters instead of 13
# (and inconsistently between servers), so the download no longer matches the sha256
# the formula pins -- every source build of llvm fails at fetch. The patch content is
# unchanged. files/llvm-1381ad4-40a8c7c.diff is the original download, byte for byte;
# brew still checks it against upstream's sha256 (f6dafd76...). Drop this line once
# upstream changes the URL or checksum -- it then simply matches nothing.
s|https://github\.com/llvm/llvm-project/compare/1381ad497b9a6d3da630cbef53cbfa9ddf117bb6\.\.\.40a8c7c0ff3f688b690e4c74db734de67f0f89e9\.diff|https://raw.githubusercontent.com/fabiomanz/intel-bottles/main/ci-patches/files/llvm-1381ad4-40a8c7c.diff|
