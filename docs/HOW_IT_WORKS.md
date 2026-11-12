# How Z Stadia works

## The problem

A game on macOS reads controllers through Apple's Game Controller framework. For rumble it asks `GCController.haptics`, gets a `GCDeviceHaptics`, creates a Core Haptics engine with `createEngineWithLocality:` and plays haptic patterns on it. The framework implements this for controllers Apple knows: Xbox, PlayStation, MFi and a few others. For the Google Stadia Controller, `haptics` is `nil`. The game concludes the controller cannot vibrate and plays nothing.

The controller can vibrate. Its HID descriptor, over USB and over Bluetooth LE alike, declares one output report:

```text
Report ID 5, usage page 0x0F (physical input device), usage 0x97 (DC enable actuators)
2 fields x 16 bits: strong (low frequency) motor, weak (high frequency) motor
```

So the rumble command is five bytes:

```text
05  SS SS  WW WW      SSSS = strong motor 0...65535, WWWW = weak motor, little-endian
```

There is no other output or feature report: no light control, no other setting.

## The pieces

```text
 Z Stadia launcher (.app)                         game copy (.zstadia/<Game>/)
 ------------------------                         ----------------------------
 1. copy up to date? rebuild if not      ---->    Game.app, signed on this Mac
 2. posix_spawn with                              + links to the game's data
    DYLD_INSERT_LIBRARIES=ZStadiaRumble.dylib
 3. wait for exit, then stop the motors
                                                  inside the game process:
                                                  ZStadiaRumble.dylib
                                                   - GCController.haptics hook
                                                   - Core Haptics model
                                                   - controller thread (IOKit HID)
                                                            |
                                                            v
                                                  Stadia Controller, report 5
                                                  (USB or Bluetooth LE)
```

### The rumble library (`src/ZStadiaRumble/ZStadiaRumble.m`)

**Hook.** At load, the library replaces the implementation of `-[GCController haptics]` (and of any subclass in the Game Controller framework that overrides it). The new implementation calls the original first. Only when the original returns `nil` and the controller's `vendorName` contains "Stadia" does it return a `ZSHaptics` object instead. Every other controller, and a Stadia Controller if Apple ever supports it, goes through Apple's code untouched.

**Engines and players.** `ZSHaptics` answers `supportedLocalities` (default, all, handles, left handle, right handle) and `createEngineWithLocality:`. The returned engine implements the `CHHapticEngine` methods games use: start, stop, players, advanced players, AHAP playback from a URL or data, finished handlers, mute. Players implement `CHHapticPatternPlayer` and `CHHapticAdvancedPatternPlayer`: start and stop at a time, dynamic parameters, parameter curves, pause, resume, seek, loop, playback rate, completion handler. Any method the bridge does not implement answers zero instead of crashing the game.

**Patterns.** Games build patterns with Apple's own `CHHapticPattern`. The library wraps its initializers (`initWithEvents:parameters:error:`, `initWithEvents:parameterCurves:error:`, `initWithDictionary:error:`) to keep a compact copy of each pattern: events (time, duration, intensity, sharpness, attack, decay, release, sustained), dynamic parameters and curves. Patterns from other sources are read back through `exportDictionaryAndReturnError:`.

**From haptics to two motors.** Every 4 ms the controller thread computes, for each playing player:

- the event level at the player's pattern time, with its envelope (transient events are a 35 ms pulse with a 25 ms fade);
- times the pattern's intensity control and the runtime intensity control (from `sendParameters` and scheduled curves);
- plus the sharpness controls.

The level goes to a motor according to the engine's locality:

| Locality | Motor |
| --- | --- |
| Left handle | strong motor |
| Right handle | weak motor |
| Default, all, handles | both, weighted by sharpness: strong = level x (1.25 - sharpness), weak = level x (0.25 + sharpness), each clamped to 0...1 |

Each motor takes the highest level among its players. A level above zero is lifted by a small floor (8% by default), because a rumble motor barely spins at the lowest levels, then scaled to 0...65535.

