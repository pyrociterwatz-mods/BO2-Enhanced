#!/bin/sh
# Builds ui-dll/bo2skipui.dll (32-bit) with the llvm-mingw toolchain kept in the audio project. Run from Git Bash:
#   sh ui-dll/build.sh
set -e
P="$(cd "$(dirname "$0")" && pwd)"
# CC: a 32-bit Windows clang/gcc (llvm-mingw); by default the one kept in the audio project next to this one.
CC="${CC:-$P/../../bo2-audio-replacement/tools/llvm-mingw/bin/i686-w64-mingw32-clang.exe}"
# The version resource (product name, description, version) is compiled with the windres next to CC.
case "$CC" in */*) WR_DEFAULT="$(dirname "$CC")/i686-w64-mingw32-windres" ;; *) WR_DEFAULT="i686-w64-mingw32-windres" ;; esac
WINDRES="${WINDRES:-$WR_DEFAULT}"
mkdir -p "$P/build"
"$WINDRES" -O coff -i "$P/version.rc" -o "$P/build/version.o"
"$CC" -O2 -Wall -Wextra -Wno-unused-parameter -msse2 -mfpmath=sse -shared -static -static-libgcc -s \
  -o "$P/build/bo2skipui.dll" "$P/bo2skipui.c" "$P/build/version.o" -lkernel32
ls -la "$P/build/bo2skipui.dll"
