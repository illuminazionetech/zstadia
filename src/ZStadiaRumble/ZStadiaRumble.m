// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Z Stadia contributors
//
// ZStadiaRumble.dylib
//
// Injected into a macOS game with DYLD_INSERT_LIBRARIES. Apple's Game Controller
// framework only gives haptics to controllers it knows (Xbox, PlayStation, MFi);
// for the Google Stadia Controller `GCController.haptics` is nil, so games never
// rumble it. This library returns a Core Haptics compatible engine for Stadia
// controllers, renders whatever the game plays into two motor levels and sends
// them as HID output report 5, over USB and Bluetooth LE.
//
// Threads: the game calls the haptics API from any thread and only touches the
// model under `gModelLock`. One private thread owns the controllers: it mixes
// the model every 4 ms and writes at most one report in flight per controller,
// always the newest levels, so Bluetooth never builds a queue.

#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <CoreHaptics/CoreHaptics.h>
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/hid/IOHIDKeys.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <os/log.h>
#import <pthread.h>
#import <time.h>
#import <math.h>
#import <stdatomic.h>

#define ZS_EXPORT __attribute__((visibility("default")))

static const char *const kZSVersion = "1.0.0";

static const uint32_t kStadiaVendorID = 0x18D1;
static const uint32_t kStadiaProductID = 0x9400;
static const uint8_t kRumbleReportID = 0x05;

static const double kMixInterval = 0.004;      // seconds between two mixes
static const double kUSBMinGap = 0.004;        // fastest report rate over USB
static const double kBluetoothMinGap = 0.012;  // leaves air time for input reports
static const double kKeepAlive = 0.5;          // resend a running level this often
static const double kWriteTimeout = 0.25;      // a write never acknowledged is dropped
static const double kTransientHold = 0.035;    // transient event: full level...
static const double kTransientLength = 0.060;  // ...then a short fade
static const double kSilence = 0.004;          // below this a motor is off

static inline double ZSNow(void) { return (double)clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9; }
static inline double ZSClamp01(double v) { return v < 0 ? 0 : (v > 1 ? 1 : v); }

#pragma mark - Configuration and logging

static struct {
    double gain;     // ZSTADIA_GAIN: multiplies every level (default 1.0)
    double floor;    // ZSTADIA_FLOOR: lowest level of a running motor (default 0.08)
    bool swap;       // ZSTADIA_SWAP_MOTORS=1: exchange the two motors
    bool dryRun;     // ZSTADIA_DRY_RUN=1: compute levels, never touch a controller
    char match[64];  // ZSTADIA_MATCH: extra controller name to treat as a Stadia
} gConfig = { 1.0, 0.08, false, false, "" };

static os_log_t gOSLog;
static FILE *gLogFile;
static size_t gLogBytes;
static const size_t kLogLimit = 4 << 20;
static os_unfair_lock gLogLock = OS_UNFAIR_LOCK_INIT;

static void ZSLog(const char *fmt, ...) __printflike(1, 2);
static void ZSLog(const char *fmt, ...) {
    if (!gLogFile) return;
    char line[768];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof line, fmt, ap);
    va_end(ap);
    os_unfair_lock_lock(&gLogLock);
    if (gLogBytes < kLogLimit) {
        int n = fprintf(gLogFile, "%.4f %s\n", ZSNow(), line);
        if (n > 0) gLogBytes += (size_t)n;
        if (gLogBytes >= kLogLimit) fputs("log limit reached, further lines dropped\n", gLogFile);
        fflush(gLogFile);
    }
    os_unfair_lock_unlock(&gLogLock);
}

static double ZSEnvDouble(const char *name, double fallback, double lo, double hi) {
    const char *s = getenv(name);
    if (!s || !*s) return fallback;
    char *end = NULL;
    double v = strtod(s, &end);
    if (end == s || !isfinite(v)) return fallback;
    return v < lo ? lo : (v > hi ? hi : v);
}

static bool ZSEnvFlag(const char *name) {
    const char *s = getenv(name);
    return s && (*s == '1' || *s == 'y' || *s == 'Y' || *s == 't' || *s == 'T');
}

#pragma mark - Haptic model

typedef struct {
    double time, duration;       // pattern time, seconds (duration may be INFINITY)
    double intensity, sharpness; // 0...1
    double attack, decay, release;
    bool sustained, transient;
} ZSEvent;

// A control value over time. `ramp` means: reach this value linearly from the
// previous point (parameter curves); otherwise the value steps here.
typedef struct {
    double time, value;
    bool ramp;
} ZSPoint;

typedef struct {
    ZSPoint *items;
    size_t count, capacity;
} ZSTrack;

enum { ZSIntensity = 0, ZSSharpness = 1, ZSTrackCount = 2 };

static void ZSTrackInsert(ZSTrack *t, double time, double value, bool ramp) {
    if (!isfinite(time) || !isfinite(value)) return;
    if (t->count == t->capacity) {
        size_t cap = t->capacity ? t->capacity * 2 : 8;
        ZSPoint *p = realloc(t->items, cap * sizeof(ZSPoint));
        if (!p) return;
        t->items = p;
        t->capacity = cap;
    }
    size_t i = t->count;
    while (i > 0 && t->items[i - 1].time > time) {
        t->items[i] = t->items[i - 1];
        i--;
    }
    t->items[i] = (ZSPoint){ time, value, ramp };
    t->count++;
}

static double ZSTrackValue(const ZSTrack *t, double time, double fallback) {
    size_t n = t->count;
    if (n == 0 || t->items[0].time > time) return fallback;
    size_t lo = 0, hi = n - 1;
    while (lo < hi) {  // last point with time <= `time`
        size_t mid = (lo + hi + 1) / 2;
        if (t->items[mid].time <= time) lo = mid; else hi = mid - 1;
    }
    const ZSPoint *a = &t->items[lo];
    if (lo + 1 < n && t->items[lo + 1].ramp) {
        const ZSPoint *b = &t->items[lo + 1];
        double span = b->time - a->time;
        if (span > 1e-9) return a->value + (b->value - a->value) * (time - a->time) / span;
    }
    return a->value;
}

// Keeps memory bounded for long-running players: points older than the last
// one already in effect can never matter again.
static void ZSTrackPrune(ZSTrack *t, double time) {
    if (t->count < 32) return;
    size_t keep = 0;
    while (keep + 1 < t->count && t->items[keep + 1].time <= time) keep++;
    if (keep == 0) return;
    memmove(t->items, t->items + keep, (t->count - keep) * sizeof(ZSPoint));
    t->count -= keep;
}

static void ZSTrackFree(ZSTrack *t) {
    free(t->items);
    *t = (ZSTrack){ 0 };
}

