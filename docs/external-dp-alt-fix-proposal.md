# External USB-C display fix — proposal & status (2026-11-09)

## Authoritative "why" (WEX's own CHANGELOG)

WhateverXe CHANGELOG (for the "newly supported mobile GPUs" release) states:

> "Internal panels and Type-C-managed output on the newly supported mobile GPUs
> still need implementation; existing DisplayPort reconnection and Sequoia App
> Store video hangs remain unresolved."

This machine is Raptor Lake-U `8086:a7a1` — one of those newly supported mobile
configurations. Therefore **the donor's XeLP Display13 path does not (yet)
implement Type-C / DP-alt display output for this device class.** The USB-C
port works for USB, but there is no donor wiring from the Type-C/DP-alt port to
a display pipe, which is exactly why there is no EDID / candidate / hot-plug
detection and the external only ever appears on the firmware boot framebuffer.
"USB-C DP Alt output" was added for Alder Lake-class GPUs (CHANGELOG), so the
machinery exists but was not extended to this mobile class.

## What was confirmed live (good accelerated boot, 2026-11-09)

* Only the internal panel is online (1920x1200, IODisplayEDID count = 1); no
  second display, no external EDID.
* `WEXDisplay13TCHooksReady = Yes`, `XELPDisplay13DPProbeAvailable = Yes`,
  `XELPDisplay13TCProbeAvailable = Yes` (Type-C hooks are installed in the
  accelerated boot) — yet no external output appears.
* `tglDPAltCandidates` / `TGLTCWiring` / `WhateverXeDPAltCandidates` are **not
  published** on this XeLP machine (those are TGL-path properties that do not
  run on RPL-U).
* The relevant gate is the XELP Display13 external-DP admission
  (`kern_xe.cpp:4349`): `adlnOutputWiring.dp && (!display13TCDPProbeReady ||
  !display13FBSSTHooksReady || !display13FBAUXHooksReady)`.

## Build status

* Toolchain fetched and working: Lilu (DEBUG, ships Resources) + MacKernelSDK.
* Stock build succeeds: `WhateverXe.kext` sha256 `2159684f2d4c0bac…`,
  `AppleIntelTGLCompat.kext` `b0fa57c588fd46bd…`. So a correct maintainer
  patch can be built and stick-tested here immediately.

## Conclusion

The fix is upstream WEX work (extend Type-C/DP-alt output to newly supported
mobile GPUs). It is not a local detection toggle. No kext change here can safely
manufacture the missing output path; forging the admission would risk a
hang/panic on the tested boot (the README itself warns DP/USB-C reconnection can
freeze). Per this machine's policy: **document and wait on upstream.** The build
pipeline is ready for when a patch lands.

## Earlier analysis (kept for reference)

Investigation into why the external monitor (USB-C -> Lenovo ThinkPad USB-C Dock
Gen2 -> HDMI) shows up only as a boot/firmware framebuffer and never with
acceleration on this Raptor Lake-U (`8086:a7a1`, Lenovo Yoga) WhateverXe 0.8.0
setup.

## Root cause (two distinct problems)

1. **External as boot display  -> no acceleration.** When the firmware/OpenCore
   hands the GOP boot framebuffer to the external (internal off), WEX's N97
   donor rejects the accelerator probe because it has no internal panel to
   borrow as donor:
   - `kern_xe.cpp` `wrapAlderLakeNRejectedAcceleratorProbe` sets
     `N97NativeProbeBlocked=true` and returns null.
   - Removing this rejection is unsafe (no panel/timing source -> likely blank /
     panic).

2. **Internal as boot display  -> acceleration, but external never lit.**
   `tglDPAltCandidates==0`. It is computed in
   `kern_vbt.hpp::tglDPAltCandidates(backend)`, which returns 0 unless the
   firmware/VBT port record is `valid()` and a non-internal DP port has a
   matching Type-C AUX owner (`port[ddi].aux==tglTCAux(ddi)`). On this machine
   no such valid USB-C DP-alt port record exists, so the candidate mask is 0 and
   the Type-C DP-alt light-up path bails:
   `kern_xe.cpp:16956 if(!tglDPAltCandidates && !-wex-tc-bootstrap) return;`.

Documented lever `-wex-tc-bootstrap -wex-tc-aux` was tested (stick boot) but
cannot substitute for the missing donor panel (problem 1) and does not create a
valid VBT USB-C DP-alt port record (problem 2).

## Build blockers (why nothing was staged as a kext)

* No `MacKernelSDK` and no `Lilu.kext` dev headers/library on this machine; the
  kext links Lilu, so a working build is not possible here without fetching the
  acidanthera toolchain.
* No prebuilt `WhateverXe.kext` on disk to patch/re-sign.
* The correct fix is WEX's in-progress "USB-C / DisplayPort on
  Raptor Lake-H/P/U" roadmap item; a safe fix must validate the donor/VBT port
  wiring, which a blind candidate bitmask cannot do (could misroute or freeze,
  per WEX README's own warning).

## Proposed upstream change (for review, NOT built)

Site A — `kern_vbt.hpp::tglDPAltCandidates`: when a compatible external sink is
presented on the USB-C/DP-alt ports and the firmware record is absent/empty,
fall back to building the candidate mask from the live port/FIA state
(`tglDPAltProbe::mode`) for the Type-C DDI(s) (3..PortCount), matching
`tglTCAux`. Guard both by "has a real sink via AUX" and "not the eDP donor".

Site B — `kern_xe.cpp:16956` / TC light-up: keep the `-wex-tc-bootstrap`
escalation but do not let it run while the boot display is the external (needs
the internal panel as donor), to avoid the probe-blocked fallback.

Both are additive and conservative; neither was built, signed, or injected
anywhere. This document is the reviewable hand-off.

## Status
* Stick staging of `-wex-tc-bootstrap -wex-tc-aux` tested -> reproduced the
  no-accel fallback; reverted stick config + clean backup.
* Internal NVRAM still holds the two flags from the stick boot (must be cleared
  to restore the good accelerated boot; see step B below).
* Nothing was modified on the internal ESP or the installed shim/patch (driver
  `0b8c00bb..`, shim `548c094a..`, `0x7ed87 = 90 90`).
* Recommendation: wait on upstream WEX for RPL-U USB-C/DP-alt output.