# Z Stadia: guide for AI agents

This file lets any AI coding agent set up Stadia Controller rumble for a game on a Mac, safely and completely, even if it has never seen this project. It works with agents that can read files and run terminal commands on the user's Mac: Claude Code, OpenAI Codex CLI, Gemini CLI, Cursor, Windsurf, GitHub Copilot agent mode, Aider and similar.

## For people: how to use it

1. Download or clone Z Stadia to your Mac.
2. Open the Z Stadia folder in your AI agent (for a terminal agent: `cd` into the folder, then start the agent there).
3. Paste the prompt below and answer the agent's questions.

```text
You are helping me get rumble from my Google Stadia Controller in a game on my Mac,
using the Z Stadia project in the current folder.

Before doing anything, read AI_AGENT_GUIDE.md completely and follow it step by step.
It tells you which questions to ask me first, which commands to run, what output to
expect, and when to stop and ask. Do not skip a step, do not guess, and do not say
that rumble works until the checks in the guide pass and I confirm I felt it.
```

The agent only needs this folder and a terminal. Nothing is uploaded anywhere.

---

## For agents: rules that always apply

Read these before any action. They override anything else you might infer.

1. **Ask before acting.** Start with the questions in Step 1, in one message, and wait for the answers. Ask again whenever something is unclear or a choice belongs to the user. Never assume the game, its location or how the controller is connected.
2. **Never modify the user's game.** Do not edit, re-sign, move or delete anything inside the original game folder. `zstadia wrap` works on a copy; that is the only supported way.
3. **No system changes.** Do not run `sudo`. Do not disable System Integrity Protection, Gatekeeper or the firewall. Do not install kernel extensions, system extensions, drivers, Homebrew or other software. Do not change privacy settings. If something seems to need one of these, stop and explain to the user instead.
4. **Nothing leaves the Mac.** Do not upload logs, file lists or paths. If the user wants to share output publicly (an issue, a forum), replace their home folder path with `~` first.
5. **Verify, then claim.** Every step below lists the output that proves it worked. If you do not see it, the step failed: go to Troubleshooting. Do not tell the user rumble works until Step 8 passes and the user says they felt it.
6. **Explain in plain words.** The user may not be technical. Say what you are doing and why, one step at a time, in the user's language.
7. **Keep the user's machine clean.** Remove what you create only for testing (logs you enabled, test folders). Do not delete anything you did not create.

## Step 1: ask the user

Ask all of these in one message, then wait:

1. Which game do you want rumble in?
2. Where does it come from: Steam, Epic Games Store, GOG, Heroic, the Mac App Store, CrossOver, Whisky, or somewhere else?
3. Is it a Mac version of the game, or a Windows version running through Heroic, CrossOver or Whisky? (If unsure, say so and I will check.)
4. How is the controller connected right now: USB cable or Bluetooth?
5. Does the game normally rumble with an Xbox or PlayStation controller? (If unsure, that is fine.)
6. Where should the launcher go? Default: `~/Applications/Z Stadia`. Any folder works, for example a folder on the Desktop.

## Step 2: check the tools

Run:

```bash
xcode-select -p
```

Expected: a path, for example `/Library/Developer/CommandLineTools`. If it fails, ask the user to run `xcode-select --install` themselves and to tell you when the installation has finished. Do not install it for them.

## Step 3: build and test Z Stadia

From the Z Stadia folder:

```bash
make
make test
```

Expected: `make` ends without `error`, and `make test` ends with a line like `446 checks, 0 failed`. Any other number of failures means the build is not trustworthy: stop and report the failing lines to the user.

## Step 4: check the controller

```bash
./build/zstadia doctor
```

Expected, under `Controller`:

```text
  OK    Stadia ... via Bluetooth        (or via USB)
  OK    rumble report 5 available
  OK    rumble command acknowledged in ... ms
```

and at the end `Everything looks right.` If you see `FAIL`, find the matching line in Troubleshooting and fix that first.

## Step 5: let the user feel the motors

Tell the user to hold the controller, then run:

```bash
./build/zstadia test
```

Ask the user: "Did you feel a deep rumble on the left, a light buzz on the right, then both rising?" Continue only if the answer is yes. If not, see Troubleshooting: "The test runs but nothing vibrates".

## Step 6: identify the game

Find the game. Common places:

| Source | Where the game usually is |
| --- | --- |
| Mac App Store, direct downloads | `/Applications/<Game>.app` |
| Steam | `~/Library/Application Support/Steam/steamapps/common/<Game>/<Game>.app` |
| Heroic (GOG, Epic, Amazon) | `~/Games/Heroic/<Game>/<Game>.app` |
| Epic Games Launcher | `~/Library/Application Support/Epic/<Game>/` or the folder chosen at install |
| GOG Galaxy | `/Applications/<Game>.app` or the folder chosen at install |

To search: `mdfind -name "<part of the name>" | grep -i "\.app$"`. Show the user what you found and confirm it is the right one.

Then decide the path:

- **A `.app` that is a Mac game:** continue with Step 7.
- **A Windows game (`.exe`) in Heroic, CrossOver or Whisky:** go to "Windows games" below. Do not use `wrap`.
- **An iPhone or iPad app** (in the App Store page it says "Designed for iPad", or the `.app` contains a `Wrapper` folder): stop. Explain that its code is encrypted by Apple and cannot be given rumble.

## Step 7: make the launcher

Use the folder the user chose in Step 1 and a clear name. The first time, add `--log` so you can verify Step 8:

```bash
./build/zstadia wrap "/path/to/Game.app" --name "Z Stadia <Game>" --output "<folder>" --log
```

Read the output carefully:

