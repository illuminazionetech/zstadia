// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Z Stadia contributors
//
// zstadia: rumble for the Google Stadia Controller in macOS games.

import AppKit
import Foundation
import GameController

let usage = """
zstadia \(zstadiaVersion): rumble for the Google Stadia Controller in macOS games

Usage:
  zstadia doctor                      check controller, Bluetooth/USB and the rumble path
  zstadia status                      list connected Stadia controllers
  zstadia test                        feel both motors (hold the controller)
  zstadia rumble <strong> <weak> [ms] run the motors, levels 0-100, default 500 ms
  zstadia stop                        stop the motors
  zstadia wrap <Game.app> [options]   make a launcher that starts the game with rumble
  zstadia unwrap <Launcher.app>       move a launcher and its game copy to the Trash
  zstadia wine [<wine folder>]        check Wine builds for Windows games
  zstadia icon <Game.app> <out.png>   preview the launcher icon
  zstadia version

wrap options:
  --name "Z Stadia Game"  launcher name (default: "Z Stadia " + game name)
  --output <folder>       where the launcher goes (default: ~/Applications/Z Stadia)
  --link <name>           item next to the game app the copy needs (repeatable)
  --no-links              link nothing (default: everything next to the app,
                          unless the app sits in an Applications folder)
  --arg <argument>        extra launch argument for the game (repeatable)
  --env KEY=VALUE         environment for the game, e.g. ZSTADIA_GAIN=1.3
  --steam-appid <id>      Steam app id (found automatically for Steam games)
  --no-badge              keep the game's icon as it is
  --log                   write a rumble log next to the game copy
  --force                 wrap even if the game does not use Game Controller

Docs: README.md, AI_AGENT_GUIDE.md and docs/ in the Z Stadia folder.
"""

func statusCommand() throws {
    let (_, list) = try connectedControllers()
    for c in list {
        let rumble = c.maxOutputReport >= 5 ? "rumble report available" : "no rumble report (\(c.maxOutputReport) bytes)"
        Out.line("\(c.name)  via \(c.transportLabel), \(rumble)")
    }
}

func rumbleCommand(_ args: [String]) throws {
    guard args.count >= 2, let s = Double(args[0]), let w = Double(args[1]) else {
        throw ZError("Usage: zstadia rumble <strong 0-100> <weak 0-100> [milliseconds]")
    }
    let ms = args.count > 2 ? min(max(Double(args[2]) ?? 500, 0), 10_000) : 500
    let (_, list) = try connectedControllers()
    for c in list {
        let r = setMotors(c, strong: s / 100, weak: w / 100)
        if r != kIOReturnSuccess { throw ZError("The controller refused the command: \(describe(r)).") }
    }
    usleep(useconds_t(ms * 1000))
    for c in list { setMotors(c, strong: 0, weak: 0) }
    Out.ok("motors ran for \(Int(ms)) ms on \(list.map(\.transportLabel).joined(separator: " and "))")
}

func testCommand() throws {
    let (_, list) = try connectedControllers()
    Out.line("Hold the controller. You should feel, in order:")
    Out.line("  1. the strong motor (left grip, deep rumble)")
    Out.line("  2. the weak motor (right grip, light buzz)")
    Out.line("  3. both motors rising from soft to full")
    Out.line()
    usleep(800_000)
    func both(_ s: Double, _ w: Double) throws {
        for c in list {
            let r = setMotors(c, strong: s, weak: w)
            if r != kIOReturnSuccess { throw ZError("The controller refused the command: \(describe(r)).") }
        }
    }
    defer { for c in list { setMotors(c, strong: 0, weak: 0) } }
    try both(1, 0); usleep(450_000); try both(0, 0); usleep(450_000)
    try both(0, 1); usleep(450_000); try both(0, 0); usleep(450_000)
    for i in 0...25 { try both(Double(i) / 25, Double(i) / 25); usleep(40_000) }
    usleep(250_000)
    Out.ok("test sent via \(list.map(\.transportLabel).joined(separator: " and ")). If you felt nothing, see docs/TROUBLESHOOTING.md.")
}

