# Security

## What Z Stadia does on your Mac

- It reads the Stadia Controller's HID descriptor and writes its rumble report (report 5). It writes nothing else to the controller; in particular it never touches the controller's firmware interface.
- `zstadia wrap` copies a game app into a folder you choose, links the files the game keeps next to its app, removes the quarantine attribute from the copy and signs the copy on your Mac with an ad-hoc signature.
- A launcher starts that copy with `DYLD_INSERT_LIBRARIES` pointing to the rumble library inside the launcher.

## What it does not do

- No network access of any kind, no analytics, no update checks.
- No administrator password, no `sudo`.
- No change to System Integrity Protection, Gatekeeper, privacy settings or any other system setting.
- No kernel extension, system extension or driver.
- No change to the original game: its files and signature stay exactly as the publisher shipped them.

## The trade-off of a re-signed copy

The copy is signed without the hardened runtime, otherwise macOS would refuse to load the rumble library. The hardened runtime is what stops other code from being injected into an app. So the copy, while it runs, can be injected by any program running as your user, like any app built before the hardened runtime existed. This does not lower the protection of anything else: the original game, other apps and the system keep theirs. A program able to start the copy with its own `DYLD_INSERT_LIBRARIES` could already run its code as your user without it.

The copy also loses the publisher's entitlements. For a game outside the App Store this changes nothing visible; for an App Store game it means running outside the sandbox.

If you prefer not to keep a copy around, `zstadia unwrap` moves the launcher and the copy to the Trash.

## Reporting a vulnerability

Please report security problems privately through GitHub's "Report a vulnerability" button on the repository's Security tab, not in public issues. Include what you found, how to reproduce it and the macOS version.