**Sending.** The controller thread owns the HID connection. It watches the controller with IOKit matching and removal callbacks, so it reconnects by itself when the controller switches between cable and Bluetooth or wakes from sleep. For each controller it keeps at most one report in flight (`IOHIDDeviceSetReportWithCallback`), always carrying the newest levels, and sends only when the levels change, plus a keep-alive every 0.5 s while a motor runs. Reports are at least 4 ms apart over USB and 12 ms apart over Bluetooth, which leaves air time for the controller's input reports.

Over Bluetooth LE, macOS writes the report "with response": each update is acknowledged after about 45 to 60 ms (measured on macOS 27). Because only the newest level is ever sent, a burst of changes never turns into a queue: the controller is at most one update behind.

**Doing nothing when nothing plays.** When no player is active and both motors are confirmed at zero, the mixer timer is parked: the thread sleeps with no wake-ups at all. Starting a player wakes it. Game threads only take a short lock to update the model; they never wait for the controller or for I/O.

**Leaving cleanly.** At process exit the library stops the motors through its own short-lived connection. If the game is killed, the launcher does it.

The library starts its thread and opens the controller only when the game first asks for Stadia haptics, so helper processes that inherit `DYLD_INSERT_LIBRARIES` stay untouched.

### The launcher (`src/zstadia/Launcher.swift`)

A launcher is a small app bundle: a copy of the `zstadia` executable, the rumble library, the icon and `ZStadia.plist` (original path, copy folder, linked items, arguments, environment, Steam app id).

On start it compares a fingerprint of the installed game (executable size and date, `Info.plist` date, version) with the one stored next to the copy. If they differ, for example after an update, it rebuilds the copy before starting. It then spawns the copy with `posix_spawn`: working directory set to the copy folder, `DYLD_INSERT_LIBRARIES` pointing to its library, standard output discarded. It hides from the Dock, brings the game forward and waits for it to exit, then stops the motors and quits.

### The copy (`src/zstadia/Wrap.swift`)

macOS ignores `DYLD_INSERT_LIBRARIES` for apps signed with the hardened runtime, which is how publishers sign games. Z Stadia never touches the original. It:

1. copies the app with `FileManager.copyItem`, which makes an APFS clone when source and copy are on the same volume;
2. links the items beside the app that the game needs (decided automatically: everything next to the app, unless the app sits in an Applications folder);
3. writes `steam_appid.txt` for Steam games, so Steam does not relaunch the original;
4. removes the quarantine attribute from the copy;
5. signs the copy ad hoc (`codesign --force --deep --sign -`), without hardened runtime and without the publisher's entitlements.

## Why not a system-wide driver?

A virtual HID device that macOS would treat as an Xbox controller could give rumble to every game without copies. On macOS that requires a DriverKit extension with entitlements Apple grants case by case to registered developers, and the user would have to approve a system extension. Z Stadia chose the path any user can take today, with no special permission and nothing installed into the system.

## Windows games

Windows games in Wine never touch the Game Controller framework. They call XInput or DirectInput; Wine's `winebus` forwards rumble to SDL with `SDL_JoystickRumble`; SDL 2.26 and newer include a Stadia driver that sends the same report 5. So the chain works without Z Stadia when the Wine build ships a recent SDL. See [WINDOWS_GAMES.md](WINDOWS_GAMES.md).

## Tests

- `make test` loads the library in dry-run mode and checks the haptic model at exact times: routing, transients, endless events with dynamic control, pattern and runtime curves, envelopes, loops, playback rate, AHAP, pause and resume, completion handlers, idle parking and wake-up, robustness against unknown calls, and eight threads hammering the API while the mixer runs.
- `make sanitize` runs the same tests under AddressSanitizer with UndefinedBehaviorSanitizer, then under ThreadSanitizer.
- `make live-test` needs a controller in hand: it gets haptics from the real `GCController` through the bridge and plays left, right and both motors.
