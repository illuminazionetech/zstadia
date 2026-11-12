# Troubleshooting

Start with `./build/zstadia doctor`. It checks every step and says which one fails.

## The controller

**`no Stadia controller connected`**
- Press the Stadia button: over Bluetooth the controller goes to sleep after some minutes without use.
- Over Bluetooth, the controller must be paired in System Settings > Bluetooth. To pair, hold the Stadia button and Y together until the light flashes orange.
- With a cable, use one that carries data; many charging cables do not.
- A controller that was never switched to Bluetooth mode works only with a cable. Google's switching tool is no longer online.

**`cannot open it: not permitted`**
Another app has taken the controller exclusively: Steam, an emulator or a remapping tool. Quit it and run the command again.

**`no rumble report`**
The controller is reporting an unexpected descriptor. Reconnect it; if it persists, open an issue with the output of `zstadia doctor`.

**The test runs but nothing vibrates**
- Charge the controller: with a very low battery the motors stay still.
- Try the other connection (cable or Bluetooth).
- Run `zstadia rumble 100 100 1000` while holding the controller firmly.

**Rumble is late or choppy over Bluetooth**
Each Bluetooth update is acknowledged after about 50 ms. Z Stadia always sends the newest level, so it never builds a backlog, but radio interference makes every update slower. Move closer to the Mac, away from USB 3 hubs and Wi-Fi routers, or use the cable.

**The motors keep spinning**
Run `zstadia stop`. The library stops the motors when the game exits and the launcher does it again after a crash, so this only happens if both were killed.

## The launcher

**It says it cannot find the game.** The game moved or was reinstalled. Run `zstadia wrap` again with the new path.

**macOS says the app is damaged or cannot be checked.** The game copy kept a quarantine flag. Run `zstadia wrap` again: it removes it.

**After a game update the launcher shows "Preparing..." for a few seconds.** That is the copy being refreshed. It happens once per update.

**The game starts, but without rumble.**
1. Make the launcher again with `--log`, play a moment that should rumble, then read `.zstadia/<Game>/rumble.log` next to the launcher.
2. No `haptics provided` line: the game never asked the Game Controller framework for the Stadia Controller's rumble. Check the game's vibration setting. If it is on, the game reads controllers another way and Z Stadia cannot help.
3. `haptics provided` but no `rumble starts`: the game created motors but played nothing yet. Play a moment that rumbles with other controllers.
4. `write failed` lines: the controller rejected commands; reconnect it.

**A Steam game opens Steam and starts the original.** Steam's app id was not found. Wrap again with `--steam-appid <id>`, the number in the game's Steam store address.

**A Mac App Store game starts without my saves.** The copy runs outside the App Store sandbox and looks for saves in another place. This is a known limit for App Store games.

**The game refuses to start from the copy.** Some games check their own signature or use anti-cheat. They cannot run from a copy.

## Windows games

See [WINDOWS_GAMES.md](WINDOWS_GAMES.md).

## Reporting a problem

Include the output of `zstadia doctor`, the game and its version, the store, how the controller was connected and, if you have it, `rumble.log`. Replace your home folder path with `~` before posting.
