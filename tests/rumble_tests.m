// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Z Stadia contributors
//
// Tests for ZStadiaRumble.dylib that need no controller. The library runs in
// dry-run mode and every check samples the motor levels at an exact host time,
// so results do not depend on the speed of the machine.
//
//   make test

#import <Foundation/Foundation.h>
#import <CoreHaptics/CoreHaptics.h>
#import <GameController/GameController.h>
#include <dlfcn.h>
#include <stdatomic.h>

static void (*Levels)(double, double *, double *);
static uint16_t (*Shape)(double);
static double (*Now)(void);
static bool (*Parked)(void);
static int failures, checks;

#define CHECK(cond, ...) do { checks++; if (!(cond)) { failures++; printf("FAIL %s:%d ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

static bool near(double a, double b) { return fabs(a - b) < 0.02; }

static void at(double t, double *s, double *w) { Levels(t, s, w); }

static CHHapticPattern *continuous(double time, double duration, float intensity, float sharpness) {
    CHHapticEvent *e = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous
                                                    parameters:@[ [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:intensity],
                                                                  [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:sharpness] ]
                                                  relativeTime:time duration:duration];
    return [[CHHapticPattern alloc] initWithEvents:@[ e ] parameters:@[] error:nil];
}

static id engineFor(GCHapticsLocality locality) {
    static id haptics;
    if (!haptics) haptics = [NSClassFromString(@"ZSHaptics") new];
    id engine = [haptics createEngineWithLocality:locality];
    [engine startAndReturnError:nil];
    return engine;
}

// Each test gets its own window far from the others, starting in the future.
static double window(void) {
    static double base;
    if (!base) base = Now() + 5;
    double t = base;
    base += 1000;
    return t;
}

// With nothing playing the mixer must sleep, and a new player must wake it.
static void testParking(void) {
    id engine = engineFor(GCHapticsLocalityLeftHandle);
    [[engine createPlayerWithPattern:continuous(0, 0.05, 1, 0.5f) error:nil] startAtTime:0 error:nil];
    usleep(300000);
    CHECK(Parked(), "mixer parks when idle");
    __block atomic_int done = 0;
    id<CHHapticAdvancedPatternPlayer> p = [engine createAdvancedPlayerWithPattern:continuous(0, 0.05, 1, 0.5f) error:nil];
    p.completionHandler = ^(NSError *e) { atomic_fetch_add(&done, 1); };
    [p startAtTime:0 error:nil];
    usleep(5000);
    CHECK(!Parked(), "a new player wakes the mixer");
    for (int i = 0; i < 50 && !done; i++) usleep(10000);
    CHECK(done == 1, "the woken mixer finishes the player: %d", done);
    usleep(300000);
    CHECK(Parked(), "and parks again afterwards");
}

static void testRouting(void) {
    double t0 = window(), s, w;
    id<CHHapticPatternPlayer> left = [engineFor(GCHapticsLocalityLeftHandle) createPlayerWithPattern:continuous(0, 1, 0.8f, 0.5f) error:nil];
    [left startAtTime:t0 error:nil];
    at(t0 - 0.01, &s, &w); CHECK(s == 0 && w == 0, "silent before start: %f %f", s, w);
    at(t0 + 0.5, &s, &w); CHECK(near(s, 0.8) && w == 0, "left handle drives the strong motor: %f %f", s, w);
    at(t0 + 1.01, &s, &w); CHECK(s == 0 && w == 0, "silent after the event: %f %f", s, w);

    double t1 = window();
    id<CHHapticPatternPlayer> right = [engineFor(GCHapticsLocalityRightHandle) createPlayerWithPattern:continuous(0, 1, 0.6f, 0.5f) error:nil];
    [right startAtTime:t1 error:nil];
    at(t1 + 0.5, &s, &w); CHECK(s == 0 && near(w, 0.6), "right handle drives the weak motor: %f %f", s, w);

    double t2 = window();
    id engine = engineFor(GCHapticsLocalityDefault);
    [[engine createPlayerWithPattern:continuous(0, 1, 1, 0) error:nil] startAtTime:t2 error:nil];
    at(t2 + 0.5, &s, &w); CHECK(near(s, 1) && near(w, 0.25), "dull rumble leans on the strong motor: %f %f", s, w);
    double t3 = window();
    [[engine createPlayerWithPattern:continuous(0, 1, 1, 1) error:nil] startAtTime:t3 error:nil];
    at(t3 + 0.5, &s, &w); CHECK(near(s, 0.25) && near(w, 1), "sharp rumble leans on the weak motor: %f %f", s, w);
}

