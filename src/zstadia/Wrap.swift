// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Z Stadia contributors
//
// `zstadia wrap` turns an installed macOS game into a rumble-enabled launcher:
//
//   <output>/<Name>.app            the launcher you double-click
//   <output>/.zstadia/<Game>/      a private copy of the game app, signed locally
//
// The original game is never modified. The copy is an APFS clone (no extra disk
// space until it is re-signed) and the launcher rebuilds it by itself whenever
// the original changes, for example after a game update.

import AppKit
import Foundation

/// Stored as Contents/Resources/ZStadia.plist inside every launcher.
struct LauncherConfig: Codable {
    var formatVersion = 1
    var displayName: String
    var originalApp: String           // absolute path of the game's .app
    var copyFolder: String            // relative to the launcher's folder, or absolute
    var linkedItems: [String]         // names next to the game app that the copy links to
    var arguments: [String] = []
    var environment: [String: String] = [:]
    var steamAppID: String?
    var logFile: String?              // relative to copyFolder; enables ZSTADIA_LOG

    func copyFolderURL(launcher: URL) -> URL {
        copyFolder.hasPrefix("/") ? URL(fileURLWithPath: copyFolder)
            : launcher.deletingLastPathComponent().appendingPathComponent(copyFolder)
    }
}

struct GameInfo {
    let app: URL
    let name: String
    let bundleID: String
    let executable: URL
    let architectures: [String]
    let usesGameController: Bool
    let bundledSDL: [String]
    let sandboxed: Bool
    let isiOSApp: Bool
}

func inspectGame(_ app: URL) throws -> GameInfo {
    guard app.pathExtension == "app", fileExists(app, directory: true) else {
        throw ZError("\(pretty(app)) is not an app bundle (.app).")
    }
    if fileExists(app.appendingPathComponent("Wrapper"), directory: true) || fileExists(app.appendingPathComponent("WrappedBundle")) {
        throw ZError("This is an iPhone or iPad app running on the Mac. Its code is encrypted by the App Store and cannot be signed again, so Z Stadia cannot add rumble to it.")
    }
    guard let bundle = Bundle(url: app), let exe = bundle.executableURL, fileExists(exe) else {
        throw ZError("Cannot find the executable inside \(pretty(app)).")
    }
    let info = bundle.infoDictionary ?? [:]
    let platforms = info["CFBundleSupportedPlatforms"] as? [String] ?? []
    let ios = platforms.contains("iPhoneOS") || (info["LSRequiresIPhoneOS"] as? Bool) == true
    let archs = machOArchitectures(exe)

    // Which input stack the game ships with decides whether the bridge can help.
    var linksGC = false
    if let data = try? Data(contentsOf: exe, options: .mappedIfSafe) {
        linksGC = data.contains("/System/Library/Frameworks/GameController.framework")
    }
    var sdl: [String] = []
    if let items = FileManager.default.enumerator(at: app.appendingPathComponent("Contents"), includingPropertiesForKeys: nil) {
        for case let url as URL in items where url.lastPathComponent.range(of: #"^(lib)?SDL[23]"#, options: .regularExpression) != nil {
            sdl.append(url.lastPathComponent)
        }
    }
    let ent = (try? run("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", app.path]))?.output ?? ""
    return GameInfo(app: app, name: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? app.deletingPathExtension().lastPathComponent,
                    bundleID: bundle.bundleIdentifier ?? "unknown", executable: exe, architectures: archs,
                    usesGameController: linksGC, bundledSDL: sdl,
                    sandboxed: ent.contains("com.apple.security.app-sandbox"), isiOSApp: ios)
}

/// Folders that hold many unrelated apps. Next to a game anywhere else, the
/// files beside the .app usually belong to the game (Cyberpunk keeps 65 GB there).
func isApplicationsFolder(_ dir: URL) -> Bool {
    let p = dir.standardizedFileURL.path
    if ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"].contains(p) { return true }
    let apps = (try? FileManager.default.contentsOfDirectory(atPath: p))?.filter { $0.hasSuffix(".app") } ?? []
    return apps.count > 1
}

