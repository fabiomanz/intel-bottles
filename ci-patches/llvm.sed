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
