# Contributing

Thank you for helping more Stadia Controllers rumble.

## Build and test

```bash
make            # build/ZStadiaRumble.dylib and build/zstadia (universal: arm64 + x86_64)
make test       # haptic model tests, no controller needed
make sanitize   # the same tests under AddressSanitizer + UBSan, then ThreadSanitizer
make live-test  # with a controller in hand: real GCController, both motors
```

A change is ready when `make test` and `make sanitize` report `0 failed` and, for anything touching the controller path, `make live-test` was felt on the controller over both USB and Bluetooth.

## Code

- `src/ZStadiaRumble/ZStadiaRumble.m`: the library injected into games. Objective-C with ARC, no dependencies beyond Apple frameworks.
- `src/zstadia/*.swift`: the command-line tool and the launchers. Swift, Apple frameworks only.
- `tests/`: automated tests, the live test and the Windows XInput test program.

Guidelines:

- The library runs inside games that need every bit of the machine. Keep the game's threads free: no I/O, no waiting, only a short lock. No work at all while nothing vibrates.
- Never crash the host game. Unknown calls answer zero; inputs from the game are checked.
- Comments are short and say why, not what.
- No third-party code or downloads at build time, no network code, no telemetry.
- Never add game files, icons or other copyrighted assets to the repository.

## Sending a change

1. Fork the repository and create a branch from `main`.
2. Make your change, with tests when it touches the rumble engine.
3. Open a pull request and fill in the template. The CI builds both architectures and runs `make test` and `make sanitize` on macOS; it must be green.
4. Pull requests are squash-merged into `main`, which only accepts changes through pull requests.

Please follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Reporting a game

Open an issue with the game, its version, the store, how the controller was connected, the output of `zstadia doctor` and the relevant part of `rumble.log` (`wrap --log`). Replace your home folder path with `~`.

## License

By contributing you agree that your work is licensed under the GNU General Public License, version 3 or later.
