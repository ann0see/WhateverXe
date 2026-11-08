#!/bin/bash
# Install / remove the combined WhateverXe Metal shim.
#
#   sudo bash install.sh              install or update (apps launched afterwards)
#   sudo bash install.sh remove       restore the original impostor.dylib
#   sudo bash install.sh mode stencil copy|noopt|both|off
#   sudo bash install.sh mode posh safe|aggressive|off
#   sudo bash install.sh status
#   bash install.sh log               last 15 minutes of shim log
#
# The shim skips /System and /usr processes, so WindowServer is untouched.
# Fix the WindowServer side with ../leakfix/wex-posh-patch.sh instead.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
B=/Library/GPUBundles/AppleIntelTGLGraphicsMTLDriver.bundle
M=$B/Contents/MacOS
HERE=$(cd "$(dirname "$0")" && pwd)
CFG="/Library/Application Support/WEXMetalFixes"

case "${1:-}" in
  log)
    log show --last 15m --style compact --predicate 'subsystem == "org.wex.metalfixes"' | tail -60
    exit 0 ;;
  status)
    echo "bundle:  $B"
    echo -n "driver:  "; shasum -a 256 "$M/AppleIntelTGLGraphicsMTLDriver" | awk '{print $1}'
    echo -n "shim:    "; [ -f "$M/impostor-real.dylib" ] && echo "installed ($(shasum -a 256 "$M/impostor.dylib" | awk '{print $1}'))" || echo "not installed"
    echo "config:  stencil=$(cat "$CFG/stencil" 2>/dev/null || echo copy) posh=$(cat "$CFG/posh" 2>/dev/null || echo aggressive) v16=$(cat "$CFG/v16" 2>/dev/null || echo on) v17=$(cat "$CFG/v17" 2>/dev/null || echo on)"
    exit 0 ;;
esac

[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
[ -f "$M/AppleIntelTGLGraphicsMTLDriver" ] || { echo "WhateverXe Graphics Metal driver not found in $B"; exit 1; }

case "${1:-}" in
  mode)
    case "${2:-}" in
      stencil) case "${3:-}" in copy|noopt|both|off) f=stencil ;; *) echo "stencil: copy|noopt|both|off"; exit 1 ;; esac ;;
      posh)    case "${3:-}" in aggressive|safe|off)      f=posh    ;; *) echo "posh: aggressive|safe|off"; exit 1 ;; esac ;;
      v16)     case "${3:-}" in on|off)                   f=v16     ;; *) echo "v16: on|off"; exit 1 ;; esac ;;
      v17)     case "${3:-}" in on|off)                   f=v17     ;; *) echo "v17: on|off"; exit 1 ;; esac ;;
      *) echo "mode stencil|posh|v16|v17 <value>"; exit 1 ;;
    esac
    mkdir -p "$CFG"; echo "$3" > "$CFG/$f"; echo "$f=$3 (relaunch the app)"; exit 0 ;;
  remove)
    [ -f "$M/impostor-real.dylib" ] || { echo "not installed"; exit 1; }
    cp -p "$M/impostor.dylib" "$HERE/impostor.removed.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
    mv -f "$M/impostor-real.dylib" "$M/impostor.dylib"
    codesign -f -s - "$B" >/dev/null 2>&1 || true
    echo "removed (relaunch the apps)"; exit 0 ;;
  ""|install)
    [ -f "$HERE/impostor.dylib" ] || { echo "build first: bash build.sh"; exit 1; }
    mkdir -p "$HERE/backup"
    # keep a pristine copy of the stock dylib the first time
    if [ ! -f "$M/impostor-real.dylib" ]; then
      cp -p "$M/impostor.dylib" "$HERE/backup/impostor.dylib.stock"
      mv "$M/impostor.dylib" "$M/impostor-real.dylib"
    fi
    cp "$HERE/impostor.dylib" "$M/impostor.dylib"
    chmod 755 "$M/impostor.dylib"
    codesign -f -s - "$M/impostor.dylib" >/dev/null 2>&1 || true
    codesign -f -s - "$B" >/dev/null 2>&1 || echo "warning: codesign of the bundle failed"
    mkdir -p "$CFG"
    [ -f "$CFG/stencil" ] || echo copy > "$CFG/stencil"
    [ -f "$CFG/posh" ] || echo aggressive > "$CFG/posh"
    [ -f "$CFG/v16" ] || echo on > "$CFG/v16"
    [ -f "$CFG/v17" ] || echo on > "$CFG/v17"
    echo "installed; stencil=$(cat "$CFG/stencil") posh=$(cat "$CFG/posh") v16=$(cat "$CFG/v16") v17=$(cat "$CFG/v17")"
    echo "relaunch the apps you want to test (WindowServer is not affected)"
    exit 0 ;;
  *)
    echo "usage: $0 [install|remove|status|log|mode stencil|posh <value>]"; exit 1 ;;
esac
