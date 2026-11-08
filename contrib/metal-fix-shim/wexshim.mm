// wexshim.mm - combined WhateverXe Metal driver adapter for AppleIntelTGLGraphicsMTLDriver
//
// Installed as  .../AppleIntelTGLGraphicsMTLDriver.bundle/Contents/MacOS/impostor.dylib
// re-exporting the original  .../impostor-real.dylib
//
// Two independent fixes, each documented in its own upstream issue:
//
//   #36  stencil reads through an X32_Stencil8 / X24_Stencil8 view of a render-written
//        depth-stencil texture return wrong data (16x16 blocks).
//        Upstream workaround/source: rodgod-rr/WhateverXe, branch adls-stencil-view-fix,
//        contrib/stencil-view-fix/stencilfix.mm (BSD-3-Clause).  Used here unchanged in
//        behaviour: a stencil view of a depth-stencil texture is a view of a shadow copy,
//        refreshed by a blit at the end of every render pass that writes the texture.
//
//   #47  -[MTLIGAccelCommandBuffer dealloc] used to leak its private POSH buffer
//        (_pPoshUsedAsTarget) whenever m_isOnlyActiveCommandBuffer was set.
//        FIXED UPSTREAM in WhateverXe Graphics 0.4.2 (driver 0x7ed87 = 90 90).
//        The shim's POSH hook was removed to stay as close to upstream as possible.
//
// Safety:
//   * System processes (executable under /System or /usr) are skipped entirely, so
//     WindowServer and loginwindow keep the stock bundle behaviour.  The WindowServer
//     leak is fixed system-wide by leakfix/wex-posh-patch.sh (the documented 2-byte
//     binary patch), not by this dylib.
//   * Every hook validates the class, method and ivar types before touching anything.
//   * Everything can be disabled with the config files described below.
//
// Config (all optional):
//   /Library/Application Support/WEXMetalFixes/stencil   copy | noopt | both | off
//   Legacy: /Library/Application Support/StencilViewFix/mode  (copy|noopt|both|off)
// Defaults: stencil=copy.
//
// #47 (POSH leak) is fixed upstream in WhateverXe Graphics 0.4.2; this shim no
// longer hooks it.
//
// Log:
//   log show --last 10m --predicate 'subsystem == "org.wex.metalfixes"'
//
// Licence: the stencil part is derived from rodgod-rr's stencilfix.mm (BSD-3-Clause,
// same licence as WhateverXe).  The POSH part follows the analysis and sample code in
// b00t0x/WhateverXe issue #47.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <os/log.h>
#include <atomic>
#include <new>
#include <mach-o/dyld.h>
#include <stdlib.h>
#include <string.h>

static os_log_t lg;
static bool doCopy = true, doNoopt = false;
static std::atomic<long> nShadow{0}, nCopies{0}, nNoopt{0};

static NSString *readCfg(NSString *name, NSString *legacyPath) {
    NSString *p = [@"/Library/Application Support/WEXMetalFixes" stringByAppendingPathComponent:name];
    NSString *s = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
    if (!s && legacyPath) s = [NSString stringWithContentsOfFile:legacyPath encoding:NSUTF8StringEncoding error:nil];
    s = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return s.length ? s : nil;
}

static void loadConfig(void) {
    NSString *m = readCfg(@"stencil", @"/Library/Application Support/StencilViewFix/mode") ?: @"copy";
    doCopy  = [m isEqualToString:@"copy"]  || [m isEqualToString:@"both"];
    doNoopt = [m isEqualToString:@"noopt"] || [m isEqualToString:@"both"];
}

// ---------------------------------------------------------------- #36 stencil view

static bool dsFormat(MTLPixelFormat f) {
    return f == MTLPixelFormatDepth32Float_Stencil8 || f == MTLPixelFormatDepth24Unorm_Stencil8;
}
static bool stencilView(MTLPixelFormat f) {
    return f == MTLPixelFormatX32_Stencil8 || f == MTLPixelFormatX24_Stencil8;
}

