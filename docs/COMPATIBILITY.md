# Compatibility

Whether a game can rumble a Stadia Controller depends on how it reads controllers, not on where you bought it.

## By how the game reads controllers

| The game uses | Rumble | Notes |
| --- | --- | --- |
| Apple Game Controller framework with Core Haptics | Yes, through a Z Stadia launcher | `zstadia wrap` prints `OK uses Apple's Game Controller framework` |
| SDL 2.26 or newer | Usually already works | SDL ships its own Stadia driver. If the game does not rumble, wrap it: SDL can also go through the Game Controller framework |
| An older SDL | Through a launcher, when SDL reads the controller via the Game Controller framework | Try `wrap` |
| Its own HID code | No | The game never asks macOS for rumble |

## By store and launcher

| Source | Native Mac games | Notes |
| --- | --- | --- |
| GOG, through Heroic or GOG Galaxy | Yes | Data next to the app is linked automatically |
| Steam | Yes | The Steam client must be running. `wrap` writes `steam_appid.txt` so Steam does not start the original instead |
| Epic Games Store, through Heroic or Epic's launcher | Yes, if the game starts without its launcher | Some titles need sign-in arguments: pass them with `--arg` |
| Direct downloads | Yes | |
| Mac App Store | Experimental | The copy runs outside the sandbox: saves stored in the sandbox container, Game Center and iCloud may not be available to it |
| iPhone and iPad apps on Apple silicon | No | Encrypted by the App Store; they cannot be signed again |

Windows games in Heroic, CrossOver or Whisky follow a different path, described in [WINDOWS_GAMES.md](WINDOWS_GAMES.md).

## Verified

| Game or setup | Version | Result |
| --- | --- | --- |
| Cyberpunk 2077, macOS, GOG via Heroic | 2.3.1 | Rumble felt in game. The game requests the left and right handle engines from its launcher |
| End-to-end live test (`make live-test`) | macOS 27.2, Bluetooth LE | Haptics from the real `GCController`, both motors, acknowledged in 45 to 60 ms |
| Windows XInput test program in Heroic | Game Porting Toolkit 1.1, Wine 7.7, SDL 2.32.10 | Controller found in XInput slot 0; strong, weak and both motors |

Tried another game? Please open an issue or a pull request with the game, its version, the store, how the controller was connected and the relevant lines of `rumble.log` (`wrap --log`). Replace your home folder path with `~` before posting.

## Things that can stop a copy from running

- **Anti-cheat and integrity checks.** A game that verifies its own signature, or ships anti-cheat, may refuse to run from a re-signed copy. Online competitive games are the usual case.
- **Launcher-only games.** Titles that only start with a ticket from their store launcher need the right `--arg` values, or cannot run from a copy at all.
- **Intel-only games** run through Rosetta; the library is universal, so this works as long as Rosetta is installed.