func doctorCommand() throws {
    var problems = 0
    let os = ProcessInfo.processInfo.operatingSystemVersion
    Out.line("System")
    if os.majorVersion >= 14 { Out.ok("macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)") }
    else { Out.fail("macOS 14 or newer is needed"); problems += 1 }
    #if arch(arm64)
    let rosetta = fileExists(URL(fileURLWithPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime"))
    if rosetta { Out.ok("Apple silicon, Rosetta installed (Intel games work too)") }
    else { Out.warn("Rosetta is not installed: only Apple silicon games can be wrapped") }
    #else
    Out.ok("Intel Mac")
    #endif

    Out.line()
    Out.line("Rumble library")
    if let lib = embeddedLibrary() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("zstadia-doctor.dylib")
        try? lib.write(to: tmp)
        Out.ok("embedded (\(lib.count / 1024) KB, \(machOArchitectures(tmp).joined(separator: " + ")))")
        try? FileManager.default.removeItem(at: tmp)
    } else {
        Out.fail("missing: rebuild zstadia with make"); problems += 1
    }

    Out.line()
    Out.line("Controller")
    let all = StadiaControllers()
    let list = all.list()
    if list.isEmpty {
        Out.fail("no Stadia controller connected (USB cable, or Bluetooth after switching it to Bluetooth mode)")
        problems += 1
    }
    for c in list {
        Out.ok("\(c.name) via \(c.transportLabel)")
        if c.maxOutputReport >= 5 { Out.ok("rumble report 5 available") }
        else { Out.fail("no rumble report (\(c.maxOutputReport) bytes): firmware not supported"); problems += 1 }
        let r = open(c)
        guard r == kIOReturnSuccess else { Out.fail("cannot open it: \(describe(r))"); problems += 1; continue }
        let (result, ms) = measureWrite(c)
        if result == kIOReturnSuccess, let ms {
            Out.ok(String(format: "rumble command acknowledged in %.1f ms", ms))
        } else {
            Out.fail("rumble command not acknowledged: \(describe(result))"); problems += 1
        }
    }

    Out.line()
    Out.line("Apple Game Controller framework")
    GCController.startWirelessControllerDiscovery {}
    let until = Date().addingTimeInterval(1.5)
    while Date() < until && !GCController.controllers().contains(where: { ($0.vendorName ?? "").localizedCaseInsensitiveContains("stadia") }) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    GCController.stopWirelessControllerDiscovery()
    if let gc = GCController.controllers().first(where: { ($0.vendorName ?? "").localizedCaseInsensitiveContains("stadia") }) {
        Out.ok("games see \"\(gc.vendorName ?? "?")\" as a \(gc.extendedGamepad != nil ? "full gamepad" : "limited gamepad")")
        if gc.haptics == nil { Out.info("without Z Stadia it has no rumble: this is what the launcher fixes") }
        else { Out.info("macOS already gives it rumble here") }
    } else if !list.isEmpty {
        Out.warn("the framework does not list the controller yet; games may not see it")
    }

    Out.line()
    if problems == 0 { Out.line("Everything looks right. Next: zstadia test, then zstadia wrap \"/path/to/Game.app\".") }
    else { Out.line("\(problems) problem(s). See docs/TROUBLESHOOTING.md.") }
    if problems > 0 { exit(1) }
}

// MARK: - Entry

if LauncherApp.runIfLauncher() { exit(0) }

var arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.isEmpty ? "help" : arguments.removeFirst()
do {
    switch command {
    case "doctor": try doctorCommand()
    case "status": try statusCommand()
    case "test": try testCommand()
    case "rumble": try rumbleCommand(arguments)
    case "stop": stopAllMotors(); Out.ok("motors stopped")
    case "wrap": try wrapCommand(arguments)
    case "unwrap": try unwrapCommand(arguments)
    case "wine": try wineCommand(arguments)
    case "icon": try iconCommand(arguments)
    case "version", "--version", "-v": Out.line("zstadia \(zstadiaVersion)")
    case "help", "--help", "-h": Out.line(usage)
    default:
        Out.err("unknown command \"\(command)\"")
        Out.line(usage)
        exit(2)
    }
} catch {
    Out.err("\(error)")
    exit(1)
}
