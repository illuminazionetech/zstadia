// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Z Stadia contributors
//
// Direct access to Stadia controllers through IOKit HID. The rumble command is
// output report 5: two little-endian 16-bit levels, strong motor then weak one.

import Foundation
import IOKit.hid

let stadiaVendorID = 0x18D1
let stadiaProductID = 0x9400
let rumbleReportID: UInt8 = 5

struct StadiaController {
    let device: IOHIDDevice
    let name: String
    let transport: String
    let maxOutputReport: Int
    var bluetooth: Bool { transport.localizedCaseInsensitiveContains("bluetooth") }
    var transportLabel: String { bluetooth ? "Bluetooth" : (transport.isEmpty ? "unknown link" : transport) }
}

final class StadiaControllers {
    private let manager: IOHIDManager

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [kIOHIDVendorIDKey: stadiaVendorID, kIOHIDProductIDKey: stadiaProductID]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    deinit { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

    func list() -> [StadiaController] {
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        return set.map { d in
            func prop(_ key: String) -> Any? { IOHIDDeviceGetProperty(d, key as CFString) }
            return StadiaController(device: d,
                                    name: prop(kIOHIDProductKey) as? String ?? "Stadia Controller",
                                    transport: prop(kIOHIDTransportKey) as? String ?? "",
                                    maxOutputReport: (prop(kIOHIDMaxOutputReportSizeKey) as? Int) ?? 0)
        }.sorted { $0.transport < $1.transport }
    }
}

func open(_ c: StadiaController) -> IOReturn {
    IOHIDDeviceOpen(c.device, IOOptionBits(kIOHIDOptionsTypeNone))
}

@discardableResult
func setMotors(_ c: StadiaController, strong: Double, weak: Double) -> IOReturn {
    func level(_ v: Double) -> UInt16 { UInt16((min(max(v, 0), 1) * 65535).rounded()) }
    let s = level(strong), w = level(weak)
    var report: [UInt8] = [rumbleReportID, UInt8(s & 0xFF), UInt8(s >> 8), UInt8(w & 0xFF), UInt8(w >> 8)]
    return IOHIDDeviceSetReport(c.device, kIOHIDReportTypeOutput, CFIndex(rumbleReportID), &report, report.count)
}

private final class WriteWait {
    var done = false
    var result: IOReturn = kIOReturnTimeout
}

/// Sends a "motors off" report asynchronously and measures how long the
/// controller takes to acknowledge it. Over Bluetooth this is the real cost of
/// one rumble update.
func measureWrite(_ c: StadiaController) -> (result: IOReturn, milliseconds: Double?) {
    guard let loop = CFRunLoopGetCurrent() else { return (kIOReturnError, nil) }
    IOHIDDeviceScheduleWithRunLoop(c.device, loop, CFRunLoopMode.defaultMode.rawValue)
    defer { IOHIDDeviceUnscheduleFromRunLoop(c.device, loop, CFRunLoopMode.defaultMode.rawValue) }
    let wait = WriteWait()
    let report = UnsafeMutablePointer<UInt8>.allocate(capacity: 5)
    report.initialize(repeating: 0, count: 5)
    report[0] = rumbleReportID
    defer { report.deallocate() }
    let context = Unmanaged.passUnretained(wait).toOpaque()
    let start = Date()
    let callback: IOHIDReportCallback = { ctx, result, _, _, _, _, _ in
        guard let ctx else { return }
        let w = Unmanaged<WriteWait>.fromOpaque(ctx).takeUnretainedValue()
        w.result = result
        w.done = true
    }
    let r = IOHIDDeviceSetReportWithCallback(c.device, kIOHIDReportTypeOutput, CFIndex(rumbleReportID), report, 5, 0.5, callback, context)
    if r != kIOReturnSuccess { return (r, nil) }
    while !wait.done && Date().timeIntervalSince(start) < 1.0 {
        CFRunLoopRunInMode(.defaultMode, 0.01, true)
    }
    return (wait.result, wait.done ? Date().timeIntervalSince(start) * 1000 : nil)
}

func describe(_ r: IOReturn) -> String {
    switch r {
    case kIOReturnSuccess: return "success"
    case kIOReturnNotPermitted, kIOReturnNotPrivileged: return "not permitted (0x\(String(UInt32(bitPattern: r), radix: 16)))"
    case kIOReturnTimeout: return "timed out"
    case kIOReturnNotAttached, kIOReturnNoDevice: return "controller disconnected"
    case kIOReturnUnsupported: return "unsupported"
    default: return "0x\(String(UInt32(bitPattern: r), radix: 16))"
    }
}

/// Opens every connected Stadia controller, or explains how to connect one.
func connectedControllers() throws -> (StadiaControllers, [StadiaController]) {
    let all = StadiaControllers()
    let list = all.list()
    guard !list.isEmpty else {
        throw ZError("""
        No Stadia controller found.
        Connect it with a USB cable, or over Bluetooth after switching it to Bluetooth mode
        (System Settings > Bluetooth). See docs/TROUBLESHOOTING.md.
        """)
    }
    for c in list {
        let r = open(c)
        if r != kIOReturnSuccess { throw ZError("macOS refused to open the controller: \(describe(r)).") }
    }
    return (all, list)
}

func stopAllMotors() {
    let all = StadiaControllers()
    for c in all.list() where open(c) == kIOReturnSuccess {
        setMotors(c, strong: 0, weak: 0)
        IOHIDDeviceClose(c.device, IOOptionBits(kIOHIDOptionsTypeNone))
    }
}