static double ZSEventLevel(const ZSEvent *e, double t) {
    if (t < 0) return 0;
    if (e->transient) {
        if (t >= kTransientLength) return 0;
        if (t < kTransientHold) return e->intensity;
        return e->intensity * (1 - (t - kTransientHold) / (kTransientLength - kTransientHold));
    }
    if (t >= e->duration) return 0;
    double env = 1;
    if (e->attack > 0 && t < e->attack) {
        env = t / e->attack;
    } else if (!e->sustained) {
        double fall = e->decay > 0 ? e->decay : 0.1;
        env = fmax(0, 1 - (t - e->attack) / fall);
    }
    if (e->release > 0 && isfinite(e->duration) && t > e->duration - e->release)
        env = fmin(env, (e->duration - t) / e->release);
    return e->intensity * env;
}

#pragma mark - Pattern data

// Immutable description of a CHHapticPattern, shared by every player of it.
@interface ZSPatternData : NSObject {
@public
    ZSEvent *events;
    size_t eventCount;
    ZSTrack tracks[ZSTrackCount];
    double duration;
}
+ (instancetype)dataWithEvents:(NSArray *)events parameters:(NSArray *)params curves:(NSArray *)curves;
+ (instancetype)dataWithDictionary:(NSDictionary *)ahap;
@end

static int ZSTrackForParameter(NSString *parameterID) {
    if ([parameterID isEqual:CHHapticDynamicParameterIDHapticIntensityControl]) return ZSIntensity;
    if ([parameterID isEqual:CHHapticDynamicParameterIDHapticSharpnessControl]) return ZSSharpness;
    return -1;
}

static double ZSNumber(id v, double fallback) {
    return [v isKindOfClass:[NSNumber class]] ? [v doubleValue] : fallback;
}

static ZSEvent ZSEventMake(NSString *type, double time, double duration) {
    ZSEvent e = { .time = time, .intensity = 1, .sharpness = 0.5, .sustained = true };
    e.transient = [type isEqual:CHHapticEventTypeHapticTransient];
    // GCHapticDurationInfinite is 1e6 seconds; treat that and anything longer as endless.
    e.duration = e.transient ? kTransientLength : (duration >= 1e6 || !isfinite(duration) ? INFINITY : fmax(0, duration));
    return e;
}

static void ZSEventApply(ZSEvent *e, NSString *parameterID, double value) {
    if ([parameterID isEqual:CHHapticEventParameterIDHapticIntensity]) e->intensity = ZSClamp01(value);
    else if ([parameterID isEqual:CHHapticEventParameterIDHapticSharpness]) e->sharpness = ZSClamp01(value);
    else if ([parameterID isEqual:CHHapticEventParameterIDAttackTime]) e->attack = fmax(0, value);
    else if ([parameterID isEqual:CHHapticEventParameterIDDecayTime]) e->decay = fmax(0, value);
    else if ([parameterID isEqual:CHHapticEventParameterIDReleaseTime]) e->release = fmax(0, value);
    else if ([parameterID isEqual:CHHapticEventParameterIDSustained]) e->sustained = value >= 0.5;
}

static bool ZSIsHapticEventType(NSString *type) {
    return [type isEqual:CHHapticEventTypeHapticTransient] || [type isEqual:CHHapticEventTypeHapticContinuous];
}

@implementation ZSPatternData

- (void)dealloc {
    free(events);
    for (int i = 0; i < ZSTrackCount; i++) ZSTrackFree(&tracks[i]);
}

- (void)finish {
    double end = 0;
    for (size_t i = 0; i < eventCount; i++) end = fmax(end, events[i].time + events[i].duration);
    for (int k = 0; k < ZSTrackCount; k++)
        if (tracks[k].count) end = fmax(end, tracks[k].items[tracks[k].count - 1].time);
    duration = end;
}

- (void)reserveEvents:(NSUInteger)n {
    events = calloc(MAX(n, 1), sizeof(ZSEvent));
}

+ (instancetype)dataWithEvents:(NSArray *)eventList parameters:(NSArray *)params curves:(NSArray *)curves {
    ZSPatternData *d = [ZSPatternData new];
    [d reserveEvents:eventList.count];
    for (CHHapticEvent *ev in eventList) {
        if (![ev isKindOfClass:[CHHapticEvent class]] || !ZSIsHapticEventType(ev.type) || !d->events) continue;
        ZSEvent e = ZSEventMake(ev.type, ev.relativeTime, ev.duration);
        for (CHHapticEventParameter *p in ev.eventParameters) ZSEventApply(&e, p.parameterID, p.value);
        d->events[d->eventCount++] = e;
    }
    for (CHHapticDynamicParameter *p in params) {
        if (![p isKindOfClass:[CHHapticDynamicParameter class]]) continue;
        int k = ZSTrackForParameter(p.parameterID);
        if (k >= 0) ZSTrackInsert(&d->tracks[k], p.relativeTime, p.value, false);
    }
    for (CHHapticParameterCurve *c in curves) {
        if (![c isKindOfClass:[CHHapticParameterCurve class]]) continue;
        int k = ZSTrackForParameter(c.parameterID);
        if (k < 0) continue;
        BOOL first = YES;
        for (CHHapticParameterCurveControlPoint *cp in c.controlPoints) {
            ZSTrackInsert(&d->tracks[k], c.relativeTime + cp.relativeTime, cp.value, !first);
            first = NO;
        }
    }
    [d finish];
    return d;
}

