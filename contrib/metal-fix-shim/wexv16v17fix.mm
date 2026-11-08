// wexv16v17fix.mm - v16 (blit ordering) + v17 (Stencil8 64 KB) for the WEX shim.
//
// Compiled MRC (-fno-objc-arc), because the "new"-family IMP indirection and the
// temp-buffer pool must be manually retained (under ARC the v17 path over-releases
// and crashes).  Linked into impostor.dylib alongside the ARC wexshim.mm; the two
// translation units hook disjoint selectors with the default config, so they
// compose:
//   wexshim.mm : MTLIGAccelTexture view hooks, MTLIGAccelCommandBuffer dealloc
//      this TU : MTLIGAccelDevice newTextureWithDescriptor: (v17),
//                MTLIGAccelBlitCommandEncoder fill/copy (v16)
// (with stencil=noopt the shim also hooks newTextureWithDescriptor:; do not use
// that mode together with v17.)
//
// Reimplements the documented NootedGreen libxedrv v16/v17 behaviour. No
// NootedGreen code is vendored.
//
//   v16: this driver routes fillBuffer and aligned copyFromBuffer to a 2D blitter
//        path and misaligned copies to a 3D path; 3D work of a CB does not wait for
//        earlier 2D writes.  Keep everything on the 3D path: fills become copies
//        from a shared pattern buffer at (dst+4)&63; aligned copies become two
//        misaligned copies through a pooled private temp.
//   v17: the driver allocates Stencil8 at 4 KB alignment (its own heap alignment
//        reports 64 KB).  A Stencil8 in the last 64 KB block of an RT used in the
//        same pass loses writes.  Recreate Private+RenderTarget Stencil8/X32_Stencil8
//        that is not 64 KB aligned in a private 64 KB-rounded heap.
//
// Config (WEXMetalFixes dir), default ON:
//   v16        on|off
//   v17        on|off
// Env overrides for testing: WEX_BLITORDER, WEX_STENCIL64K, WEX_FILL_NATIVO,
// WEX_COPIA_NATIVA, WEX_V16_NATIVO, WEX_V17_NATIVO.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <os/log.h>
#include <pthread.h>
#include <atomic>
#include <stdarg.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <mach-o/dyld.h>

static os_log_t lg;

static bool cfgOn(NSString *name, const char *env, bool def) {
    const char *e = getenv(env);
    if (e) {
        if (!strcmp(e, "0") || !strcmp(e, "off") || !strcmp(e, "no") || !strcmp(e, "")) return false;
        return true;
    }
    NSString *p = [@"/Library/Application Support/WEXMetalFixes" stringByAppendingPathComponent:name];
    NSString *s = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
    if (!s) return def;
    s = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return ![s isEqualToString:@"off"] && s.length;
}

static void logm(const char *fmt, ...) __attribute__((format(printf,1,2)));
static void logm(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    char m[512]; vsnprintf(m, sizeof m, fmt, ap); va_end(ap);
    os_log(lg, "%{public}s", m);
}

static bool doV16 = true, doV17 = true, copiaNative = false;

static IMP hookFn(Class c, SEL s, IMP fn) {
    if (!c) return NULL;
    Method m = class_getInstanceMethod(c, s);
    if (!m) return NULL;
    IMP o = method_getImplementation(m);
    class_replaceMethod(c, s, fn, method_getTypeEncoding(m));
    return o;
}
static uint64_t gpuAddr(id t) {
    static SEL sg; if (!sg) sg = sel_registerName("gpuAddress");
    return [t respondsToSelector:sg] ? ((uint64_t (*)(id,SEL))objc_msgSend)(t, sg) : 0;
}

