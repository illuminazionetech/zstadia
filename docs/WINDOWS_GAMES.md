# Windows games on a Mac

Windows games run on a Mac inside Wine, through Heroic (with Apple's Game Porting Toolkit), CrossOver or Whisky. They ask for rumble with XInput or DirectInput. Wine's `winebus` passes that to SDL with `SDL_JoystickRumble`, and SDL 2.26 and newer include a Stadia driver that sends the controller's rumble report directly. When the Wine build ships such an SDL, Windows games rumble a Stadia Controller with no help from Z Stadia.

## Check your Wine builds

```bash
./build/zstadia wine
```

It looks for Heroic's toolkits and Wine builds, CrossOver and Whisky. For each one you want:

```text
  OK    SDL 2.32.10 with the Stadia driver
  OK    winebus forwards rumble to SDL
```

For a Wine build elsewhere, pass its folder: `./build/zstadia wine "/path/to/wine"`.

## Prove the chain without any game

`tests/windows/xinput_rumble.cs` is a tiny Windows program that finds the controller through XInput and rumbles each motor. Wine Mono, which comes with most Wine builds, includes a C# compiler, so nothing needs to be downloaded.

The commands below use Heroic's Game Porting Toolkit; adjust `WINE` for another build. They use a throw-away Wine prefix in a temporary folder, so your games' prefixes are not touched.

```bash
WINE="$HOME/Library/Application Support/heroic/tools/game-porting-toolkit/Game-Porting-Toolkit-latest/Contents/Resources/wine"
WORK="$(mktemp -d)"
export WINEPREFIX="$WORK/prefix" WINEDEBUG=-all
cp tests/windows/xinput_rumble.cs "$WORK/"
cd "$WORK"
"$WINE/bin/wine64" wineboot -i
MCS="$(find "$WINE/share/wine/mono" -name mcs.exe | head -1)"
"$WINE/bin/wine64" "$MCS" -out:xinput_rumble.exe xinput_rumble.cs
"$WINE/bin/wine64" xinput_rumble.exe
"$WINE/bin/wineserver" -k
```

Expected output, with the controller rumbling left, right, then both:

```text
XInput slot 0: controller connected
Rumble on slot 0: left (strong), right (weak), both
  XInputSetState(0, left 65535, right 0) = OK
  ...
done
```

Delete the temporary folder afterwards: `rm -rf "$WORK"`.

## When it does not work

| What you see | Cause | What to do |
| --- | --- | --- |
| `FAIL no SDL2 inside` | This Wine reads controllers through IOKit only, which does not rumble | Use another Wine build that ships SDL, for example Heroic's Game Porting Toolkit |
| `FAIL SDL ... has no Stadia driver` | SDL older than 2.26 | Use a newer Wine build. Replacing files inside a Wine installation is possible but unsupported and undone by its updates |
| `XInput slot 0: empty` | Wine does not see the controller | Connect the controller before starting the game. Quit apps that may hold it exclusively |
| The test rumbles but a game does not | The game uses an API Wine does not map to rumble, or the game's own setting is off | Check the game's vibration setting. Try the game with an Xbox controller to see whether it rumbles at all under Wine |

## Why `zstadia wrap` is not used here

Wine's own executable is not a game app, and the rumble never passes through Apple's Game Controller framework on this path. Injecting the library would change nothing, so `wrap` is meant for native Mac games only.