func defaultLinkedItems(for app: URL) -> [String] {
    let dir = app.deletingLastPathComponent()
    if isApplicationsFolder(dir) { return [] }
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    return names.filter { !$0.hasPrefix(".") && $0 != app.lastPathComponent }.sorted()
}

/// Steam games relaunch themselves through Steam unless steam_appid.txt sits in
/// the working directory; Steam's library manifests tell us the id.
func steamAppID(for app: URL) -> String? {
    var dir = app.deletingLastPathComponent()
    var installDir: String?
    while dir.path != "/" {
        if dir.deletingLastPathComponent().lastPathComponent == "common",
           dir.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "steamapps" {
            installDir = dir.lastPathComponent
            break
        }
        dir = dir.deletingLastPathComponent()
    }
    guard let installDir else { return nil }
    let steamapps = dir.deletingLastPathComponent().deletingLastPathComponent()
    for name in (try? FileManager.default.contentsOfDirectory(atPath: steamapps.path)) ?? [] where name.hasPrefix("appmanifest_") {
        guard let text = try? String(contentsOf: steamapps.appendingPathComponent(name), encoding: .utf8),
              text.contains("\"installdir\"") && text.contains("\"\(installDir)\"") else { continue }
        return name.replacingOccurrences(of: "appmanifest_", with: "").replacingOccurrences(of: ".acf", with: "")
    }
    return nil
}

// MARK: - The private copy

struct SourceFingerprint: Codable, Equatable {
    var executableSize: Int
    var executableModified: Double
    var infoModified: Double
    var version: String