+ (instancetype)dataWithDictionary:(NSDictionary *)ahap {
    NSArray *items = [ahap isKindOfClass:[NSDictionary class]] ? ahap[CHHapticPatternKeyPattern] : nil;
    if (![items isKindOfClass:[NSArray class]]) return nil;
    ZSPatternData *d = [ZSPatternData new];
    [d reserveEvents:items.count];
    for (NSDictionary *item in items) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *ev = item[CHHapticPatternKeyEvent];
        NSDictionary *param = item[CHHapticPatternKeyParameter];
        NSDictionary *curve = item[CHHapticPatternKeyParameterCurve];
        if ([ev isKindOfClass:[NSDictionary class]] && d->events) {
            NSString *type = ev[CHHapticPatternKeyEventType];
            if (![type isKindOfClass:[NSString class]] || !ZSIsHapticEventType(type)) continue;
            ZSEvent e = ZSEventMake(type, ZSNumber(ev[CHHapticPatternKeyTime], 0), ZSNumber(ev[CHHapticPatternKeyEventDuration], 0));
            for (NSDictionary *p in ev[CHHapticPatternKeyEventParameters]) {
                if (![p isKindOfClass:[NSDictionary class]]) continue;
                NSString *pid = p[CHHapticPatternKeyParameterID];
                if ([pid isKindOfClass:[NSString class]]) ZSEventApply(&e, pid, ZSNumber(p[CHHapticPatternKeyParameterValue], 0));
            }
            d->events[d->eventCount++] = e;
        } else if ([param isKindOfClass:[NSDictionary class]]) {
            int k = ZSTrackForParameter(param[CHHapticPatternKeyParameterID]);
            if (k >= 0) ZSTrackInsert(&d->tracks[k], ZSNumber(param[CHHapticPatternKeyTime], 0), ZSNumber(param[CHHapticPatternKeyParameterValue], 1), false);
        } else if ([curve isKindOfClass:[NSDictionary class]]) {
            int k = ZSTrackForParameter(curve[CHHapticPatternKeyParameterID]);
            if (k < 0) continue;
            double base = ZSNumber(curve[CHHapticPatternKeyTime], 0);
            BOOL first = YES;
            for (NSDictionary *cp in curve[CHHapticPatternKeyParameterCurveControlPoints]) {
                if (![cp isKindOfClass:[NSDictionary class]]) continue;
                ZSTrackInsert(&d->tracks[k], base + ZSNumber(cp[CHHapticPatternKeyTime], 0), ZSNumber(cp[CHHapticPatternKeyParameterValue], 0), !first);
                first = NO;
            }
        }
    }
    [d finish];
    return d;
}

@end

#pragma mark - Capturing patterns

// Patterns are created by the game with Apple's own CHHapticPattern. Its
// initializers are wrapped so each pattern carries a ZSPatternData.
static char kPatternDataKey;

