# Metal driver fix shim (AppleIntelTGLGraphicsMTLDriver)

**AI-assisted work — patches are provided for independent review and testing.**

A user-space adapter for the WhateverXe Graphics Metal driver bundle
(`/Library/GPUBundles/AppleIntelTGLGraphicsMTLDriver.bundle`). It is installed
as the bundle's `impostor.dylib` and re-exports the original (`impostor-real`).
It targets **app processes only** — the constructor returns early for any
executable under `/System` or `/usr`, so WindowServer and system daemons keep
the stock behaviour.

Verified on: macOS 26.7.2 (25G332), WhateverXe Graphics 0.4.1, driver 16.0.32,
iGPU `8086:a7a1` (TGL).

## What it fixes

| Fix | Issue / reference | Mechanism |
|---|---|---|
| #36 stencil view | b00t0x/WhateverXe#36 | Render-written depth-stencil texture read through an X32/X24 `Stencil8` view returns wrong 16x16 blocks → shadow copy refreshed by a blit at each render pass |
| #47 POSH buffer leak | **fixed upstream** in WhateverXe-Graphics 0.4.2 (`0x7ed87 = 90 90`); the shim no longer hooks POSH | removed to stay close to upstream |
| v16 blit ordering | NootedGreen libxedrv v16 (see #72) | 2D/3D blit paths race within one command buffer → route buffer writes through the 3D path (fill→pattern copy, aligned copy→two misaligned copies via a pooled temp) |
| v17 Stencil8 64 KB | NootedGreen libxedrv v17 (see #72) | Device allocates Stencil8 at 4 KB alignment → recreate non-aligned Private+RenderTarget Stencil8 in a private 64 KB-rounded heap |

The v16/v17 work is tracked in https://github.com/b00t0x/WhateverXe/issues/72
and is a reimplementation of documented NootedGreen behaviour (no code vendored).

## Files

* `wexshim.mm` — ARC translation unit: #36 stencil hooks (#47 POSH removed — now upstream).
* `wexv16v17fix.mm` — MRC translation unit (its `new`-family IMP indirection and
  the temp-buffer pool must be manually retained, ARC over-releases the v17
  path): v16 blit ordering + v17 Stencil8 64 KB.
* `build.sh` — compiles both translation units and links `impostor.dylib`
  (ad-hoc signed), re-exporting the original.
* `install.sh` — install / remove / status / config (`mode stencil|posh|v16|v17`).

## Config

Written to `/Library/Application Support/WEXMetalFixes/`:

* `stencil` : `copy | noopt | both | off` (default `copy`)
* `posh`    : `aggressive | safe | off` (default `aggressive`)
* `v16`     : `on | off` (default `on`)
* `v17`     : `on | off` (default `on`)

## Validation (app-process, driver 16.0.32)

* #47: empty-CB RSS 16.26 → 0.14 KB/CB; 4 KB blit 16.38 → 0.18 KB/CB.
* v16: mixed fill+aligned+misaligned copies vs CPU expectation 0/20 mismatch;
  pure fill byte value 0/10 wrong.
* v17: 512×512 Stencil8 write + `Equal` readback 0/262144 failed.

The v16/v17 tests prove the fixes are safe and byte-for-byte correct; the stock
failures are pattern/data-dependent and were not reproduced, so nothing here is
claimed as "fixed".

## Install

```bash
bash build.sh
sudo bash install.sh        # apps launched afterwards
sudo bash install.sh status
```

Apply the #47 WindowServer side with the separate 2-byte driver patch (not in
this branch). Both installers ad-hoc re-sign the bundle, so hand back the
installed `impostor-real.dylib` on removal.