    init(app: URL) throws {
        guard let bundle = Bundle(url: app), let exe = bundle.executableURL else {
            throw ZError("The game at \(pretty(app)) is missing or damaged.")
        }
        let a = try FileManager.default.attributesOfItem(atPath: exe.path)
        let info = try? FileManager.default.attributesOfItem(atPath: app.appendingPathComponent("Contents/Info.plist").path)
        executableSize = (a[.size] as? NSNumber)?.intValue ?? 0
        executableModified = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        infoModified = (info?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let d = bundle.infoDictionary ?? [:]
        version = "\(d["CFBundleShortVersionString"] ?? "?") (\(d["CFBundleVersion"] ?? "?"))"
    }
}

let fingerprintName = ".zstadia-source.plist"

func copiedApp(_ config: LauncherConfig, launcher: URL) -> URL {
    config.copyFolderURL(launcher: launcher).appendingPathComponent(URL(fileURLWithPath: config.originalApp).lastPathComponent)
}

func copyIsCurrent(_ config: LauncherConfig, launcher: URL) -> Bool {
    let folder = config.copyFolderURL(launcher: launcher)
    guard fileExists(copiedApp(config, launcher: launcher), directory: true),
          let data = try? Data(contentsOf: folder.appendingPathComponent(fingerprintName)),
          let stored = try? PropertyListDecoder().decode(SourceFingerprint.self, from: data),
          let now = try? SourceFingerprint(app: URL(fileURLWithPath: config.originalApp)) else { return false }
    return stored == now
}

/// (Re)creates the private copy: clone, link, sign. Safe to run again at any time.
func buildCopy(_ config: LauncherConfig, launcher: URL, progress: (String) -> Void) throws {
    let fm = FileManager.default
    let original = URL(fileURLWithPath: config.originalApp)
    let folder = config.copyFolderURL(launcher: launcher)
    let copy = folder.appendingPathComponent(original.lastPathComponent)
    let fingerprint = try SourceFingerprint(app: original)

    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    try? fm.removeItem(at: folder.appendingPathComponent(fingerprintName))
    if fileExists(copy) { try fm.removeItem(at: copy) }

    progress("Copying the game app")
    try fm.copyItem(at: original, to: copy)  // APFS clone when on the same volume

    for name in config.linkedItems {
        let link = folder.appendingPathComponent(name)
        if isSymlink(link) { try fm.removeItem(at: link) }
        else if fileExists(link) { throw ZError("\(pretty(link)) exists and is not a link made by Z Stadia; remove it first.") }
        try fm.createSymbolicLink(at: link, withDestinationURL: original.deletingLastPathComponent().appendingPathComponent(name))
    }
    if let id = config.steamAppID {
        try Data((id + "\n").utf8).write(to: folder.appendingPathComponent("steam_appid.txt"))
    }

    // A quarantined copy with a local signature would be refused by Gatekeeper.
    try run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", copy.path])

    // The publisher's signature forbids loading the rumble library. The copy is
    // signed again locally, without hardened runtime and without entitlements
    // that only the publisher's certificate may hold.
    progress("Signing the copy on this Mac")
    let sign = try run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", "--timestamp=none", copy.path])
    guard sign.status == 0 else { throw ZError("codesign failed:\n\(sign.output)") }

    let data = try PropertyListEncoder().encode(fingerprint)
    try data.write(to: folder.appendingPathComponent(fingerprintName))
}

// MARK: - The launcher bundle

func writeLauncher(at launcher: URL, config: LauncherConfig, icon: URL?, library: Data) throws {
    let fm = FileManager.default
    let contents = launcher.appendingPathComponent("Contents")
    let macOS = contents.appendingPathComponent("MacOS")
    let resources = contents.appendingPathComponent("Resources")
    if fileExists(launcher) { try fm.removeItem(at: launcher) }
    try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
    try fm.createDirectory(at: resources, withIntermediateDirectories: true)

    let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let exe = macOS.appendingPathComponent("zstadia-launcher")
    try fm.copyItem(at: Bundle.main.executableURL ?? me, to: exe)
    try library.write(to: resources.appendingPathComponent("ZStadiaRumble.dylib"))
    try PropertyListEncoder().encode(config).write(to: resources.appendingPathComponent("ZStadia.plist"))
    if let icon { try fm.copyItem(at: icon, to: resources.appendingPathComponent("AppIcon.icns")) }

    let slug = config.displayName.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
    let info: [String: Any] = [
        "CFBundleDevelopmentRegion": "en",
        "CFBundleExecutable": "zstadia-launcher",
        "CFBundleIdentifier": "dev.zstadia.launcher.\(slug.isEmpty ? "game" : slug)",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": config.displayName,
        "CFBundleDisplayName": config.displayName,
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": zstadiaVersion,
        "CFBundleVersion": zstadiaVersion,
        "CFBundleIconFile": "AppIcon",
        "LSApplicationCategoryType": "public.app-category.games",
        "LSMinimumSystemVersion": "14.0",
        "NSHighResolutionCapable": true,
        "NSHumanReadableCopyright": "Z Stadia, GPL-3.0-or-later",
    ]
    let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try plist.write(to: contents.appendingPathComponent("Info.plist"))
    let sign = try run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", "--timestamp=none", launcher.path])
    guard sign.status == 0 else { throw ZError("codesign failed for the launcher:\n\(sign.output)") }
    NSWorkspace.shared.noteFileSystemChanged(launcher.path)
}

// MARK: - Command

func wrapCommand(_ args: [String]) throws {
    var gamePath: String?
    var name: String?
    var output = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications/Z Stadia")
    var links: [String]?
    var extraArgs: [String] = []
    var env: [String: String] = [:]
    var steam: String?
    var badge = true
    var log = false
    var force = false
    var it = args.makeIterator()
    func value(_ flag: String) throws -> String {
        guard let v = it.next() else { throw ZError("\(flag) needs a value.") }
        return v
    }
    while let a = it.next() {
        switch a {
        case "--name": name = try value(a)
        case "--output": output = URL(fileURLWithPath: (try value(a) as NSString).expandingTildeInPath)
        case "--link": links = (links ?? []) + [try value(a)]
        case "--no-links": links = []
        case "--arg": extraArgs.append(try value(a))
        case "--env":
            let kv = try value(a)
            guard let eq = kv.firstIndex(of: "="), !kv[..<eq].isEmpty else { throw ZError("--env expects KEY=VALUE.") }
            env[String(kv[..<eq])] = String(kv[kv.index(after: eq)...])
        case "--steam-appid": steam = try value(a)
        case "--no-badge": badge = false
        case "--log": log = true
        case "--force": force = true
        default:
            if a.hasPrefix("-") { throw ZError("Unknown option \(a). Run: zstadia help wrap") }
            gamePath = a
        }
    }
    guard let gamePath else { throw ZError("Tell me which game: zstadia wrap \"/path/to/Game.app\"") }
    let app = URL(fileURLWithPath: (gamePath as NSString).expandingTildeInPath).standardizedFileURL
    let game = try inspectGame(app)
    guard let library = embeddedLibrary() else { throw ZError("This zstadia binary has no embedded rumble library. Build it with make.") }

    Out.line("Game        \(game.name)  (\(game.bundleID))")
    Out.line("Location    \(pretty(app))")
    Out.line("Code        \(game.architectures.joined(separator: ", "))")
    if game.isiOSApp { throw ZError("This is an iPhone or iPad app. Z Stadia cannot add rumble to it.") }
    if game.architectures.contains("arm64e") && !game.architectures.contains("arm64") && !game.architectures.contains("x86_64") {
        throw ZError("The game is built only for arm64e, which third-party libraries cannot join.")
    }
    if game.usesGameController {
        Out.ok("uses Apple's Game Controller framework: the bridge can give it rumble")
    } else if !game.bundledSDL.isEmpty {
        Out.warn("bundles \(game.bundledSDL.joined(separator: ", ")). SDL 2.26 or newer already rumbles a Stadia controller by itself; try the game without Z Stadia first.")
    } else if !force {
        throw ZError("The game does not use Apple's Game Controller framework, so it never asks for rumble through it. Nothing to bridge. Use --force to wrap it anyway.")
    }
    if game.sandboxed {
        Out.warn("the game is sandboxed (Mac App Store). The copy runs outside the sandbox, so it may not see the saves of the original and Game Center or iCloud may not sign in.")
    }

    let display = name ?? "Z Stadia \(game.name)"
    let linked = links ?? defaultLinkedItems(for: app)
    let steamID = steam ?? steamAppID(for: app)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let launcher = output.appendingPathComponent(display + ".app")
    let folderName = app.deletingPathExtension().lastPathComponent
    var config = LauncherConfig(displayName: display, originalApp: app.path, copyFolder: ".zstadia/\(folderName)",
                                linkedItems: linked, arguments: extraArgs, environment: env, steamAppID: steamID)
    if log { config.logFile = "rumble.log" }
    if !linked.isEmpty { Out.info("links to the game's data next to it: \(linked.joined(separator: ", "))") }
    if let steamID { Out.info("Steam app id \(steamID): steam_appid.txt keeps Steam from relaunching the original") }

    try buildCopy(config, launcher: launcher) { Out.info($0 + "...") }

    var iconFile: URL?
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("zstadia-icon-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }
    do {
        iconFile = try makeLauncherIcon(for: app, badge: badge, workDir: tmp)
    } catch {
        Out.warn("icon not created (\(error)); the launcher uses a generic icon")
    }
    try writeLauncher(at: launcher, config: config, icon: iconFile, library: library)
    Out.ok("launcher ready: \(pretty(launcher))")
    Out.line()
    Out.line("Open \"\(display)\" to play with rumble. The original game in its launcher is unchanged.")
    Out.line("After a game update the launcher refreshes its copy by itself on the next start.")
}

func unwrapCommand(_ args: [String]) throws {
    guard let path = args.first else { throw ZError("Tell me which launcher: zstadia unwrap \"/path/to/Z Stadia Game.app\"") }
    let launcher = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    let plist = launcher.appendingPathComponent("Contents/Resources/ZStadia.plist")
    guard let data = try? Data(contentsOf: plist), let config = try? PropertyListDecoder().decode(LauncherConfig.self, from: data) else {
        throw ZError("\(pretty(launcher)) is not a Z Stadia launcher.")
    }
    let folder = config.copyFolderURL(launcher: launcher)
    var removed: [String] = []
    if fileExists(folder.appendingPathComponent(fingerprintName)) || fileExists(copiedApp(config, launcher: launcher)) {
        try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
        removed.append(pretty(folder))
        let parent = folder.deletingLastPathComponent()
        if parent.lastPathComponent == ".zstadia", (try? FileManager.default.contentsOfDirectory(atPath: parent.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: parent)
        }
    }
    try FileManager.default.trashItem(at: launcher, resultingItemURL: nil)
    removed.append(pretty(launcher))
    Out.ok("moved to the Trash: \(removed.joined(separator: ", "))")
    Out.info("The original game was not touched.")
}