static void testTransient(void) {
    double t0 = window(), s, w;
    CHHapticEvent *e = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticTransient
                                                    parameters:@[ [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:1] ]
                                                  relativeTime:0.2];
    CHHapticPattern *p = [[CHHapticPattern alloc] initWithEvents:@[ e ] parameters:@[] error:nil];
    [[engineFor(GCHapticsLocalityRightHandle) createPlayerWithPattern:p error:nil] startAtTime:t0 error:nil];
    at(t0 + 0.1, &s, &w); CHECK(w == 0, "transient waits for its time: %f", w);
    at(t0 + 0.21, &s, &w); CHECK(near(w, 1), "transient is a full pulse: %f", w);
    at(t0 + 0.25, &s, &w); CHECK(w > 0 && w < 1, "transient fades: %f", w);
    at(t0 + 0.27, &s, &w); CHECK(w == 0, "transient is short: %f", w);
}

// The way SDL, Unreal and Cyberpunk drive rumble: one endless event whose
// strength changes with dynamic parameters.
static void testEndlessWithControl(void) {
    double t0 = window(), s, w;
    id<CHHapticPatternPlayer> p = [engineFor(GCHapticsLocalityLeftHandle) createPlayerWithPattern:continuous(0, GCHapticDurationInfinite, 1, 0.5f) error:nil];
    [p startAtTime:t0 error:nil];
    CHHapticDynamicParameter *third = [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:0.3f relativeTime:0];
    [p sendParameters:@[ third ] atTime:t0 + 0.2 error:nil];
    at(t0 + 0.1, &s, &w); CHECK(near(s, 1), "full before the control: %f", s);
    at(t0 + 0.3, &s, &w); CHECK(near(s, 0.3), "control scales the level: %f", s);
    at(t0 + 500, &s, &w); CHECK(near(s, 0.3), "endless event keeps going: %f", s);
    [p stopAtTime:t0 + 600 error:nil];
    at(t0 + 600.01, &s, &w); CHECK(s == 0, "stopAtTime ends it: %f", s);
}

static void testCurves(void) {
    double t0 = window(), s, w;
    CHHapticEvent *e = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous
                                                    parameters:@[ [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:1] ]
                                                  relativeTime:0 duration:2];
    CHHapticParameterCurve *ramp = [[CHHapticParameterCurve alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl
                                                                         controlPoints:@[ [[CHHapticParameterCurveControlPoint alloc] initWithRelativeTime:0 value:0],
                                                                                          [[CHHapticParameterCurveControlPoint alloc] initWithRelativeTime:1 value:1] ]
                                                                          relativeTime:0];
    CHHapticPattern *p = [[CHHapticPattern alloc] initWithEvents:@[ e ] parameterCurves:@[ ramp ] error:nil];
    [[engineFor(GCHapticsLocalityLeftHandle) createPlayerWithPattern:p error:nil] startAtTime:t0 error:nil];
    at(t0 + 0.25, &s, &w); CHECK(near(s, 0.25), "pattern curve ramps up: %f", s);
    at(t0 + 0.75, &s, &w); CHECK(near(s, 0.75), "pattern curve ramps up: %f", s);
    at(t0 + 1.5, &s, &w); CHECK(near(s, 1), "holds the last point: %f", s);

    double t1 = window();
    id<CHHapticPatternPlayer> q = [engineFor(GCHapticsLocalityLeftHandle) createPlayerWithPattern:continuous(0, 3, 1, 0.5f) error:nil];
    [q startAtTime:t1 error:nil];
    CHHapticParameterCurve *fade = [[CHHapticParameterCurve alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl
                                                                         controlPoints:@[ [[CHHapticParameterCurveControlPoint alloc] initWithRelativeTime:0 value:1],
                                                                                          [[CHHapticParameterCurveControlPoint alloc] initWithRelativeTime:1 value:0] ]
                                                                          relativeTime:0];
    [q scheduleParameterCurve:fade atTime:t1 + 1 error:nil];
    at(t1 + 0.5, &s, &w); CHECK(near(s, 1), "runtime curve not yet started: %f", s);
    at(t1 + 1.5, &s, &w); CHECK(near(s, 0.5), "runtime curve fades: %f", s);
    at(t1 + 2.5, &s, &w); CHECK(s < 0.02, "runtime curve reached zero: %f", s);
}

static void testEnvelope(void) {
    double t0 = window(), s, w;
    CHHapticEvent *e = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous
                                                    parameters:@[ [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:1],
                                                                  [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDAttackTime value:0.4f],
                                                                  [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDReleaseTime value:0.4f] ]
                                                  relativeTime:0 duration:2];
    [[engineFor(GCHapticsLocalityLeftHandle) createPlayerWithPattern:[[CHHapticPattern alloc] initWithEvents:@[ e ] parameters:@[] error:nil] error:nil] startAtTime:t0 error:nil];
    at(t0 + 0.2, &s, &w); CHECK(near(s, 0.5), "attack ramps in: %f", s);
    at(t0 + 1.0, &s, &w); CHECK(near(s, 1), "sustain: %f", s);
    at(t0 + 1.8, &s, &w); CHECK(near(s, 0.5), "release ramps out: %f", s);
}