// swizzle on this class only (an inherited method gets an override that calls the original)
static void hook(Class c, SEL s, id (^mk)(IMP)) {
    if (!c) return;
    Method m = class_getInstanceMethod(c, s);
    if (!m) { os_log(lg, "wexshim: %{public}s lacks %{public}s", class_getName(c), sel_getName(s)); return; }
    IMP o = method_getImplementation(m);
    class_replaceMethod(c, s, imp_implementationWithBlock(mk(o)), method_getTypeEncoding(m));
}

static const void *kShadow = &kShadow, *kSrc = &kSrc, *kCB = &kCB;

// shadow copy with the same type/slices/mips (Unity uses 2D and 1-slice 2DArray);
// multisample and buffer textures are skipped
static id<MTLTexture> shadowFor(id<MTLTexture> t) {
    id<MTLTexture> sh = objc_getAssociatedObject(t, kShadow);
    if (sh) return sh;
    MTLTextureType ty = t.textureType;
    bool ok = (ty == MTLTextureType2D || ty == MTLTextureType2DArray || ty == MTLTextureTypeCube || ty == MTLTextureTypeCubeArray)
              && t.sampleCount == 1 && !t.buffer && !t.parentTexture;
    if (!ok) {
        os_log(lg, "wexshim: stencil SKIPPED %lux%lu fmt %lu type %lu samples %lu slices %lu parent %d buffer %d",
               (unsigned long)t.width, (unsigned long)t.height, (unsigned long)t.pixelFormat, (unsigned long)ty,
               (unsigned long)t.sampleCount, (unsigned long)t.arrayLength, t.parentTexture != nil, t.buffer != nil);
        return nil;
    }
    MTLTextureDescriptor *d = [MTLTextureDescriptor new];
    d.textureType = ty; d.pixelFormat = t.pixelFormat; d.width = t.width; d.height = t.height; d.depth = t.depth;
    d.arrayLength = t.arrayLength; d.mipmapLevelCount = t.mipmapLevelCount; d.sampleCount = 1;
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
    d.storageMode = MTLStorageModePrivate;
    sh = [t.device newTextureWithDescriptor:d];
    if (sh) { objc_setAssociatedObject(t, kShadow, sh, OBJC_ASSOCIATION_RETAIN); ++nShadow; }
    os_log(lg, "wexshim: stencil shadow %lux%lu fmt %lu type %lu slices %lu mips %lu %{public}s (total %ld)",
           (unsigned long)t.width, (unsigned long)t.height, (unsigned long)t.pixelFormat, (unsigned long)ty,
           (unsigned long)t.arrayLength, (unsigned long)t.mipmapLevelCount, sh ? "ok" : "FAILED", nShadow.load());
    return sh;
}