static ZSPatternData *ZSDataForPattern(CHHapticPattern *pattern) {
    if (!pattern) return nil;
    ZSPatternData *d = objc_getAssociatedObject(pattern, &kPatternDataKey);
    if (d) return d;
    if ([pattern respondsToSelector:@selector(exportDictionaryAndReturnError:)]) {
        NSDictionary *dict = [pattern exportDictionaryAndReturnError:nil];
        d = [ZSPatternData dataWithDictionary:dict];
    }
    if (!d) {  // Unknown origin: behave like a plain endless rumble.
        d = [ZSPatternData new];
        [d reserveEvents:1];
        if (d->events) d->events[d->eventCount++] = ZSEventMake(CHHapticEventTypeHapticContinuous, 0, INFINITY);
        [d finish];
    }
    objc_setAssociatedObject(pattern, &kPatternDataKey, d, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return d;
}

static void ZSWrapInitializer(SEL sel, id (^capture)(id result, NSArray *args)) {
    Method m = class_getInstanceMethod([CHHapticPattern class], sel);
    if (!m) return;
    IMP original = method_getImplementation(m);
    IMP wrapped = NULL;
    NSUInteger argc = [[NSStringFromSelector(sel) componentsSeparatedByString:@":"] count] - 1;
    if (argc == 2) {
        wrapped = imp_implementationWithBlock(^id(id self, id a, NSError **err) {
            id r = ((id (*)(id, SEL, id, NSError **))original)(self, sel, a, err);
            @try { if (r) capture(r, @[ a ?: [NSNull null] ]); } @catch (__unused id e) {}
            return r;
        });
    } else if (argc == 3) {
        wrapped = imp_implementationWithBlock(^id(id self, id a, id b, NSError **err) {
            id r = ((id (*)(id, SEL, id, id, NSError **))original)(self, sel, a, b, err);
            @try { if (r) capture(r, @[ a ?: [NSNull null], b ?: [NSNull null] ]); } @catch (__unused id e) {}
            return r;
        });
    }
    if (wrapped) method_setImplementation(m, wrapped);
}

static void ZSInstallPatternCapture(void) {
    ZSWrapInitializer(@selector(initWithEvents:parameters:error:), ^id(id r, NSArray *a) {
        id events = a[0], params = a[1];
        ZSPatternData *d = [ZSPatternData dataWithEvents:[events isKindOfClass:[NSArray class]] ? events : @[]
                                              parameters:[params isKindOfClass:[NSArray class]] ? params : @[]
                                                  curves:@[]];
        objc_setAssociatedObject(r, &kPatternDataKey, d, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return r;
    });
    ZSWrapInitializer(@selector(initWithEvents:parameterCurves:error:), ^id(id r, NSArray *a) {
        id events = a[0], curves = a[1];
        ZSPatternData *d = [ZSPatternData dataWithEvents:[events isKindOfClass:[NSArray class]] ? events : @[]
                                              parameters:@[]
                                                  curves:[curves isKindOfClass:[NSArray class]] ? curves : @[]];
        objc_setAssociatedObject(r, &kPatternDataKey, d, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return r;
    });
    ZSWrapInitializer(@selector(initWithDictionary:error:), ^id(id r, NSArray *a) {
        ZSPatternData *d = [ZSPatternData dataWithDictionary:a[0]];
        if (d) objc_setAssociatedObject(r, &kPatternDataKey, d, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return r;
    });
}

#pragma mark - Players and engines

typedef enum { ZSRouteStrong = 0, ZSRouteWeak = 1, ZSRouteBoth = 2 } ZSRoute;

@class ZSEngine;

// Everything below `@public` is guarded by gModelLock.
@interface ZSPlayer : NSObject <CHHapticAdvancedPatternPlayer> {
@public
    ZSEngine *engine;  // players keep their engine alive, like Core Haptics does
    ZSPatternData *pattern;
    bool playing, paused, active;
    double originHost, originTime;  // pattern time `originTime` happens at host time `originHost`
    double stopHost;
    double rate;
    bool loop, muted;
    double loopEnd;
    ZSTrack runtime[ZSTrackCount];  // host-time controls from sendParameters / curves
    CHHapticAdvancedPatternPlayerCompletionHandler completion;
}
@end

@interface ZSEngine : NSObject {
@public
    ZSRoute route;
    bool mutedHaptics;
    unsigned activePlayers;
    CHHapticEngineFinishedHandler finishedHandler;
}
@end

static os_unfair_lock gModelLock = OS_UNFAIR_LOCK_INIT;
static NSMutableArray<ZSPlayer *> *gActive;  // players that may produce output

static void ZSStartController(void);
static void ZSWake(void);

static double ZSHostTime(NSTimeInterval t) {
    // CHHapticTimeImmediate (0) or a time in the past means "now".
    double now = ZSNow();
    return (t <= 0 || t < now) ? now : t;
}

static NSError *ZSError(NSString *what) {
    return [NSError errorWithDomain:@"dev.zstadia.rumble" code:-1 userInfo:@{ NSLocalizedDescriptionKey: what }];
}

// Pattern time of player `p` at host time `now`. Caller holds gModelLock.
static double ZSPatternTime(ZSPlayer *p, double now) {
    if (p->paused) return p->originTime;
    return p->originTime + (now - p->originHost) * p->rate;
}

static void ZSActivate(ZSPlayer *p) {
    if (p->active) return;
    p->active = true;
    [gActive addObject:p];
    ZSEngine *e = p->engine;
    if (e) e->activePlayers++;
}

@implementation ZSPlayer

- (void)dealloc {
    for (int i = 0; i < ZSTrackCount; i++) ZSTrackFree(&runtime[i]);
}

- (BOOL)startAtTime:(NSTimeInterval)time error:(NSError **)outError {
    double at = ZSHostTime(time);
    os_unfair_lock_lock(&gModelLock);
    playing = true;
    paused = false;
    originHost = at;
    originTime = 0;
    stopHost = INFINITY;
    ZSActivate(self);
    os_unfair_lock_unlock(&gModelLock);
    ZSStartController();
    ZSWake();
    return YES;
}

- (BOOL)stopAtTime:(NSTimeInterval)time error:(NSError **)outError {
    double at = ZSHostTime(time);
    os_unfair_lock_lock(&gModelLock);
    if (playing) stopHost = fmin(stopHost, at);
    os_unfair_lock_unlock(&gModelLock);
    return YES;
}

- (BOOL)sendParameters:(NSArray<CHHapticDynamicParameter *> *)parameters atTime:(NSTimeInterval)time error:(NSError **)outError {
    double at = ZSHostTime(time);
    os_unfair_lock_lock(&gModelLock);
    for (CHHapticDynamicParameter *p in parameters) {
        if (![p isKindOfClass:[CHHapticDynamicParameter class]]) continue;
        int k = ZSTrackForParameter(p.parameterID);
        if (k >= 0) ZSTrackInsert(&runtime[k], at + fmax(0, p.relativeTime), p.value, false);
    }
    os_unfair_lock_unlock(&gModelLock);
    return YES;
}

- (BOOL)scheduleParameterCurve:(CHHapticParameterCurve *)curve atTime:(NSTimeInterval)time error:(NSError **)outError {
    if (![curve isKindOfClass:[CHHapticParameterCurve class]]) return YES;
    int k = ZSTrackForParameter(curve.parameterID);
    if (k < 0) return YES;
    double at = ZSHostTime(time) + fmax(0, curve.relativeTime);
    os_unfair_lock_lock(&gModelLock);
    BOOL first = YES;
    for (CHHapticParameterCurveControlPoint *cp in curve.controlPoints) {
        ZSTrackInsert(&runtime[k], at + cp.relativeTime, cp.value, !first);
        first = NO;
    }
    os_unfair_lock_unlock(&gModelLock);
    return YES;
}

- (BOOL)cancelAndReturnError:(NSError **)outError {
    os_unfair_lock_lock(&gModelLock);
    stopHost = ZSNow();
    os_unfair_lock_unlock(&gModelLock);
    return YES;
}

- (BOOL)pauseAtTime:(NSTimeInterval)time error:(NSError **)outError {
    double now = ZSNow();
    os_unfair_lock_lock(&gModelLock);
    if (playing && !paused) {
        originTime = ZSPatternTime(self, fmax(now, originHost));
        paused = true;
    }
    os_unfair_lock_unlock(&gModelLock);
    return YES;
}

- (BOOL)resumeAtTime:(NSTimeInterval)time error:(NSError **)outError {
    double at = ZSHostTime(time);
    os_unfair_lock_lock(&gModelLock);
    if (playing && paused) {
        originHost = at;
        paused = false;
    }
    os_unfair_lock_unlock(&gModelLock);
    return YES;
}

- (BOOL)seekToOffset:(NSTimeInterval)offset error:(NSError **)outError {
    double now = ZSNow();
    os_unfair_lock_lock(&gModelLock);
    originTime = fmax(0, offset);
    originHost = now;
    os_unfair_lock_unlock(&gModelLock);
    return YES;
}

- (BOOL)loopEnabled { os_unfair_lock_lock(&gModelLock); BOOL v = loop; os_unfair_lock_unlock(&gModelLock); return v; }
- (void)setLoopEnabled:(BOOL)v { os_unfair_lock_lock(&gModelLock); loop = v; os_unfair_lock_unlock(&gModelLock); }
- (NSTimeInterval)loopEnd { os_unfair_lock_lock(&gModelLock); double v = loopEnd; os_unfair_lock_unlock(&gModelLock); return v; }
- (void)setLoopEnd:(NSTimeInterval)v { os_unfair_lock_lock(&gModelLock); loopEnd = fmax(0, v); os_unfair_lock_unlock(&gModelLock); }
- (BOOL)isMuted { os_unfair_lock_lock(&gModelLock); BOOL v = muted; os_unfair_lock_unlock(&gModelLock); return v; }
- (void)setIsMuted:(BOOL)v { os_unfair_lock_lock(&gModelLock); muted = v; os_unfair_lock_unlock(&gModelLock); }

- (float)playbackRate {
    os_unfair_lock_lock(&gModelLock);
    float v = (float)rate;
    os_unfair_lock_unlock(&gModelLock);
    return v;
}

- (void)setPlaybackRate:(float)v {
    double now = ZSNow();
    os_unfair_lock_lock(&gModelLock);
    if (playing && !paused && now > originHost) {  // rebase so the change has no jump
        originTime = ZSPatternTime(self, now);
        originHost = now;
    }
    rate = (isfinite(v) && v > 0) ? v : 1;
    os_unfair_lock_unlock(&gModelLock);
}

- (CHHapticAdvancedPatternPlayerCompletionHandler)completionHandler {
    os_unfair_lock_lock(&gModelLock);
    CHHapticAdvancedPatternPlayerCompletionHandler h = completion;
    os_unfair_lock_unlock(&gModelLock);
    return h;
}

- (void)setCompletionHandler:(CHHapticAdvancedPatternPlayerCompletionHandler)h {
    os_unfair_lock_lock(&gModelLock);
    completion = [h copy];
    os_unfair_lock_unlock(&gModelLock);
}

@end

// Level and sharpness of player `p` at host time `now`; *done when it ended.
// Caller holds gModelLock.
static void ZSPlayerSample(ZSPlayer *p, double now, double *level, double *sharp, bool *done) {
    *level = 0;
    *sharp = 0.5;
    *done = false;
    if (!p->playing) { *done = true; return; }
    if (now >= p->stopHost) { *done = true; return; }
    if (p->paused || now < p->originHost) return;  // paused, or scheduled for later
    ZSPatternData *d = p->pattern;
    double t = ZSPatternTime(p, now);
    double length = (p->loopEnd > 0) ? p->loopEnd : d->duration;
    if (p->loop && length > 1e-3 && isfinite(length)) {
        t = fmod(t, length);
    } else if (isfinite(d->duration) && t >= d->duration) {
        *done = true;
        return;
    }
    double best = 0, bestSharp = 0.5;
    for (size_t i = 0; i < d->eventCount; i++) {
        double v = ZSEventLevel(&d->events[i], t - d->events[i].time);
        if (v > best) { best = v; bestSharp = d->events[i].sharpness; }
    }
    best *= ZSClamp01(ZSTrackValue(&d->tracks[ZSIntensity], t, 1));
    best *= ZSClamp01(ZSTrackValue(&p->runtime[ZSIntensity], now, 1));
    bestSharp += ZSTrackValue(&d->tracks[ZSSharpness], t, 0) + ZSTrackValue(&p->runtime[ZSSharpness], now, 0);
    for (int k = 0; k < ZSTrackCount; k++) ZSTrackPrune(&p->runtime[k], now);
    ZSEngine *engine = p->engine;
    *level = (p->muted || (engine && engine->mutedHaptics)) ? 0 : best;
    *sharp = ZSClamp01(bestSharp);
}

// Both motors at host time `now`, as levels 0...1. With `collect`, ended players
// are retired and their completion handlers returned to be called unlocked.
static void ZSMix(double now, double *strong, double *weak, NSMutableArray *collect) {
    double s = 0, w = 0;
    os_unfair_lock_lock(&gModelLock);
    for (NSInteger i = (NSInteger)gActive.count - 1; i >= 0; i--) {
        ZSPlayer *p = gActive[(NSUInteger)i];
        double level, sharp;
        bool done;
        ZSPlayerSample(p, now, &level, &sharp, &done);
        if (done) {
            if (collect) {
                p->playing = false;
                p->active = false;
                ZSEngine *e = p->engine;
                if (p->completion) [collect addObject:p->completion];
                if (e && e->activePlayers > 0 && --e->activePlayers == 0 && e->finishedHandler) {
                    CHHapticEngineFinishedHandler fh = e->finishedHandler;
                    e->finishedHandler = nil;
                    [collect addObject:^(NSError *unused) { fh(nil); }];
                }
                [gActive removeObjectAtIndex:(NSUInteger)i];
            }
            continue;
        }
        ZSEngine *engine = p->engine;
        ZSRoute route = engine ? engine->route : ZSRouteBoth;
        switch (route) {
            case ZSRouteStrong: s = fmax(s, level); break;
            case ZSRouteWeak: w = fmax(w, level); break;
            case ZSRouteBoth:  // low sharpness feels like the heavy motor, high like the light one
                s = fmax(s, level * ZSClamp01(1.25 - sharp));
                w = fmax(w, level * ZSClamp01(0.25 + sharp));
                break;
        }
    }
    os_unfair_lock_unlock(&gModelLock);
    *strong = gConfig.swap ? w : s;
    *weak = gConfig.swap ? s : w;
}

@implementation ZSEngine

- (BOOL)startAndReturnError:(NSError **)outError { ZSStartController(); return YES; }
- (void)startWithCompletionHandler:(CHHapticCompletionHandler)h {
    ZSStartController();
    if (h) dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ h(nil); });
}

- (void)stopWithCompletionHandler:(CHHapticCompletionHandler)h {
    double now = ZSNow();
    os_unfair_lock_lock(&gModelLock);
    for (ZSPlayer *p in gActive)
        if (p->engine == self) p->stopHost = fmin(p->stopHost, now);
    os_unfair_lock_unlock(&gModelLock);
    if (h) dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ h(nil); });
}

