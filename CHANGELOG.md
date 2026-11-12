# Changelog

## 1.0.0 (2026-11-12)

First release.

- Rumble library for native Mac games: provides Game Controller haptics for the Stadia Controller and renders Core Haptics (events, envelopes, dynamic parameters, curves, loops, playback rate, AHAP) into the controller's two motors.
- USB and Bluetooth LE, with reconnection when the controller switches link or wakes up. One report in flight per controller, always the newest levels.
- No work while nothing vibrates: the mixer sleeps with zero wake-ups.
- `zstadia` tool: `doctor`, `status`, `test`, `rumble`, `stop`, `wrap`, `unwrap`, `wine`, `icon`.
- Launchers that start a private copy of the game, refresh it after game updates and stop the motors when the game exits.
- Launcher icons: the game's icon with a Stadia Controller badge.
- Windows games: `zstadia wine` checks that a Wine build forwards rumble through SDL's Stadia driver; XInput test program included.
- Automated tests, sanitizer runs and a live test.
- Verified in game with Cyberpunk 2077 2.3.1 (macOS, GOG via Heroic).
