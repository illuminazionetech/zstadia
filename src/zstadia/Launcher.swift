// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Z Stadia contributors
//
// What a launcher made by `zstadia wrap` does when you open it:
//   1. refresh the private copy if the original game changed (an update),
//   2. start the copy with the rumble library injected,
//   3. hide from the Dock, wait for the game to quit, then stop the motors.

import AppKit
import Darwin
import Foundation

final class LauncherApp: NSObject, NSApplicationDelegate {
    private let launcher: URL
    private let config: LauncherConfig
    private var panel: NSPanel?
    private var label: NSTextField?

    init(launcher: URL, config: LauncherConfig) {
        self.launcher = launcher
        self.config = config
    }

    static func runIfLauncher() -> Bool {
        let bundle = Bundle.main
        guard bundle.bundleURL.pathExtension == "app",
              let url = bundle.url(forResource: "ZStadia", withExtension: "plist") else { return false }
        let app = NSApplication.shared
        guard let data = try? Data(contentsOf: url), let config = try? PropertyListDecoder().decode(LauncherConfig.self, from: data) else {
            app.setActivationPolicy(.regular)
            alert("This launcher is damaged.", "Create it again with: zstadia wrap \"/path/to/Game.app\"")
            exit(1)
        }
        let delegate = LauncherApp(launcher: bundle.bundleURL, config: config)
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.global(qos: .userInitiated).async { self.start() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func start() {
        let original = URL(fileURLWithPath: config.originalApp)
        guard fileExists(original, directory: true) else {
            fail("\(config.displayName) cannot find the game.",
                 "It was at \(pretty(original)). If you moved or reinstalled it, wrap it again with zstadia.")
            return
        }
        let copy = copiedApp(config, launcher: launcher)
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.executableURL?.path.hasPrefix(copy.path + "/") == true }) {
            running.activate()
            finish(0)
            return
        }
        if !copyIsCurrent(config, launcher: launcher) {
            showProgress("Preparing \(config.displayName)...")
            do {
                try buildCopy(config, launcher: launcher) { step in self.updateProgress(step + "...") }
            } catch {
                fail("\(config.displayName) could not prepare the game.", "\(error)")
                return
            }
            hideProgress()
        }
        launch(copy)
    }

    private func launch(_ copy: URL) {
        guard let bundle = Bundle(url: copy), let exe = bundle.executableURL else {
            fail("The prepared copy is damaged.", "Delete the .zstadia folder next to the launcher and open it again.")
            return
        }
        let library = launcher.appendingPathComponent("Contents/Resources/ZStadiaRumble.dylib")
        let folder = config.copyFolderURL(launcher: launcher)

        var env = ProcessInfo.processInfo.environment
        env["DYLD_INSERT_LIBRARIES"] = [library.path, env["DYLD_INSERT_LIBRARIES"]].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ":")
        for (k, v) in config.environment { env[k] = v }
        if let log = config.logFile { env["ZSTADIA_LOG"] = folder.appendingPathComponent(log).path }
        env.removeValue(forKey: "__CFBundleIdentifier")  // belongs to the launcher, not the game

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_addchdir_np(&actions, folder.path)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = [exe.path] + config.arguments
        let envp = env.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let status = withCStrings(argv) { a in withCStrings(envp) { e in posix_spawn(&pid, exe.path, &actions, &attributes, a, e) } }
        guard status == 0 else {
            fail("\(config.displayName) could not start the game.", String(cString: strerror(status)))
            return
        }

        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)  // the game takes the Dock and the menu bar
        }
        let exited = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            var code: Int32 = 0
            while waitpid(pid, &code, 0) == -1 && errno == EINTR {}
            exited.signal()
            stopAllMotors()  // even if the game crashed with the motors running
            self.finish(0)
        }
        // Bring the game forward once it has registered with the system.
        for _ in 0..<40 {
            if exited.wait(timeout: .now() + 0.25) == .success { break }
            if let app = NSRunningApplication(processIdentifier: pid) {
                app.activate()
                break
            }
        }
    }

    // MARK: UI

    private func showProgress(_ text: String) {
        DispatchQueue.main.sync {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 92), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.isMovableByWindowBackground = true
            let spinner = NSProgressIndicator(frame: NSRect(x: 24, y: 30, width: 32, height: 32))
            spinner.style = .spinning
            spinner.startAnimation(nil)
            let l = NSTextField(labelWithString: text)
            l.frame = NSRect(x: 70, y: 36, width: 270, height: 20)
            l.font = .systemFont(ofSize: 13, weight: .medium)
            p.contentView?.addSubview(spinner)
            p.contentView?.addSubview(l)
            p.center()
            NSApp.activate(ignoringOtherApps: true)
            p.makeKeyAndOrderFront(nil)
            panel = p
            label = l
        }
    }

    private func updateProgress(_ text: String) { DispatchQueue.main.async { self.label?.stringValue = text } }
    private func hideProgress() { DispatchQueue.main.sync { panel?.orderOut(nil); panel = nil } }

    private func fail(_ title: String, _ detail: String) {
        DispatchQueue.main.sync {
            panel?.orderOut(nil)
            NSApp.activate(ignoringOtherApps: true)
            alert(title, detail)
        }
        finish(1)
    }

    private func finish(_ code: Int32) { DispatchQueue.main.async { exit(code) } }
}

func alert(_ title: String, _ detail: String) {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = detail
    a.alertStyle = .warning
    a.runModal()
}

private func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
    var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    pointers.append(nil)
    defer { pointers.forEach { free($0) } }
    return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
}