static void testAdvanced(void) {
    double t0 = window(), s, w;
    id<CHHapticAdvancedPatternPlayer> loop = [engineFor(GCHapticsLocalityLeftHandle) createAdvancedPlayerWithPattern:continuous(0, 0.1, 1, 0.5f) error:nil];
    loop.loopEnabled = YES;
    loop.loopEnd = 0.2;
    [loop startAtTime:t0 error:nil];
    at(t0 + 10.05, &s, &w); CHECK(near(s, 1), "loop plays again: %f", s);
    at(t0 + 10.15, &s, &w); CHECK(s == 0, "loop gap: %f", s);
    [loop stopAtTime:t0 + 20 error:nil];

    double t1 = window();
    id<CHHapticAdvancedPatternPlayer> fast = [engineFor(GCHapticsLocalityLeftHandle) createAdvancedPlayerWithPattern:continuous(0, 1, 1, 0.5f) error:nil];
    fast.playbackRate = 2;
    [fast startAtTime:t1 error:nil];
    at(t1 + 0.45, &s, &w); CHECK(near(s, 1), "double speed, still inside: %f", s);
    at(t1 + 0.55, &s, &w); CHECK(s == 0, "double speed ends at half the time: %f", s);
}

static void testAHAPAndPauseRealTime(void) {
    NSDictionary *ahap = @{ @"Pattern": @[ @{ @"Event": @{ @"Time": @0, @"EventType": @"HapticContinuous", @"EventDuration": @0.3,
                                                          @"EventParameters": @[ @{ @"ParameterID": @"HapticIntensity", @"ParameterValue": @0.7 } ] } } ] };
    NSData *json = [NSJSONSerialization dataWithJSONObject:ahap options:0 error:nil];
    id engine = engineFor(GCHapticsLocalityLeftHandle);
    NSError *err = nil;
    BOOL ok = [engine playPatternFromData:json error:&err];
    CHECK(ok && !err, "AHAP data plays");
    double s, w;
    at(0, &s, &w);
    CHECK(s > 0.6, "AHAP pattern sounds right away: %f", s);
    [engine stopWithCompletionHandler:nil];
    usleep(30000);
    at(0, &s, &w);
    CHECK(s == 0, "engine stop silences its players: %f", s);

    id<CHHapticAdvancedPatternPlayer> p = [engine createAdvancedPlayerWithPattern:continuous(0, 10, 1, 0.5f) error:nil];
    [p startAtTime:0 error:nil];
    usleep(20000);
    [p pauseAtTime:0 error:nil];
    at(0, &s, &w); CHECK(s == 0, "paused player is silent: %f", s);
    [p resumeAtTime:0 error:nil];
    at(0, &s, &w); CHECK(near(s, 1), "resumed player plays: %f", s);
    [p cancelAndReturnError:nil];
    usleep(20000);
    at(0, &s, &w); CHECK(s == 0, "cancel silences: %f", s);
}

static void testCompletionHandlers(void) {
    id engine = engineFor(GCHapticsLocalityRightHandle);
    __block atomic_int playerDone = 0, engineDone = 0;
    id<CHHapticAdvancedPatternPlayer> p = [engine createAdvancedPlayerWithPattern:continuous(0, 0.05, 1, 0.5f) error:nil];
    p.completionHandler = ^(NSError *e) { atomic_fetch_add(&playerDone, 1); };
    [engine notifyWhenPlayersFinished:^CHHapticEngineFinishedAction(NSError *e) {
        atomic_fetch_add(&engineDone, 1);
        return CHHapticEngineFinishedActionLeaveEngineRunning;
    }];
    [p startAtTime:0 error:nil];
    for (int i = 0; i < 100 && (!playerDone || !engineDone); i++) usleep(10000);
    CHECK(playerDone == 1, "player completion called once: %d", playerDone);
    CHECK(engineDone == 1, "engine finished handler called once: %d", engineDone);
}