// ---------------------------------------------------------------- v17
static std::atomic<long> nS64{0}, nS64Fail{0};
static id realignStencil64k(id dev, id r, MTLTextureDescriptor *d) __attribute__((ns_returns_retained));
static id realignStencil64k(id dev, id r, MTLTextureDescriptor *d) {
    if (!r || !d) return nil;
    if (d.storageMode != MTLStorageModePrivate) return nil;
    if (!(d.usage & MTLTextureUsageRenderTarget)) return nil;
    MTLPixelFormat f = d.pixelFormat;
    if (f != MTLPixelFormatStencil8 && f != MTLPixelFormatX32_Stencil8) return nil;
    uint64_t ga = gpuAddr(r);
    if (!ga || !(ga & 0xffff)) return nil;
    SEL sz = sel_registerName("heapTextureSizeAndAlignWithDescriptor:");
    if (![dev respondsToSelector:sz]) return nil;
    MTLSizeAndAlign sa = ((MTLSizeAndAlign(*)(id,SEL,id))objc_msgSend)(dev, sz, d);
    if (!sa.size) return nil;
    MTLHeapDescriptor *hd = [[MTLHeapDescriptor new] autorelease];
    hd.storageMode = MTLStorageModePrivate; hd.cpuCacheMode = d.cpuCacheMode;
    hd.size = (sa.size + 0xffff) & ~(NSUInteger)0xffff;
    if ([hd respondsToSelector:@selector(setHazardTrackingMode:)]) hd.hazardTrackingMode = MTLHazardTrackingModeTracked;
    id<MTLHeap> h = [dev newHeapWithDescriptor:hd];
    id t = h ? [h newTextureWithDescriptor:d] : nil;
    uint64_t gb = t ? gpuAddr(t) : 0;
    if (!t || (gb & 0xffff)) {
        if (++nS64Fail <= 8) logm("v17 STENCIL64K %lux%lu fmt %lu at 0x%llx heap failed, keeping original",
            (unsigned long)d.width, (unsigned long)d.height, (unsigned long)f, ga);
        return nil;
    }
    NSString *lab = [r label]; if (lab) [t setLabel:lab];
    long n = ++nS64;
    if (n <= 4 || (n & (n - 1)) == 0) logm("v17 STENCIL64K %lux%lu fmt %lu 0x%llx -> heap 0x%llx (n=%ld)",
        (unsigned long)d.width, (unsigned long)d.height, (unsigned long)f, ga, gb, n);
    [r release]; [h release];
    return t;
}
static IMP gOrigNewTex = NULL;
static id newTexHook(id self, SEL _cmd, MTLTextureDescriptor *d) {
    id r = ((id(*)(id,SEL,id))gOrigNewTex)(self, _cmd, d);
    if (doV17) { id t = realignStencil64k(self, r, d); if (t) r = t; }
    return r;
}

// ---------------------------------------------------------------- v16
#define PAT_LEN 65536
#define TMP_SMALL (65536 + 128)
#define TMP_BIG ((4u << 20) + 128)
static IMP gOrigFill = NULL, gOrigFill4 = NULL, gOrigB2B = NULL;
static Class gIGBlit = NULL; static SEL gB2BSel = NULL;
static std::atomic<long> nFill{0}, nB2B{0};
static const void *kPat = &kPat, *kTmp = &kTmp;
static pthread_mutex_t gPoolMutex = PTHREAD_MUTEX_INITIALIZER;

