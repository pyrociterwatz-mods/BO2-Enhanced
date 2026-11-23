#!/bin/sh
# Builds the sound engine, sound/build/backend/dinput.dll (FMOD 3 replaced by miniaudio inside the running game).
# Run from Git Bash: sh sound/build.sh        CC: a 32-bit Windows clang (llvm-mingw), default i686-w64-mingw32-clang
set -e
P="$(cd "$(dirname "$0")" && pwd)"
CC="${CC:-i686-w64-mingw32-clang}"
FLAGS="-O2 -Wall -Wno-unused-function -msse2 -mfpmath=sse -shared -static -static-libgcc"
mkdir -p "$P/build/backend" "$P/build/obj"
"$CC" -O2 -msse2 -mfpmath=sse -c -o "$P/build/obj/ma_impl.o" "$P/src/ma_impl.c"
"$CC" $FLAGS -o "$P/build/backend/dinput.dll" \
  "$P/src/dllmain.c" "$P/src/backend.c" "$P/src/hook.c" "$P/src/log.c" "$P/build/obj/ma_impl.o" "$P/src/dinput.def" \
  -Wl,--enable-stdcall-fixup -lshell32 -lkernel32 -lole32
ls -la "$P/build/backend/dinput.dll"