- (void)notifyWhenPlayersFinished:(CHHapticEngineFinishedHandler)h {
    if (!h) return;
    os_unfair_lock_lock(&gModelLock);
    bool idle = activePlayers == 0;
    if (!idle) finishedHandler = [h copy];
    os_unfair_lock_unlock(&gModelLock);
    if (idle) dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ h(nil); });
}

- (id)makePlayer:(CHHapticPattern *)pattern error:(NSError **)outError {
    ZSPatternData *d = ZSDataForPattern(pattern);
    if (!d) {
        if (outError) *outError = ZSError(@"Z Stadia: pattern is nil");
        return nil;
    }
    ZSPlayer *p = [ZSPlayer new];
    p->engine = self;
    p->pattern = d;
    p->rate = 1;
    p->stopHost = INFINITY;
    ZSLog("player created: %zu events, duration %.3f, route %d", d->eventCount, d->duration, route);
    return p;
}

- (id<CHHapticPatternPlayer>)createPlayerWithPattern:(CHHapticPattern *)pattern error:(NSError **)outError {
    return [self makePlayer:pattern error:outError];
}

- (id<CHHapticAdvancedPatternPlayer>)createAdvancedPlayerWithPattern:(CHHapticPattern *)pattern error:(NSError **)outError {
    return [self makePlayer:pattern error:outError];
}

- (BOOL)playPattern:(NSDictionary *)ahap error:(NSError **)outError {
    if (![ahap isKindOfClass:[NSDictionary class]]) {
        if (outError) *outError = ZSError(@"Z Stadia: unreadable AHAP pattern");
        return NO;
    }
    CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithDictionary:ahap error:outError];
    id<CHHapticPatternPlayer> p = [self makePlayer:pattern error:outError];
    return p ? [p startAtTime:CHHapticTimeImmediate error:outError] : NO;
}

- (BOOL)playPatternFromURL:(NSURL *)url error:(NSError **)outError {
    NSData *data = url ? [NSData dataWithContentsOfURL:url options:0 error:outError] : nil;
    return data ? [self playPatternFromData:data error:outError] : NO;
}

- (BOOL)playPatternFromData:(NSData *)data error:(NSError **)outError {
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:outError] : nil;
    return [self playPattern:json error:outError];
}

- (NSUInteger)registerAudioResource:(NSURL *)url options:(NSDictionary *)options error:(NSError **)outError { return 1; }
- (BOOL)unregisterAudioResource:(NSUInteger)resourceID error:(NSError **)outError { return YES; }

