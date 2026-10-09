# Applied by build_root.sh to the build runner's copy of qtwebengine.rb, never to the fork.
#
# qtwebengine is Chromium, one build that takes longer than GitHub's 6-hour job limit on
# 4 cores (cut off at 5h50m). Unlike llvm there is no optional step to drop, so the build
# is made resumable instead: every compile goes through ccache, the build step stops
# before the job limit, and the workflow saves the cache (see ccache.txt). The next run
# restores it and only compiles what is still missing.
#
# Qt passes CMAKE_CXX_COMPILER_LAUNCHER on to Chromium's GN as cc_wrapper
# (cmake/QtToolchainHelpers.cmake). Homebrew filters the environment, so ccache is
# configured from inside the formula. The directory is under HOMEBREW_CACHE, which the
# build sandbox may write to. BASEDIR makes hits independent of the random build dir;
# the compiler check hashes `clang --version`, since the superenv shim changes with
# every Homebrew update.
#
# Precompiled headers are deliberately NOT cached (no `pch_defines` in the sloppiness).
# A .gch embeds the absolute paths of the build that created it, and Homebrew builds in
# a new random directory every run. With PCH caching on, the Oct 6-8 runs restored a
# precompile_platform.h-cc.gch from the Oct 5 directory and failed with "malformed or
# corrupted precompiled file". Without it ccache runs the compiler for anything that
# creates or uses a PCH and caches everything else as before.
s|^  def install$|  def install; ENV["CCACHE_DIR"] = "#{HOMEBREW_CACHE}/ccache"; ENV["CCACHE_BASEDIR"] = HOMEBREW_TEMP.realpath.to_s; ENV["CCACHE_NOHASHDIR"] = "1"; ENV["CCACHE_COMPILERCHECK"] = "%compiler% --version"; ENV["CCACHE_SLOPPINESS"] = "time_macros,include_file_mtime,include_file_ctime"; ENV["CCACHE_MAXSIZE"] = "6G" # intel-bottles: resumable build|
s|^([[:space:]]*-DFEATURE_webengine_kerberos=ON)$|\1 -DCMAKE_C_COMPILER_LAUNCHER=#{HOMEBREW_PREFIX}/bin/ccache -DCMAKE_CXX_COMPILER_LAUNCHER=#{HOMEBREW_PREFIX}/bin/ccache|
