// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Z Stadia contributors
//
// Windows games on a Mac run inside Wine (Heroic with Game Porting Toolkit,
// CrossOver, Whisky). They ask for rumble through XInput or DirectInput; Wine's
// winebus turns that into SDL_JoystickRumble, and SDL 2.26+ has its own Stadia
// driver that sends the same HID report 5. So no injection is needed there: what
// matters is that the Wine build ships a recent enough SDL. `zstadia wine`
// checks exactly that.

import Foundation

struct WineBuild {
    let label: String
    let root: URL
}

func knownWineBuilds() -> [WineBuild] {
    let fm = FileManager.default
    let home = URL(fileURLWithPath: NSHomeDirectory())
    var found: [WineBuild] = []
    func add(_ label: String, _ url: URL) { if fileExists(url, directory: true) { found.append(WineBuild(label: label, root: url)) } }
    let heroic = home.appendingPathComponent("Library/Application Support/heroic/tools")
    for kind in ["game-porting-toolkit", "wine"] {
        let dir = heroic.appendingPathComponent(kind)
        for name in (try? fm.contentsOfDirectory(atPath: dir.path))?.sorted() ?? [] where !name.hasPrefix(".") {
            add("Heroic \(name)", dir.appendingPathComponent(name))
        }
    }
    add("CrossOver", URL(fileURLWithPath: "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"))
    add("Whisky", home.appendingPathComponent("Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine"))
    return found
}

private func find(_ name: String, under root: URL, maxDepth: Int = 7) -> URL? {
    guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsPackageDescendants]) else { return nil }
    for case let url as URL in e {
        if e.level > maxDepth { e.skipDescendants(); continue }
        if url.lastPathComponent == name { return url }
    }
    return nil
}

/// Current version of a dylib, from its LC_ID_DYLIB load command.
func dylibVersion(_ url: URL) -> (Int, Int, Int)? {
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count > 64 else { return nil }
    func u32(_ o: Int, big: Bool) -> UInt32 {
        guard o >= 0, o + 4 <= data.count else { return 0 }
        let b = data[data.startIndex + o..<data.startIndex + o + 4]
        return big ? b.reduce(0) { $0 << 8 | UInt32($1) } : b.reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }
    var slices: [Int] = []
    let magic = u32(0, big: true)
    if magic == 0xCAFEBABE {
        for i in 0..<Int(min(u32(4, big: true), 8)) { slices.append(Int(u32(8 + i * 20 + 8, big: true))) }
    } else {
        slices = [0]
    }
    for base in slices where u32(base, big: false) == 0xFEEDFACF {
        let ncmds = Int(u32(base + 16, big: false))
        var off = base + 32
        for _ in 0..<min(ncmds, 512) {
            let cmd = u32(off, big: false), size = Int(u32(off + 4, big: false))
            if cmd == 0xD {  // LC_ID_DYLIB
                let v = u32(off + 16, big: false)
                return (Int(v >> 16), Int((v >> 8) & 0xFF), Int(v & 0xFF))
            }
            if size <= 0 { break }
            off += size
        }
    }
    return nil
}

func wineCommand(_ args: [String]) throws {
    var builds = knownWineBuilds()
    if let path = args.first {
        builds = [WineBuild(label: "Wine", root: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))]
    }
    guard !builds.isEmpty else {
        Out.line("No Wine build found (Heroic, CrossOver or Whisky). Pass its folder: zstadia wine \"/path/to/wine\"")
        return
    }
    var anyGood = false
    for b in builds {
        Out.line("\(b.label)  \(pretty(b.root))")
        guard let sdl = find("libSDL2-2.0.0.dylib", under: b.root) else {
            Out.fail("no SDL2 inside: this Wine reads controllers without SDL and does not rumble a Stadia")
            continue
        }
        let data = (try? Data(contentsOf: sdl, options: .mappedIfSafe)) ?? Data()
        let v = dylibVersion(sdl)
        // SDL2 libraries carry 100 * minor + 1 as their major version: 3201.10.0 is SDL 2.32.10.
        let versionText = v.map { $0.0 > 100 ? "2.\(($0.0 - 1) / 100).\($0.1)" : "\($0.0).\($0.1).\($0.2)" } ?? "unknown version"
        let hasStadia = data.contains("SDL_JOYSTICK_HIDAPI_STADIA")
        let bus = find("winebus.so", under: b.root)
        let busRumble = bus.flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }?.contains("SDL_JoystickRumble") ?? false
        if hasStadia { Out.ok("SDL \(versionText) with the Stadia driver") }
        else { Out.fail("SDL \(versionText) has no Stadia driver (needs 2.26 or newer)") }
        if busRumble { Out.ok("winebus forwards rumble to SDL") }
        else { Out.fail("winebus does not forward rumble to SDL") }
        if hasStadia && busRumble {
            anyGood = true
            Out.info("Windows games started with this Wine should rumble the Stadia controller as they are.")
        }
        Out.line()
    }
    if anyGood {
        Out.line("If a Windows game still does not rumble, see docs/WINDOWS_GAMES.md.")
    }
}