static void testRobustness(void) {
    id engine = engineFor(GCHapticsLocalityDefault);
    // Calls the bridge does not implement must not crash the game.
    [engine performSelector:@selector(playsAudioOnly)];
    [engine performSelector:NSSelectorFromString(@"someFutureMethod")];
    id haptics = [NSClassFromString(@"ZSHaptics") new];
    [haptics performSelector:NSSelectorFromString(@"anotherFutureMethod")];
    CHECK([[haptics supportedLocalities] containsObject:GCHapticsLocalityLeftHandle], "advertises both handles");
    CHHapticPattern *missing = nil;  // games do pass nil after a failed pattern init
    id nilPlayer = [engine createPlayerWithPattern:missing error:nil];
    CHECK(nilPlayer == nil, "nil pattern gives no player");

    CHECK(Shape(0) == 0, "silence stays silence");
    CHECK(Shape(NAN) == 0, "NaN is silence");
    CHECK(Shape(1) == 65535, "full is full: %u", Shape(1));
    CHECK(Shape(0.5) == (uint16_t)lrint((0.08 + 0.92 * 0.5) * 65535), "floor lifts weak levels: %u", Shape(0.5));
}

// Many game threads hammering the API while the mixer samples.
static void testConcurrency(void) {
    NSArray *engines = @[ engineFor(GCHapticsLocalityLeftHandle), engineFor(GCHapticsLocalityRightHandle), engineFor(GCHapticsLocalityDefault) ];
    __block atomic_bool stop = false;
    dispatch_group_t g = dispatch_group_create();
    for (int t = 0; t < 8; t++) {
        dispatch_group_async(g, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            @autoreleasepool {
                id engine = engines[t % 3];
                NSMutableArray *players = [NSMutableArray new];
                while (!atomic_load(&stop)) @autoreleasepool {
                    uint32_t r = arc4random_uniform(6);
                    if (r == 0 || players.count == 0) {
                        id p = [engine createAdvancedPlayerWithPattern:continuous(0, arc4random_uniform(2) ? 0.05 : GCHapticDurationInfinite, 1, 0.5f) error:nil];
                        [p startAtTime:0 error:nil];
                        [players addObject:p];
                    } else {
                        id<CHHapticAdvancedPatternPlayer> p = players[arc4random_uniform((uint32_t)players.count)];
                        CHHapticDynamicParameter *dp = [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:arc4random_uniform(100) / 100.f relativeTime:0];
                        switch (r) {
                            case 1: [p sendParameters:@[ dp ] atTime:0 error:nil]; break;
                            case 2: [p stopAtTime:0 error:nil]; [players removeObject:p]; break;
                            case 3: [p pauseAtTime:0 error:nil]; [p resumeAtTime:0 error:nil]; break;
                            case 4: p.playbackRate = 0.5f + arc4random_uniform(3); break;
                            default: [p seekToOffset:0.01 error:nil]; break;
                        }
                    }
                    if (players.count > 50) { for (id p in players) [p stopAtTime:0 error:nil]; [players removeAllObjects]; }
                }
                for (id p in players) [p stopAtTime:0 error:nil];
            }
        });
    }
    double s, w;
    for (int i = 0; i < 400; i++) { at(0, &s, &w); CHECK(s >= 0 && s <= 1 && w >= 0 && w <= 1, "levels stay in range: %f %f", s, w); usleep(2500); }
    atomic_store(&stop, true);
    dispatch_group_wait(g, DISPATCH_TIME_FOREVER);
    usleep(50000);
    at(0, &s, &w);
    CHECK(s == 0 && w == 0, "everything stopped is silent: %f %f", s, w);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        setenv("ZSTADIA_DRY_RUN", "1", 1);
        const char *path = argc > 1 ? argv[1] : "build/ZStadiaRumble.dylib";
        void *lib = dlopen(path, RTLD_NOW);
        if (!lib) { printf("cannot load %s: %s\n", path, dlerror()); return 2; }
        Levels = dlsym(lib, "ZStadiaDebugLevels");
        Shape = dlsym(lib, "ZStadiaDebugShape");
        Now = dlsym(lib, "ZStadiaDebugNow");
        Parked = dlsym(lib, "ZStadiaDebugParked");
        if (!Levels || !Shape || !Now || !Parked) { printf("debug entry points missing\n"); return 2; }
        testParking();
        testRouting();
        testTransient();
        testEndlessWithControl();
        testCurves();
        testEnvelope();
        testAdvanced();
        testAHAPAndPauseRealTime();
        testCompletionHandlers();
        testRobustness();
        testConcurrency();
        printf("%d checks, %d failed\n", checks, failures);
        return failures ? 1 : 0;
    }
}