- (NSTimeInterval)currentTime { return ZSNow(); }
- (BOOL)isMutedForHaptics { os_unfair_lock_lock(&gModelLock); BOOL v = mutedHaptics; os_unfair_lock_unlock(&gModelLock); return v; }
- (void)setIsMutedForHaptics:(BOOL)v { os_unfair_lock_lock(&gModelLock); mutedHaptics = v; os_unfair_lock_unlock(&gModelLock); }
- (BOOL)isMutedForAudio { return YES; }
- (void)setIsMutedForAudio:(BOOL)v {}
- (BOOL)playsHapticsOnly { return YES; }
- (void)setPlaysHapticsOnly:(BOOL)v {}
- (BOOL)playsAudioOnly { return NO; }
- (void)setPlaysAudioOnly:(BOOL)v {}
- (BOOL)isAutoShutdownEnabled { return NO; }
- (void)setAutoShutdownEnabled:(BOOL)v {}
- (CHHapticEngineStoppedHandler)stoppedHandler { return nil; }
- (void)setStoppedHandler:(CHHapticEngineStoppedHandler)h {}
- (CHHapticEngineResetHandler)resetHandler { return nil; }
- (void)setResetHandler:(CHHapticEngineResetHandler)h {}

// Anything else a game may call on CHHapticEngine answers "nothing, no error"
// instead of crashing it with an unrecognized selector.
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    return [super methodSignatureForSelector:sel] ?: [CHHapticEngine instanceMethodSignatureForSelector:sel] ?: [NSMethodSignature signatureWithObjCTypes:"@@:"];
}

- (void)forwardInvocation:(NSInvocation *)inv {
    ZSLog("engine: unsupported call %s answered with zero", sel_getName(inv.selector));
    NSUInteger n = inv.methodSignature.methodReturnLength;
    if (n) {
        void *zero = calloc(1, n);
        [inv setReturnValue:zero];
        free(zero);
    }
}

@end

#pragma mark - Game Controller haptics

@interface ZSHaptics : NSObject
@end

@implementation ZSHaptics

- (NSSet<GCHapticsLocality> *)supportedLocalities {
    return [NSSet setWithObjects:GCHapticsLocalityDefault, GCHapticsLocalityAll, GCHapticsLocalityHandles,
                                 GCHapticsLocalityLeftHandle, GCHapticsLocalityRightHandle, nil];
}

- (CHHapticEngine *)createEngineWithLocality:(GCHapticsLocality)locality {
    ZSEngine *e = [ZSEngine new];
    if ([locality isEqual:GCHapticsLocalityLeftHandle]) e->route = ZSRouteStrong;
    else if ([locality isEqual:GCHapticsLocalityRightHandle]) e->route = ZSRouteWeak;
    else e->route = ZSRouteBoth;
    ZSLog("engine created for locality %s, route %d", locality.UTF8String ?: "?", e->route);
    ZSStartController();
    return (CHHapticEngine *)e;
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    return [super methodSignatureForSelector:sel] ?: [GCDeviceHaptics instanceMethodSignatureForSelector:sel] ?: [NSMethodSignature signatureWithObjCTypes:"@@:"];
}

- (void)forwardInvocation:(NSInvocation *)inv {
    ZSLog("haptics: unsupported call %s answered with zero", sel_getName(inv.selector));
    NSUInteger n = inv.methodSignature.methodReturnLength;
    if (n) {
        void *zero = calloc(1, n);
        [inv setReturnValue:zero];
        free(zero);
    }
}

@end

static char kHapticsKey;