static void installStencil(void) {
    Class tex = objc_getClass("MTLIGAccelTexture"), cbc = objc_getClass("MTLIGAccelCommandBuffer"),
          rec = objc_getClass("MTLIGAccelRenderCommandEncoder"), dev = objc_getClass("MTLIGAccelDevice");
    os_log(lg, "wexshim: stencil loaded in %{public}s (copy %d, noopt %d; classes %d%d%d%d)",
           getprogname(), doCopy, doNoopt, tex != nil, cbc != nil, rec != nil, dev != nil);

    if (doNoopt && dev) {
        SEL s = @selector(newTextureWithDescriptor:);
        hook(dev, s, ^id(IMP o) { return ^id(id self, MTLTextureDescriptor *d) {
            if (d && dsFormat(d.pixelFormat) && (d.usage & (MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView)) &&
                d.allowGPUOptimizedContents) {
                MTLTextureDescriptor *dd = [d copy]; dd.allowGPUOptimizedContents = NO;
                if (++nNoopt <= 8)
                    os_log(lg, "wexshim: stencil noopt %lux%lu fmt %lu", (unsigned long)d.width, (unsigned long)d.height, (unsigned long)d.pixelFormat);
                return ((id (*)(id, SEL, id))o)(self, s, dd);
            }
            return ((id (*)(id, SEL, id))o)(self, s, d); }; });
    }

    if (!doCopy || !tex || !cbc || !rec) return;

    SEL v1 = @selector(newTextureViewWithPixelFormat:);
    hook(tex, v1, ^id(IMP o) { return ^id(id self, MTLPixelFormat f) {
        id<MTLTexture> t = self;
        if (dsFormat(t.pixelFormat) && stencilView(f)) {
            os_log(lg, "wexshim: stencil view %lu->%lu %lux%lu", (unsigned long)t.pixelFormat, (unsigned long)f,
                   (unsigned long)t.width, (unsigned long)t.height);
            if (id<MTLTexture> sh = shadowFor(t)) return ((id (*)(id, SEL, MTLPixelFormat))o)(sh, v1, f);
        }
        return ((id (*)(id, SEL, MTLPixelFormat))o)(self, v1, f); }; });

    SEL v2 = @selector(newTextureViewWithPixelFormat:textureType:levels:slices:);
    hook(tex, v2, ^id(IMP o) { return ^id(id self, MTLPixelFormat f, MTLTextureType ty, NSRange l, NSRange sl) {
        id<MTLTexture> t = self;
        if (dsFormat(t.pixelFormat) && stencilView(f)) {
            os_log(lg, "wexshim: stencil view2 %lu->%lu type %lu %lux%lu", (unsigned long)t.pixelFormat,
                   (unsigned long)f, (unsigned long)ty, (unsigned long)t.width, (unsigned long)t.height);
            if (id<MTLTexture> sh = shadowFor(t))
                return ((id (*)(id, SEL, MTLPixelFormat, MTLTextureType, NSRange, NSRange))o)(sh, v2, f, ty, l, sl);
        }
        return ((id (*)(id, SEL, MTLPixelFormat, MTLTextureType, NSRange, NSRange))o)(self, v2, f, ty, l, sl); }; });

    SEL rs = @selector(renderCommandEncoderWithDescriptor:);
    hook(cbc, rs, ^id(IMP o) { return ^id(id self, MTLRenderPassDescriptor *d) {
        id enc = ((id (*)(id, SEL, id))o)(self, rs, d);
        id<MTLTexture> t = d.depthAttachment.texture ?: d.stencilAttachment.texture;
        if (t && !objc_getAssociatedObject(t, kShadow) && t.parentTexture) t = t.parentTexture; // pass rendered through a view (slice/mip)
        if (enc && t && objc_getAssociatedObject(t, kShadow)) {
            objc_setAssociatedObject(enc, kSrc, t, OBJC_ASSOCIATION_RETAIN);
            objc_setAssociatedObject(enc, kCB, self, OBJC_ASSOCIATION_ASSIGN);
        }
        return enc; }; });

    SEL ee = @selector(endEncoding);
    hook(rec, ee, ^id(IMP o) { return ^void(id self) {
        ((void (*)(id, SEL))o)(self, ee);
        id<MTLTexture> src = objc_getAssociatedObject(self, kSrc);
        if (!src) return;
        id<MTLTexture> sh = objc_getAssociatedObject(src, kShadow);
        id<MTLCommandBuffer> cb = objc_getAssociatedObject(self, kCB);
        objc_setAssociatedObject(self, kSrc, nil, OBJC_ASSOCIATION_RETAIN);
        if (sh && cb) {
            id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
            [bl copyFromTexture:src toTexture:sh];
            [bl endEncoding];
            long c = ++nCopies;
            if (c == 1 || c % 500 == 0) os_log(lg, "wexshim: stencil %ld blit copies", c);
        } }; });
}

// ---------------------------------------------------------------- entry point

__attribute__((constructor)) static void init(void) { @autoreleasepool {
    lg = os_log_create("org.wex.metalfixes", "fix");

    // Safety: never run inside system processes (WindowServer, loginwindow, ...).
    char exe[1024]; uint32_t n = sizeof exe;
    bool isSystem = (_NSGetExecutablePath(exe, &n) == 0) &&
                    (!strncmp(exe, "/System/", 8) || !strncmp(exe, "/usr/", 5));
    if (isSystem) return;

    loadConfig();
    installStencil();
} }