static id<MTLBuffer> patternFor(id<MTLDevice> dev, uint32_t v) {
    pthread_mutex_lock(&gPoolMutex);
    NSMutableDictionary *m = objc_getAssociatedObject(dev, kPat);
    if (!m) { m = [NSMutableDictionary dictionary]; objc_setAssociatedObject(dev, kPat, m, OBJC_ASSOCIATION_RETAIN); }
    NSNumber *key = @(v);
    id<MTLBuffer> b = m[key];
    if (!b) {
        b = [dev newBufferWithLength:PAT_LEN + 64 options:MTLResourceStorageModeShared]; // not WriteCombined: rejected
        if (b) { uint32_t *p = (uint32_t *)b.contents; for (NSUInteger i = 0; i < (PAT_LEN + 64)/4; i++) p[i] = v;
                 m[key] = b; [b release]; }
    }
    pthread_mutex_unlock(&gPoolMutex);
    return b;
}
static BOOL fillAsCopy(id enc, id<MTLBuffer> buf, NSRange r, uint32_t pat) {
    if (!gOrigB2B || !buf || !r.length || ![enc isKindOfClass:gIGBlit]) return NO;
    id<MTLBuffer> p = patternFor(buf.device, pat); if (!p) return NO;
    for (NSUInteger off = 0; off < r.length; off += PAT_LEN) {
        NSUInteger dst = r.location + off, n = MIN((NSUInteger)PAT_LEN, r.length - off), so = (dst + 4) & 63;
        ((void(*)(id,SEL,id,NSUInteger,id,NSUInteger,NSUInteger))gOrigB2B)(enc, gB2BSel, p, so, buf, dst, n);
    }
    long k = ++nFill;
    if (k <= 3 || (k & (k - 1)) == 0) logm("v16 FILL len=%lu range=%lu+%lu pat=%08x -> copy (n=%ld)",
        (unsigned long)buf.length, (unsigned long)r.location, (unsigned long)r.length, pat, k);
    return YES;
}
static void fillHook(id self, SEL _cmd, id<MTLBuffer> b, NSRange r, uint8_t v) {
    if (fillAsCopy(self, b, r, v * 0x01010101u)) return;
    ((void(*)(id,SEL,id,NSRange,uint8_t))gOrigFill)(self, _cmd, b, r, v);
}
static void fill4Hook(id self, SEL _cmd, id<MTLBuffer> b, NSRange r, uint32_t v) {
    if (!(r.location & 3) && !(r.length & 3) && fillAsCopy(self, b, r, v)) return;
    ((void(*)(id,SEL,id,NSRange,uint32_t))gOrigFill4)(self, _cmd, b, r, v);
}
static id<MTLBuffer> tmpGet(id<MTLDevice> dev, NSUInteger need) {
    NSUInteger sz = need <= TMP_SMALL ? TMP_SMALL : TMP_BIG;
    id<MTLBuffer> b = nil;
    pthread_mutex_lock(&gPoolMutex);
    NSMutableArray *pool = objc_getAssociatedObject(dev, kTmp);
    if (!pool) { pool = [NSMutableArray array]; objc_setAssociatedObject(dev, kTmp, pool, OBJC_ASSOCIATION_RETAIN); }
    for (NSUInteger i = 0; i < pool.count; i++) { id<MTLBuffer> c = pool[i]; if (c.length == sz) { b = [c retain]; [pool removeObjectAtIndex:i]; break; } }
    pthread_mutex_unlock(&gPoolMutex);
    if (!b) b = [dev newBufferWithLength:sz options:MTLResourceStorageModePrivate];
    return b;
}
static void tmpPut(id<MTLDevice> dev, id<MTLBuffer> b) {
    pthread_mutex_lock(&gPoolMutex);
    NSMutableArray *pool = objc_getAssociatedObject(dev, kTmp);
    if (pool && pool.count < 8) [pool addObject:b];
    pthread_mutex_unlock(&gPoolMutex);
}
static void b2bHook(id self, SEL _cmd, id<MTLBuffer> src, NSUInteger so, id<MTLBuffer> dst, NSUInteger dof, NSUInteger n) {
    typedef void (*CP)(id,SEL,id,NSUInteger,id,NSUInteger,NSUInteger);
    if (copiaNative || !n || ((so - dof) & 63) || !src || !dst || ![self isKindOfClass:gIGBlit]) { ((CP)gOrigB2B)(self,_cmd,src,so,dst,dof,n); return; }
    id<MTLCommandBuffer> cb = [self respondsToSelector:@selector(commandBuffer)] ? ((id(*)(id,SEL))objc_msgSend)(self, @selector(commandBuffer)) : nil;
    id<MTLDevice> dev = dst.device;
    NSUInteger chunk = n <= TMP_SMALL - 128 ? n : (TMP_BIG - 128);
    id<MTLBuffer> tmp = cb ? tmpGet(dev, chunk + 128) : nil;
    if (!tmp) { ((CP)gOrigB2B)(self,_cmd,src,so,dst,dof,n); return; }
    for (NSUInteger off = 0; off < n; off += chunk) {
        NSUInteger k = MIN(chunk, n - off), t = (so + off + 4) & 63;
        ((CP)gOrigB2B)(self,_cmd,src,so+off,tmp,t,k);
        ((CP)gOrigB2B)(self,_cmd,tmp,t,dst,dof+off,k);
    }
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done){ (void)done; tmpPut(dev, tmp); [tmp release]; }];
    long q = ++nB2B;
    if (q <= 3 || (q & (q - 1)) == 0) logm("v16 COPY aligned %lu (%lu->%lu) -> two 3D copies (n=%ld)", (unsigned long)n, (unsigned long)so, (unsigned long)dof, q);
}
static void installBlitOrder(void) {
    Class k = objc_getClass("MTLIGAccelBlitCommandEncoder"), io = objc_getClass("MTLIOAccelBlitCommandEncoder");
    if (!k) { logm("v16 skipped: no MTLIGAccelBlitCommandEncoder"); return; }
    gOrigB2B = hookFn(k, @selector(copyFromBuffer:sourceOffset:toBuffer:destinationOffset:size:), (IMP)b2bHook);
    if (!gOrigB2B) { logm("v16 skipped: no copy method"); return; }
    gB2BSel = @selector(copyFromBuffer:sourceOffset:toBuffer:destinationOffset:size:);
    gIGBlit = k;
    gOrigFill = hookFn(k, @selector(fillBuffer:range:value:), (IMP)fillHook);
    if (io) gOrigFill4 = hookFn(io, @selector(fillBuffer:range:pattern4:), (IMP)fill4Hook);
    if (!gOrigFill) gOrigFill = (IMP)1;
    logm("v16 on: fill=%d fill4=%d", gOrigFill != (IMP)1, gOrigFill4 != NULL);
}
static void installV17(void) {
    gOrigNewTex = hookFn(objc_getClass("MTLIGAccelDevice"), @selector(newTextureWithDescriptor:), (IMP)newTexHook);
    if (!gOrigNewTex) logm("v17 skipped: no MTLIGAccelDevice newTextureWithDescriptor:");
    else logm("v17 on");
}

__attribute__((constructor)) static void init(void) {
    @autoreleasepool {
        char exe[1024]; uint32_t m = sizeof exe;
        bool sys = (_NSGetExecutablePath(exe, &m) == 0) && (!strncmp(exe, "/System/", 8) || !strncmp(exe, "/usr/", 5));
        if (sys) return;   // keep the shim app-process-only (WindowServer untouched)
        lg = os_log_create("org.wex.metalfixes", "v16");
        doV16  = cfgOn(@"v16", "WEX_BLITORDER", true);
        doV17  = cfgOn(@"v17", "WEX_STENCIL64K", true);
        copiaNative = false;
        doV16  = doV16 && !cfgOn(@"v16", "WEX_V16_NATIVO", false);
        if (doV17) installV17();
        if (doV16) installBlitOrder();
    }
}