// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Z Stadia contributors

import Foundation
import MachO

let zstadiaVersion = "1.0.0"

struct ZError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

enum Out {
    static var quiet = false
    static func line(_ s: String = "") { if !quiet { print(s) } }
    static func ok(_ s: String) { line("  OK    \(s)") }
    static func warn(_ s: String) { line("  WARN  \(s)") }
    static func fail(_ s: String) { line("  FAIL  \(s)") }
    static func info(_ s: String) { line("        \(s)") }
    static func err(_ s: String) {
        fflush(stdout)  // keep messages in order when both go to the same pipe
        FileHandle.standardError.write(Data(("zstadia: " + s + "\n").utf8))
    }
}

/// Paths shown to the user never include the home folder name.
func pretty(_ url: URL) -> String { pretty(url.path) }
func pretty(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

/// Runs a tool and returns its exit status and combined output.
@discardableResult
func run(_ tool: String, _ args: [String], input: Data? = nil) throws -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    if let input {
        let inPipe = Pipe()
        p.standardInput = inPipe
        try p.run()
        inPipe.fileHandleForWriting.write(input)
        try inPipe.fileHandleForWriting.close()
    } else {
        p.standardInput = FileHandle.nullDevice
        try p.run()
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// The rumble library travels inside this executable (section __DATA,__zstadia_lib),
/// so `zstadia` is a single self-contained file.
func embeddedLibrary() -> Data? {
    guard let raw = _dyld_get_image_header(0) else { return nil }
    let header = UnsafeRawPointer(raw).assumingMemoryBound(to: mach_header_64.self)
    var size: UInt = 0
    guard let bytes = getsectiondata(header, "__DATA", "__zstadia_lib", &size), size > 0 else { return nil }
    return Data(bytes: bytes, count: Int(size))
}

/// Architectures contained in a Mach-O file, read from its headers.
func machOArchitectures(_ url: URL) -> [String] {
    guard let fh = try? FileHandle(forReadingFrom: url), let head = try? fh.read(upToCount: 4096) else { return [] }
    try? fh.close()
    func be32(_ o: Int) -> UInt32 { head.count >= o + 4 ? head[o..<o + 4].reduce(0) { $0 << 8 | UInt32($1) } : 0 }
    func le32(_ o: Int) -> UInt32 { head.count >= o + 4 ? head[o..<o + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) } : 0 }
    func name(_ cpu: UInt32, _ sub: UInt32) -> String {
        switch cpu {
        case 0x0100000C: return (sub & 0xFF) == 2 ? "arm64e" : "arm64"
        case 0x01000007: return "x86_64"
        case 7: return "i386"
        default: return String(format: "cpu-%x", cpu)
        }
    }
    let magic = be32(0)
    if magic == 0xCAFEBABE || magic == 0xCAFEBABF {  // fat
        let count = Int(be32(4)), step = magic == 0xCAFEBABE ? 20 : 32
        return (0..<min(count, 16)).map { name(be32(8 + $0 * step), be32(12 + $0 * step)) }
    }
    if le32(0) == 0xFEEDFACF { return [name(le32(4), le32(8))] }
    return []
}

func fileExists(_ url: URL, directory: Bool? = nil) -> Bool {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
    return directory == nil || isDir.boolValue == directory!
}

func isSymlink(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
}

extension Data {
    func contains(_ ascii: String) -> Bool { range(of: Data(ascii.utf8)) != nil }
}