static bool ZSIsStadia(id controller) {
    NSString *name = nil;
    @try { name = [controller vendorName]; } @catch (__unused id e) {}
    if (![name isKindOfClass:[NSString class]]) return false;
    if ([name rangeOfString:@"stadia" options:NSCaseInsensitiveSearch].location != NSNotFound) return true;
    return gConfig.match[0] && [name rangeOfString:@(gConfig.match) options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static id ZSHapticsFor(id controller) {
    if (!ZSIsStadia(controller)) return nil;
    ZSHaptics *h = objc_getAssociatedObject(controller, &kHapticsKey);
    if (!h) {
        h = [ZSHaptics new];
        objc_setAssociatedObject(controller, &kHapticsKey, h, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSString *name = [controller vendorName];
        ZSLog("haptics provided for \"%s\"", name.UTF8String ?: "?");
        os_log(gOSLog, "Z Stadia: haptics provided for %{public}@", name);
    }
    return h;
}

static bool ZSDefinesMethod(Class cls, SEL sel) {
    unsigned int n = 0;
    Method *list = class_copyMethodList(cls, &n);
    bool found = false;
    for (unsigned int i = 0; i < n && !found; i++) found = method_getName(list[i]) == sel;
    free(list);
    return found;
}

static void ZSHookHapticsOf(Class cls) {
    Method m = class_getInstanceMethod(cls, @selector(haptics));
    if (!m) return;
    IMP original = method_getImplementation(m);
    IMP hook = imp_implementationWithBlock(^id(id self) {
        id real = ((id (*)(id, SEL))original)(self, @selector(haptics));
        return real ?: ZSHapticsFor(self);
    });
    method_setImplementation(m, hook);
}

// GCController and every subclass that overrides `haptics` (the framework
// hands out private subclasses on some macOS versions).
static void ZSInstallHapticsHook(void) {
    Class base = [GCController class];
    if (!base || !class_getInstanceMethod(base, @selector(haptics))) {
        os_log_error(gOSLog, "Z Stadia: GCController.haptics not found, rumble disabled");
        return;
    }
    ZSHookHapticsOf(base);
    // Only the framework's own classes can subclass GCController for real
    // controllers; scanning just its image keeps game startup untouched.
    const char *image = class_getImageName(base);
    unsigned int n = 0;
    const char **names = image ? objc_copyClassNamesForImage(image, &n) : NULL;
    for (unsigned int i = 0; i < n; i++) {
        Class c = objc_getClass(names[i]);
        if (!c || c == base) continue;
        for (Class s = class_getSuperclass(c); s; s = class_getSuperclass(s)) {
            if (s != base) continue;
            if (ZSDefinesMethod(c, @selector(haptics))) ZSHookHapticsOf(c);
            break;
        }
    }
    free(names);
}

#pragma mark - Controller output

typedef struct ZSDevice {
    IOHIDDeviceRef ref;
    bool bluetooth, inFlight, everSent, gone, syncOnly;
    double inFlightSince, lastSend, worstLatency;
    uint16_t sentStrong, sentWeak;
    uint8_t report[5];
    unsigned failures;
    struct ZSDevice *next;
} ZSDevice;

// Owned by the controller thread only.
static ZSDevice *gDevices;
static IOHIDManagerRef gManager;
static uint16_t gWantStrong, gWantWeak;
static pthread_once_t gControllerOnce = PTHREAD_ONCE_INIT;
static volatile bool gControllerStarted;

// While nothing plays and both motors rest, the mixer timer is parked: the
// thread sleeps with zero wake-ups until a game starts a player again.
static CFRunLoopRef gLoop;
static CFRunLoopTimerRef gTimer;
static atomic_bool gParked;
static const CFTimeInterval kParkedInterval = 365.0 * 24 * 3600;

static void ZSWake(void) {
    if (!atomic_exchange(&gParked, false)) return;
    CFRunLoopRef loop = gLoop;
    if (!loop) return;
    CFRunLoopPerformBlock(loop, kCFRunLoopDefaultMode, ^{
        CFRunLoopTimerSetNextFireDate(gTimer, CFAbsoluteTimeGetCurrent());
    });
    CFRunLoopWakeUp(loop);
}

static uint16_t ZSShape(double v) {
    if (!(v > kSilence)) return 0;  // also catches NaN
    v = fmin(1.0, v * gConfig.gain);
    v = gConfig.floor + (1.0 - gConfig.floor) * v;
    return (uint16_t)lrint(ZSClamp01(v) * 65535.0);
}

static void ZSPump(ZSDevice *d, double now);

static void ZSReportDone(void *context, IOReturn result, void *sender, IOHIDReportType type,
                         uint32_t reportID, uint8_t *report, CFIndex length) {
    ZSDevice *d = context;
    d->inFlight = false;
    if (d->gone) {  // disconnected while this write was pending
        free(d);
        return;
    }
    double latency = ZSNow() - d->inFlightSince;
    if (result != kIOReturnSuccess) {
        d->failures++;
        ZSLog("write failed 0x%08x after %.1f ms", result, latency * 1000);
    } else {
        d->failures = 0;
        if (latency > d->worstLatency) {
            d->worstLatency = latency;
            ZSLog("slowest acknowledged write so far: %.1f ms (%s)", latency * 1000, d->bluetooth ? "Bluetooth" : "USB");
        }
    }
    ZSPump(d, ZSNow());
}

static void ZSSend(ZSDevice *d, uint16_t strong, uint16_t weak, double now) {
    d->report[0] = kRumbleReportID;
    d->report[1] = strong & 0xFF;
    d->report[2] = strong >> 8;
    d->report[3] = weak & 0xFF;
    d->report[4] = weak >> 8;
    d->sentStrong = strong;
    d->sentWeak = weak;
    d->everSent = true;
    d->lastSend = now;
    IOReturn r = kIOReturnUnsupported;
    if (!d->syncOnly) {
        d->inFlight = true;
        d->inFlightSince = now;
        r = IOHIDDeviceSetReportWithCallback(d->ref, kIOHIDReportTypeOutput, kRumbleReportID, d->report,
                                             sizeof d->report, kWriteTimeout, ZSReportDone, d);
        if (r == kIOReturnSuccess) return;
        d->inFlight = false;
        if (r == kIOReturnUnsupported) {
            d->syncOnly = true;
            ZSLog("asynchronous writes unsupported, using synchronous ones");
        }
    }
    if (d->syncOnly) r = IOHIDDeviceSetReport(d->ref, kIOHIDReportTypeOutput, kRumbleReportID, d->report, sizeof d->report);
    if (r != kIOReturnSuccess) {
        d->failures++;
        ZSLog("write rejected 0x%08x", r);
    }
}

static void ZSPump(ZSDevice *d, double now) {
    if (d->gone) return;
    if (d->inFlight) {
        if (now - d->inFlightSince < kWriteTimeout) return;
        d->inFlight = false;  // never acknowledged: do not wait forever
    }
    uint16_t s = gWantStrong, w = gWantWeak;
    bool changed = !d->everSent || s != d->sentStrong || w != d->sentWeak;
    bool keepAlive = (s || w) && now - d->lastSend >= kKeepAlive;
    if (!changed && !keepAlive) return;
    if (now - d->lastSend < (d->bluetooth ? kBluetoothMinGap : kUSBMinGap)) return;
    ZSSend(d, s, w, now);
}

static void ZSMixTick(CFRunLoopTimerRef timer, void *info) {
    @autoreleasepool {
        static NSMutableArray *callbacks;
        if (!callbacks) callbacks = [NSMutableArray new];
        double now = ZSNow(), s, w;
        ZSMix(now, &s, &w, callbacks);
        for (id cb in callbacks) {
            void (^handler)(NSError *) = cb;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ handler(nil); });
        }
        [callbacks removeAllObjects];
        uint16_t S = ZSShape(s), W = ZSShape(w);
        if (S != gWantStrong || W != gWantWeak) {
            if (gConfig.dryRun) ZSLog("motors strong %u weak %u", S, W);
            else if (!(gWantStrong || gWantWeak)) ZSLog("rumble starts: strong %u weak %u", S, W);
            else if (!(S || W)) ZSLog("rumble stops");
            gWantStrong = S;
            gWantWeak = W;
        }
        bool quiet = !(gWantStrong || gWantWeak);
        for (ZSDevice *d = gDevices; d; d = d->next) {
            ZSPump(d, now);
            if (d->inFlight || !d->everSent || d->sentStrong || d->sentWeak) quiet = false;
        }
        if (quiet) {
            // Mark parked before looking at the players, so a player started in
            // between always finds the flag set and wakes the timer.
            atomic_store(&gParked, true);
            os_unfair_lock_lock(&gModelLock);
            bool idle = gActive.count == 0;
            os_unfair_lock_unlock(&gModelLock);
            if (idle) CFRunLoopTimerSetNextFireDate(timer, CFAbsoluteTimeGetCurrent() + kParkedInterval);
            else atomic_store(&gParked, false);
        }
    }
}

static bool ZSIsBluetooth(IOHIDDeviceRef ref) {
    CFTypeRef t = IOHIDDeviceGetProperty(ref, CFSTR(kIOHIDTransportKey));
    if (!t || CFGetTypeID(t) != CFStringGetTypeID()) return false;
    return [(__bridge NSString *)t rangeOfString:@"Bluetooth"].location != NSNotFound;
}

static void ZSDeviceMatched(void *context, IOReturn result, void *sender, IOHIDDeviceRef ref) {
    @autoreleasepool {
    for (ZSDevice *d = gDevices; d; d = d->next)
        if (d->ref == ref && !d->gone) return;
    IOReturn r = IOHIDDeviceOpen(ref, kIOHIDOptionsTypeNone);
    if (r != kIOReturnSuccess) {
        ZSLog("could not open controller: 0x%08x", r);
        os_log_error(gOSLog, "Z Stadia: could not open the controller (0x%08x)", r);
        return;
    }
    ZSDevice *d = calloc(1, sizeof *d);
    if (!d) return;
    d->ref = (IOHIDDeviceRef)CFRetain(ref);
    d->bluetooth = ZSIsBluetooth(ref);
    d->next = gDevices;
    gDevices = d;
    ZSLog("controller connected via %s", d->bluetooth ? "Bluetooth" : "USB");
    os_log(gOSLog, "Z Stadia: controller connected via %{public}s", d->bluetooth ? "Bluetooth" : "USB");
    ZSPump(d, ZSNow());
    atomic_store(&gParked, false);
    if (gTimer) CFRunLoopTimerSetNextFireDate(gTimer, CFAbsoluteTimeGetCurrent());
    }
}

static void ZSDeviceRemoved(void *context, IOReturn result, void *sender, IOHIDDeviceRef ref) {
    for (ZSDevice **link = &gDevices; *link;) {
        ZSDevice *d = *link;
        if (d->ref != ref) { link = &d->next; continue; }
        *link = d->next;
        d->gone = true;
        ZSLog("controller disconnected (%s)", d->bluetooth ? "Bluetooth" : "USB");
        CFRelease(d->ref);
        // A write may still be pending; its callback no longer arrives once the
        // device is gone, but keep the memory to stay safe if it does.
        if (!d->inFlight) free(d);
        return;
    }
}

static void *ZSControllerThread(void *unused) {
    pthread_setname_np("Z Stadia controller");
    @autoreleasepool {
        CFRunLoopRef loop = CFRunLoopGetCurrent();
        if (!gConfig.dryRun) {
            gManager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
            NSDictionary *match = @{ @kIOHIDVendorIDKey: @(kStadiaVendorID), @kIOHIDProductIDKey: @(kStadiaProductID) };
            IOHIDManagerSetDeviceMatching(gManager, (__bridge CFDictionaryRef)match);
            IOHIDManagerRegisterDeviceMatchingCallback(gManager, ZSDeviceMatched, NULL);
            IOHIDManagerRegisterDeviceRemovalCallback(gManager, ZSDeviceRemoved, NULL);
            IOHIDManagerScheduleWithRunLoop(gManager, loop, kCFRunLoopDefaultMode);
            IOHIDManagerOpen(gManager, kIOHIDOptionsTypeNone);
        }
        CFRunLoopTimerRef timer = CFRunLoopTimerCreate(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + kMixInterval,
                                                       kMixInterval, 0, 0, ZSMixTick, NULL);
        CFRunLoopTimerSetTolerance(timer, kMixInterval / 4);
        CFRunLoopAddTimer(loop, timer, kCFRunLoopDefaultMode);
        gTimer = timer;
        gLoop = loop;
    }
    for (;;) @autoreleasepool { CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0e10, false); }
    return NULL;
}

