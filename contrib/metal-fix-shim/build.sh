#!/bin/bash
# Build the combined WhateverXe Metal shim.
#
# The driver bundle loads @loader_path/impostor.dylib in every Metal process.
# We replace it with our dylib, which re-exports the original renamed to
# impostor-real.dylib.  Output: ./impostor.dylib (ad-hoc signed).
#
# Two translation units:
#   wexshim.mm        ARC  - #36 stencil view + #47 POSH buffer leak
#   wexv16v17fix.mm   MRC  - NG v16 blit ordering + NG v17 Stencil8 64 KB
# The v16/v17 TU is MRC because its "new"-family IMP indirection and temp-buffer
# pool must be manually retained (ARC over-releases the v17 path).
#
# Requires the installed WhateverXe Graphics bundle.
set -euo pipefail
cd "$(dirname "$0")"

B=/Library/GPUBundles/AppleIntelTGLGraphicsMTLDriver.bundle
M=$B/Contents/MacOS
REAL=$M/impostor-real.dylib
[ -f "$REAL" ] || REAL=$M/impostor.dylib
[ -f "$REAL" ] || { echo "missing $REAL (is WhateverXe Graphics installed?)"; exit 1; }

rm -rf build && mkdir -p build
cp "$REAL" build/impostor-real.dylib
install_name_tool -id @loader_path/impostor-real.dylib build/impostor-real.dylib 2>/dev/null || true

# compile the two TUs with their own memory-management flavour
xcrun clang++ -std=c++17 -fobjc-arc  -O2 -Wall -arch x86_64 -c wexshim.mm     -o build/wexshim.o
xcrun clang++ -std=c++17 -fno-objc-arc -O2 -Wall -arch x86_64 -c wexv16v17fix.mm -o build/wexv16v17fix.o

# link into the impostor dylib, re-exporting the original
xcrun clang++ -arch x86_64 -dynamiclib -mmacosx-version-min=13.0 \
  -install_name @rpath/impostor.dylib \
  -framework Foundation -framework Metal \
  -Wl,-reexport_library,build/impostor-real.dylib \
  build/wexshim.o build/wexv16v17fix.o -o build/impostor.dylib

codesign -f -s - build/impostor.dylib
cp build/impostor.dylib ./impostor.dylib

echo "built ./impostor.dylib"
echo -n "sha256: "; shasum -a 256 ./impostor.dylib | awk '{print $1}'
echo "reexports:"; otool -L ./impostor.dylib | grep -E 'impostor-real|Foundation|Metal' | sed 's/^/  /'