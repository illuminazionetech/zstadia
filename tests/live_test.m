// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Z Stadia contributors
//
// End-to-end check with a real controller: loads the rumble library like a game
// would, gets haptics from Apple's GCController (through the bridge) and plays
// left, right, then both motors rising. Hold the controller while it runs.
//
//   make live-test

#import <Foundation/Foundation.h>
#import <CoreHaptics/CoreHaptics.h>
#import <GameController/GameController.h>
#include <dlfcn.h>

static CHHapticPattern *endless(void) {
    CHHapticEvent *e = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous
                                                    parameters:@[ [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:1] ]
                                                  relativeTime:0 duration:GCHapticDurationInfinite];
    return [[CHHapticPattern alloc] initWithEvents:@[ e ] parameters:@[] error:nil];
}

static void level(id<CHHapticPatternPlayer> p, float v) {
    [p sendParameters:@[ [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:v relativeTime:0] ]
               atTime:CHHapticTimeImmediate error:nil];
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2 || !dlopen(argv[1], RTLD_NOW)) { printf("usage: live_test path/to/ZStadiaRumble.dylib\n"); return 2; }
        GCController *stadia = nil;
        for (int i = 0; i < 60 && !stadia; i++) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            for (GCController *c in GCController.controllers)
                if ([c.vendorName rangeOfString:@"stadia" options:NSCaseInsensitiveSearch].location != NSNotFound) stadia = c;
        }
        if (!stadia) { printf("FAIL no Stadia controller visible to the Game Controller framework\n"); return 1; }
        id haptics = stadia.haptics;
        printf("controller: %s, haptics object: %s\n", stadia.vendorName.UTF8String, haptics ? object_getClassName(haptics) : "nil");
        if (!haptics) { printf("FAIL the bridge did not provide haptics\n"); return 1; }

        CHHapticEngine *left = [haptics createEngineWithLocality:GCHapticsLocalityLeftHandle];
        CHHapticEngine *right = [haptics createEngineWithLocality:GCHapticsLocalityRightHandle];
        [left startAndReturnError:nil];
        [right startAndReturnError:nil];
        id<CHHapticPatternPlayer> l = [left createPlayerWithPattern:endless() error:nil];
        id<CHHapticPatternPlayer> r = [right createPlayerWithPattern:endless() error:nil];
        printf("playing: strong motor, weak motor, then both rising\n");
        [l startAtTime:0 error:nil];  usleep(500000); [l stopAtTime:0 error:nil]; usleep(350000);
        [r startAtTime:0 error:nil];  usleep(500000); [r stopAtTime:0 error:nil]; usleep(350000);
        l = [left createPlayerWithPattern:endless() error:nil];
        r = [right createPlayerWithPattern:endless() error:nil];
        level(l, 0); level(r, 0);
        [l startAtTime:0 error:nil]; [r startAtTime:0 error:nil];
        for (int i = 0; i <= 50; i++) { level(l, i / 50.f); level(r, i / 50.f); usleep(20000); }
        usleep(200000);
        [left stopWithCompletionHandler:nil];
        [right stopWithCompletionHandler:nil];
        usleep(300000);
        printf("done\n");
    }
    return 0;
}