static void ZSStartControllerOnce(void) {
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_attr_set_qos_class_np(&attr, QOS_CLASS_USER_INTERACTIVE, 0);
    pthread_t thread;
    if (pthread_create(&thread, &attr, ZSControllerThread, NULL) == 0) gControllerStarted = true;
    pthread_attr_destroy(&attr);
}

// The controller is opened only once a game asks for Stadia haptics, so helper
// processes that inherit the library stay untouched.
static void ZSStartController(void) { pthread_once(&gControllerOnce, ZSStartControllerOnce); }

// Motors must never keep spinning after the game is gone. This runs on the
// exiting thread with its own short-lived connection, independent of the
// controller thread.
static void ZSStopMotorsOnExit(void) {
    if (!gControllerStarted || gConfig.dryRun) return;
    IOHIDManagerRef m = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    if (!m) return;
    NSDictionary *match = @{ @kIOHIDVendorIDKey: @(kStadiaVendorID), @kIOHIDProductIDKey: @(kStadiaProductID) };
    IOHIDManagerSetDeviceMatching(m, (__bridge CFDictionaryRef)match);
    IOHIDManagerOpen(m, kIOHIDOptionsTypeNone);
    NSSet *devices = CFBridgingRelease(IOHIDManagerCopyDevices(m));
    uint8_t zero[5] = { kRumbleReportID, 0, 0, 0, 0 };
    for (id dev in devices) {
        IOHIDDeviceRef ref = (__bridge IOHIDDeviceRef)dev;
        if (IOHIDDeviceOpen(ref, kIOHIDOptionsTypeNone) != kIOReturnSuccess) continue;
        IOHIDDeviceSetReport(ref, kIOHIDReportTypeOutput, kRumbleReportID, zero, sizeof zero);
        IOHIDDeviceClose(ref, kIOHIDOptionsTypeNone);
    }
    IOHIDManagerClose(m, kIOHIDOptionsTypeNone);
    CFRelease(m);
}

#pragma mark - Test and diagnostics entry points

// Levels the mixer would produce at host time `when` (<= 0 means now), without
// retiring players. Used by the test suite.
ZS_EXPORT void ZStadiaDebugLevels(double when, double *strong, double *weak) {
    double s = 0, w = 0;
    ZSMix(when > 0 ? when : ZSNow(), &s, &w, nil);
    if (strong) *strong = s;
    if (weak) *weak = w;
}

ZS_EXPORT uint16_t ZStadiaDebugShape(double level) { return ZSShape(level); }

ZS_EXPORT const char *ZStadiaVersion(void) { return kZSVersion; }

ZS_EXPORT bool ZStadiaDebugParked(void) { return atomic_load(&gParked); }

ZS_EXPORT double ZStadiaDebugNow(void) { return ZSNow(); }

#pragma mark - Load

__attribute__((constructor)) static void ZSLoad(void) {
    if (ZSEnvFlag("ZSTADIA_DISABLE")) return;
    @autoreleasepool {
        gOSLog = os_log_create("dev.zstadia", "rumble");
        gConfig.gain = ZSEnvDouble("ZSTADIA_GAIN", 1.0, 0.0, 4.0);
        gConfig.floor = ZSEnvDouble("ZSTADIA_FLOOR", 0.08, 0.0, 0.6);
        gConfig.swap = ZSEnvFlag("ZSTADIA_SWAP_MOTORS");
        gConfig.dryRun = ZSEnvFlag("ZSTADIA_DRY_RUN");
        const char *match = getenv("ZSTADIA_MATCH");
        if (match) strlcpy(gConfig.match, match, sizeof gConfig.match);
        const char *logPath = getenv("ZSTADIA_LOG");
        if (logPath && *logPath) gLogFile = fopen(logPath, "w");
        gActive = [NSMutableArray new];
        ZSInstallPatternCapture();
        ZSInstallHapticsHook();
        atexit(ZSStopMotorsOnExit);
        ZSLog("Z Stadia rumble %s loaded into %s (gain %.2f, floor %.2f%s%s)", kZSVersion, getprogname(),
              gConfig.gain, gConfig.floor, gConfig.swap ? ", motors swapped" : "", gConfig.dryRun ? ", dry run" : "");
        os_log(gOSLog, "Z Stadia rumble %{public}s loaded", kZSVersion);
    }
}