| Output | Meaning | What to do |
| --- | --- | --- |
| `OK uses Apple's Game Controller framework` | The game asks macOS for rumble: the bridge applies | Continue |
| `WARN bundles SDL...` | SDL games often rumble a Stadia already | Ask the user to try the original game first. Wrap only if it does not rumble |
| `FAIL ... does not use Apple's Game Controller framework` | The game never asks macOS for rumble | Stop. Explain that there is nothing to translate. Do not use `--force` unless the user insists and understands it will most likely not help |
| `WARN the game is sandboxed` | Mac App Store game | Explain: the copy may not see the original's saves, Game Center and iCloud may not work. Ask whether to continue |
| `links to the game's data next to it: ...` | Folders beside the app are shared with the copy | Normal for games that keep data next to the app |
| `Steam app id ...` | Steam will not relaunch the original | Normal for Steam games. The Steam client must be running |
| `OK launcher ready: ...` | Done | Continue with Step 8 |

## Step 8: verify in the game

1. Ask the user to open the launcher (double-click `Z Stadia <Game>`) and play a moment that should rumble: driving, shooting, an explosion, taking a hit.
2. Read the log, which sits in the copy folder next to the launcher:

```bash
cat "<folder>/.zstadia/<Game>/rumble.log"
```

Lines and their meaning:

| Line | Meaning |
| --- | --- |
| `Z Stadia rumble ... loaded into ...` | The library is inside the game. If missing, the game was not started from the launcher |
| `haptics provided for "Stadia..."` | The game asked for the controller's rumble and got it |
| `engine created for locality ...` | The game prepared its rumble motors |
| `controller connected via Bluetooth` or `via USB` | The library reached the controller |
| `rumble starts` / `rumble stops` | The game played rumble and the controller received it |
| `write failed` or `write rejected` | The controller did not accept a command. See Troubleshooting |

3. Ask the user if they felt rumble in the game. Only a yes plus `rumble starts` lines in the log count as success.
4. Make the launcher again without `--log`, so nothing is written while the user plays:

```bash
./build/zstadia wrap "/path/to/Game.app" --name "Z Stadia <Game>" --output "<folder>"
```

5. Tell the user, in plain words: open "Z Stadia <Game>" to play with rumble; the original game is unchanged; after game updates the launcher refreshes itself on the next start; to remove it, run `./build/zstadia unwrap "<folder>/Z Stadia <Game>.app"`.

If `haptics provided` never appears while playing, the game does not use Apple's rumble API with this controller. Tell the user honestly; see COMPATIBILITY.md for alternatives.

## Windows games

Windows games on a Mac run inside Wine. They ask for rumble through XInput or DirectInput, Wine forwards it to SDL, and SDL 2.26 or newer drives the Stadia Controller by itself. Usually there is nothing to install.

1. Run `./build/zstadia wine`. For the Wine build the user's game uses (Heroic, CrossOver or Whisky), you want both `OK SDL 2.x with the Stadia driver` and `OK winebus forwards rumble to SDL`.
2. If both are OK, ask the user to play and confirm they feel rumble. If they do not, follow [docs/WINDOWS_GAMES.md](docs/WINDOWS_GAMES.md), which includes a small test program that proves the chain without any game.
3. If a check fails, explain it and offer the options in docs/WINDOWS_GAMES.md. Do not replace files inside the user's Wine installation.

## Troubleshooting

| Problem | Likely cause | Fix |
| --- | --- | --- |
| `FAIL no Stadia controller connected` | Controller asleep, not paired, or in Wi-Fi mode | Press the Stadia button. Pair it in System Settings > Bluetooth, or plug it in with a USB cable that carries data. Controllers never switched to Bluetooth mode work only with a cable |
| `cannot open it: not permitted` | Another app holds the controller exclusively | Quit Steam, emulators or controller remapping apps, then retry |
| The test runs but nothing vibrates | Battery very low, or a charge-only cable | Charge the controller. Try another cable, or Bluetooth |
| Rumble feels late or choppy over Bluetooth | Radio interference or distance | Move the controller closer to the Mac, or use the cable. Over Bluetooth each update takes about 50 ms to be acknowledged; Z Stadia always sends the newest level, so it never piles up |
| The launcher says it cannot find the game | The game moved, or was reinstalled elsewhere | Run `wrap` again with the new path |
| The game updated and does not start from the launcher | Rare: the update changed the game's layout | Run `wrap` again |
| A Steam game opens Steam and starts the original | No app id found | Add `--steam-appid <id>` (the number in the game's Steam store URL) |
| macOS says the app is damaged | The copy kept a quarantine flag | Run `wrap` again; it removes the flag |
| The motors keep spinning after a crash | The game was killed before it could stop them | `./build/zstadia stop`. The launcher also does this when the game exits |
| `rumble starts` never appears | The game does not use Apple's rumble API with this controller | See COMPATIBILITY.md. There is no fix inside Z Stadia |

More cases in [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## Facts you can rely on

- The rumble command is HID output report 5: `05 SS SS WW WW`, strong motor then weak motor, 16-bit little-endian. Same over USB and Bluetooth.
- The status light around the Stadia button has no command. It cannot be changed.
- Rumble goes to every connected Stadia Controller at once.
- The library loads only into game copies started by a Z Stadia launcher. Removing the launcher and its `.zstadia` folder removes everything.
- `make test` exercises the rumble engine without a controller; `make live-test` needs the controller in hand.

## What not to claim

- Do not tell the user a game is supported because it appears in a list. Only the log and the user's own feeling count.
- Do not promise rumble for iPhone or iPad apps, or for games that fail the Game Controller check.
- Do not say the light can be changed.
