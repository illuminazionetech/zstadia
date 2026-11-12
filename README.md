# Z Stadia

**Rumble for the Google Stadia Controller in Mac games.**

[![CI](https://github.com/illuminazionetech/zstadia/actions/workflows/ci.yml/badge.svg)](https://github.com/illuminazionetech/zstadia/actions/workflows/ci.yml)
[![License: GPL v3+](https://img.shields.io/badge/license-GPL--3.0--or--later-blue.svg)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000.svg?logo=apple)](#requirements)
[![Apple silicon and Intel](https://img.shields.io/badge/Apple%20silicon%20%7C%20Intel-universal-555555.svg)](#requirements)

Stadia is gone, but its controller is still one of the best gamepads around, and in Bluetooth mode it pairs with any Mac. Games see it, buttons work, sticks work. One thing is missing: it never vibrates. Apple's Game Controller framework only gives vibration to Xbox, PlayStation and MFi controllers, so for the Stadia Controller a game simply gets "no rumble here".

Z Stadia gives the rumble back. It speaks to the controller directly, over USB or Bluetooth, and translates the vibration a game plays into the controller's two motors: the heavy one in the left grip and the light one in the right grip.

- **Real rumble, both motors.** Left and right, soft to full, short taps and long rumbles, as the game designed them.
- **USB and Bluetooth.** Plug in, unplug, switch while you play: Z Stadia follows the controller.
- **Your game stays untouched.** Z Stadia starts a private copy of the game. The original, its launcher and its updates are never modified.
- **Updates take care of themselves.** After a game update, the launcher notices on its next start and refreshes its copy in a few seconds.
- **Built for heavy games.** Nothing runs while nothing vibrates. While it does, the work is a few multiplications every 4 ms on a thread of its own. The game never waits for Z Stadia.
- **Private.** No network, no telemetry, no admin rights, no system settings changed.

## What works

| Kind of game | Rumble with a Stadia Controller | How |
| --- | --- | --- |
| Native Mac games that read controllers through Apple's Game Controller framework | Yes | `zstadia wrap` makes a launcher for the game |
| Windows games in Wine: Heroic with Game Porting Toolkit, CrossOver, Whisky | Yes, out of the box, when the Wine build ships SDL 2.26 or newer | Nothing to install. `zstadia wine` checks your Wine builds |
| Native Mac games that bundle SDL 2.26 or newer | Usually already, through SDL's own Stadia driver | Try without Z Stadia first, wrap only if needed |
| Mac App Store games | Experimental | The copy runs outside the App Store sandbox, so saves, Game Center and iCloud may not follow |
| iPhone and iPad apps running on the Mac | No | Their code is encrypted by the App Store and cannot be signed again |
| Games that read controllers with their own drivers | No | They never ask macOS for rumble, so there is nothing to translate |

Verified so far (macOS 27.2, Apple silicon):

- **Cyberpunk 2077 2.3.1 (macOS, GOG via Heroic):** rumbles in game. Started from its Z Stadia launcher, the game asks for both motors and the player feels them while playing. The rumble path is also verified end to end with a live test over Bluetooth (left motor, right motor, both rising).
- **Windows games in Heroic (Game Porting Toolkit 1.1, Wine 7.7, SDL 2.32.10):** an XInput test program finds the controller and rumbles it, motor by motor.

More detail in [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md).

## Requirements

- macOS 14 Sonoma or newer, on Apple silicon or Intel.
- Xcode Command Line Tools, to build: `xcode-select --install`.
- A Stadia Controller connected with a USB cable, or over Bluetooth if it was switched to Bluetooth mode while Google's tool was online.

## Quick start

```bash
git clone https://github.com/illuminazionetech/zstadia.git
cd zstadia
make
```

Check that everything is in place, then feel the motors:

```bash
./build/zstadia doctor
./build/zstadia test
```

Make a launcher for a game:

```bash
./build/zstadia wrap "/path/to/Game.app"
```

Open the new launcher from `~/Applications/Z Stadia`. That's it: play with rumble.

For example, Cyberpunk 2077 installed by Heroic:

```bash
./build/zstadia wrap "$HOME/Games/Heroic/Cyberpunk 2077/Cyberpunk2077.app" --name "Z Stadia Cyberpunk"
```

To use `zstadia` from anywhere, install it with `make install` (it goes to `~/.local/bin`).

## Commands

| Command | What it does |
| --- | --- |
| `zstadia doctor` | Checks macOS, the controller, its link (USB or Bluetooth), the rumble command and how games see the controller |
| `zstadia test` | Runs the strong motor, the weak motor, then both rising. Hold the controller |
| `zstadia rumble <strong> <weak> [ms]` | Runs the motors at levels from 0 to 100 |
| `zstadia stop` | Stops the motors |
| `zstadia wrap <Game.app>` | Makes a launcher that starts the game with rumble |
| `zstadia unwrap <Launcher.app>` | Moves a launcher and its game copy to the Trash |
| `zstadia wine [<folder>]` | Checks Wine builds for Windows games |
| `zstadia icon <Game.app> <out.png>` | Previews the launcher icon |

`zstadia help` lists every option of `wrap`.

## How a launcher works

`zstadia wrap` creates two things in the output folder:

- **`<Name>.app`**, the launcher, with the game's icon and a Stadia Controller badge.
- **`.zstadia/<Game>/`**, a private copy of the game app. On APFS it is a clone: it costs disk space only for the files that the local signature rewrites. Folders the game keeps next to its app (Cyberpunk keeps 65 GB there) are linked, not copied.

When you open the launcher it:

1. checks that the copy matches the installed game and rebuilds it if the game was updated;
2. starts the copy with the rumble library;
3. leaves the Dock to the game and waits, using no CPU;
4. stops the motors when the game quits, even if it crashed.

The publisher's signature forbids loading extra libraries, so the copy is signed again on your Mac. The original keeps its signature. Details in [docs/HOW_IT_WORKS.md](docs/HOW_IT_WORKS.md).

## Tuning

Pass settings to the game when you wrap it, for example `--env ZSTADIA_GAIN=1.3`.

| Variable | Default | Effect |
| --- | --- | --- |
| `ZSTADIA_GAIN` | `1.0` | Multiplies every level (0 to 4) |
| `ZSTADIA_FLOOR` | `0.08` | Lowest level of a running motor, so faint effects are still felt (0 to 0.6) |
| `ZSTADIA_SWAP_MOTORS` | off | `1` exchanges the two motors |
| `ZSTADIA_MATCH` | | Another controller name to treat as a Stadia Controller |
| `ZSTADIA_LOG` | off | Path of a log file. `wrap --log` sets it for you |
| `ZSTADIA_DISABLE` | off | `1` loads the library but leaves the game as it was |

## Limits worth knowing

- All connected Stadia Controllers receive the same rumble. Local multiplayer with two Stadia Controllers works, but rumble is shared.
- The status light around the Stadia button cannot be changed: the controller offers no command for it.
- Games that check their own code signature, or use anti-cheat, may refuse to run from a copy.
- Steam games restart through Steam unless `steam_appid.txt` is present. `wrap` writes it when it finds the Steam app id.
- Epic Games Store titles that require their launcher's sign-in arguments need them passed with `--arg`.

## Privacy and security

Z Stadia sends nothing anywhere: no network code, no analytics. It needs no administrator password, does not touch System Integrity Protection, installs no driver or system extension and changes no system setting. The rumble library loads only into the game copies that its launchers start. See [SECURITY.md](SECURITY.md) for the full picture.

## Uninstall

```bash
./build/zstadia unwrap "$HOME/Applications/Z Stadia/<Name>.app"
make uninstall
```

`unwrap` moves the launcher and its game copy to the Trash. Your game is untouched.

## Using an AI assistant

Z Stadia is designed to be set up by an AI coding agent too: Claude Code, OpenAI Codex, Gemini CLI, Cursor, GitHub Copilot and others. [AI_AGENT_GUIDE.md](AI_AGENT_GUIDE.md) holds a ready prompt and a step-by-step procedure, with the questions the agent must ask you first and the checks it must pass before saying it works.

## Documentation

- [docs/HOW_IT_WORKS.md](docs/HOW_IT_WORKS.md): architecture, rumble protocol, timing.
- [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md): stores, launchers and engines.
- [docs/WINDOWS_GAMES.md](docs/WINDOWS_GAMES.md): Windows games in Wine.
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md): when something does not work.
- [CONTRIBUTING.md](CONTRIBUTING.md): building, testing, sending changes.

## Community

- Questions and ideas: [Discussions](https://github.com/illuminazionetech/zstadia/discussions).
- Tried a game? Share a [game report](https://github.com/illuminazionetech/zstadia/issues/new?template=game_report.yml), whatever the result: every report grows the compatibility list.
- Found a bug? Open a [bug report](https://github.com/illuminazionetech/zstadia/issues/new?template=bug_report.yml).
- Want to help? Start with [CONTRIBUTING.md](CONTRIBUTING.md). Everyone is welcome under our [Code of Conduct](CODE_OF_CONDUCT.md).

If Z Stadia brought your controller back to life, give the repository a star: it is how other Stadia owners find it.

## License

Z Stadia is free software under the GNU General Public License, version 3 or later. See [LICENSE](LICENSE).

Z Stadia is an independent project, not affiliated with or endorsed by Google. Stadia is a trademark of Google LLC. Game names belong to their owners.
