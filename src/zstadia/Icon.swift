// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Z Stadia contributors
//
// Launcher icon: the game's own icon with a badge in the bottom-right corner
// showing the Stadia Controller as it really looks (white body, black controls,
// salmon stick bases, white status light around the center button). The game
// icon is read from the installed game at wrap time and never shipped.
//
// Shapes are measured on a top view of the real controller, in a 375 x 247
// frame (x to the right, y down), and mapped into the badge.

import AppKit
import Foundation

private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

private let shellTop = rgb(250, 250, 248)
private let shellBottom = rgb(222, 222, 219)
private let shellEdge = rgb(196, 196, 193)
private let control = rgb(24, 24, 27)
private let controlTop = rgb(58, 58, 64)
private let salmonLight = rgb(255, 150, 126)
private let salmonDeep = rgb(240, 92, 66)
private let discTop = rgb(52, 53, 60)
private let discBottom = rgb(22, 22, 26)

/// Outline of the controller, clockwise from the top center, in frame units.
private let outline: [CGPoint] = [
    (187, 7), (250, 8), (306, 11), (343, 21), (364, 42), (373, 74), (375, 112), (374, 156),
    (369, 200), (359, 230), (341, 245), (317, 247), (297, 238), (284, 214), (273, 192), (257, 177),
    (230, 168), (187, 166), (144, 168), (117, 177), (101, 192), (90, 214), (77, 238), (57, 247),
    (33, 245), (15, 230), (5, 200), (0, 156), (-1, 112), (1, 74), (10, 42), (31, 21), (68, 11), (124, 8),
].map { CGPoint(x: $0.0, y: $0.1) }

/// Closed Catmull-Rom spline through `points`, as Bezier curves.
private func smoothClosedPath(_ points: [NSPoint]) -> NSBezierPath {
    let path = NSBezierPath()
    let n = points.count
    path.move(to: points[0])
    for i in 0..<n {
        let p0 = points[(i - 1 + n) % n], p1 = points[i], p2 = points[(i + 1) % n], p3 = points[(i + 2) % n]
        let c1 = NSPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
        let c2 = NSPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
        path.curve(to: p2, controlPoint1: c1, controlPoint2: c2)
    }
    path.close()
    return path
}

private func withShadow(color: NSColor, blur: CGFloat, offset: NSSize = .zero, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let s = NSShadow()
    s.shadowColor = color
    s.shadowBlurRadius = blur
    s.shadowOffset = offset
    s.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

/// Draws the badge filling the square `rect`.
func drawControllerBadge(in rect: NSRect) {
    let d = rect.width
    func circle(_ c: NSPoint, _ r: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }

    // Dark disc, so the white controller reads on any game icon.
    let discPath = circle(NSPoint(x: rect.midX, y: rect.midY), d / 2)
    withShadow(color: NSColor.black.withAlphaComponent(0.5), blur: 0.07 * d, offset: NSSize(width: 0, height: -0.025 * d)) {
        discBottom.setFill()
        discPath.fill()
    }
    NSGradient(starting: discTop, ending: discBottom)?.draw(in: discPath, angle: -90)
    NSColor.white.withAlphaComponent(0.12).setStroke()
    let rim = circle(NSPoint(x: rect.midX, y: rect.midY), d / 2 - 0.011 * d)
    rim.lineWidth = 0.022 * d
    rim.stroke()

    // Map the 375 x 247 frame into the disc, centered, 82% of its width.
    let width = 0.82 * d, k = width / 375, height = 247 * k
    let ox = rect.midX - width / 2, oy = rect.midY - height / 2 + 0.01 * d
    func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: ox + x * k, y: oy + (247 - y) * k) }
    func L(_ v: CGFloat) -> CGFloat { v * k }

    // Shell with a soft shadow and a top-lit gradient.
    let shell = smoothClosedPath(outline.map { P($0.x, $0.y) })
    withShadow(color: NSColor.black.withAlphaComponent(0.55), blur: 0.04 * d, offset: NSSize(width: 0, height: -0.012 * d)) {
        shellBottom.setFill()
        shell.fill()
    }
    NSGradient(starting: shellTop, ending: shellBottom)?.draw(in: shell, angle: -90)
    shellEdge.setStroke()
    shell.lineWidth = max(1, L(1.6))
    shell.stroke()

    // D-pad, top left.
    control.setFill()
    let dpad = NSBezierPath()
    let dc = P(82, 57), arm = L(26), half = L(9.5), r = L(4)
    dpad.appendRoundedRect(NSRect(x: dc.x - arm, y: dc.y - half, width: 2 * arm, height: 2 * half), xRadius: r, yRadius: r)
    dpad.appendRoundedRect(NSRect(x: dc.x - half, y: dc.y - arm, width: 2 * half, height: 2 * arm), xRadius: r, yRadius: r)
    dpad.windingRule = .nonZero
    dpad.fill()

    // Face buttons Y, X, B, A, top right.
    for (x, y) in [(296.0, 42.0), (272.0, 65.0), (321.0, 65.0), (296.0, 88.0)] {
        let b = circle(P(x, y), L(10.5))
        NSGradient(starting: controlTop, ending: control)?.draw(in: b, angle: -90)
    }

    // Options and menu pills, assistant and capture buttons.
    for x in [148.0, 237.0] {
        let c = P(x, 38)
        NSBezierPath(roundedRect: NSRect(x: c.x - L(10), y: c.y - L(4.5), width: L(20), height: L(9)), xRadius: L(4.5), yRadius: L(4.5)).fill()
    }
    circle(P(163, 64), L(6.5)).fill()
    let cap = P(218, 64)
    NSBezierPath(roundedRect: NSRect(x: cap.x - L(6.5), y: cap.y - L(6.5), width: L(13), height: L(13)), xRadius: L(3.5), yRadius: L(3.5)).fill()

    // Thumbsticks on their salmon bases, low in the middle.
    for x in [130.0, 250.0] {
        let c = P(x, 114)
        let base = circle(c, L(27))
        withShadow(color: salmonDeep.withAlphaComponent(0.8), blur: L(6)) {
            salmonDeep.setFill()
            base.fill()
        }
        NSGradient(starting: salmonLight, ending: salmonDeep)?.draw(in: base, angle: -90)
        let stick = circle(NSPoint(x: c.x, y: c.y + L(2.5)), L(21))
        withShadow(color: NSColor.black.withAlphaComponent(0.45), blur: L(3), offset: NSSize(width: 0, height: -L(1.5))) {
            control.setFill()
            stick.fill()
        }
        NSGradient(starting: controlTop, ending: control)?.draw(in: stick, angle: -90)
    }

    // Center button with its white status light.
    let sc = P(190, 118)
    withShadow(color: NSColor.white, blur: L(10)) {
        NSColor.white.setFill()
        circle(sc, L(15)).fill()
    }
    shellEdge.setStroke()
    let ring = circle(sc, L(13))
    ring.lineWidth = max(1, L(1.5))
    NSColor.white.setFill()
    ring.fill()
    ring.stroke()
    control.setFill()
    let mark = NSBezierPath()
    mark.appendRoundedRect(NSRect(x: sc.x - L(6), y: sc.y + L(0.5), width: L(12), height: L(3.2)), xRadius: L(1.6), yRadius: L(1.6))
    mark.appendRoundedRect(NSRect(x: sc.x - L(4), y: sc.y - L(4.5), width: L(8), height: L(3.2)), xRadius: L(1.6), yRadius: L(1.6))
    mark.fill()
}

/// Renders the badged icon at `size` pixels.
func renderLauncherIcon(base: NSImage, size: Int, badge: Bool) -> NSBitmapImageRep? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    let s = CGFloat(size)
    base.draw(in: NSRect(x: 0, y: 0, width: s, height: s), from: .zero, operation: .sourceOver, fraction: 1)
    if badge {
        let d = 0.52 * s  // large enough to read in the Dock and in Launchpad
        drawControllerBadge(in: NSRect(x: s - d - 0.012 * s, y: 0.012 * s, width: d, height: d))
    }
    ctx.flushGraphics()
    return rep
}

func makeLauncherIcon(for app: URL, badge: Bool, workDir: URL) throws -> URL {
    let base = NSWorkspace.shared.icon(forFile: app.path)
    base.size = NSSize(width: 1024, height: 1024)
    let iconset = workDir.appendingPathComponent("AppIcon.iconset")
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let px = points * scale
            guard let rep = renderLauncherIcon(base: base, size: px, badge: badge),
                  let png = rep.representation(using: .png, properties: [:]) else { throw ZError("cannot render the icon") }
            let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
            try png.write(to: iconset.appendingPathComponent(name))
        }
    }
    let icns = workDir.appendingPathComponent("AppIcon.icns")
    let r = try run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", icns.path])
    guard r.status == 0 else { throw ZError("iconutil failed: \(r.output)") }
    return icns
}

/// `zstadia icon <Game.app> <out.png>`: preview of the launcher icon.
func iconCommand(_ args: [String]) throws {
    guard args.count >= 2 else { throw ZError("Usage: zstadia icon \"/path/to/Game.app\" preview.png") }
    let base = NSWorkspace.shared.icon(forFile: (args[0] as NSString).expandingTildeInPath)
    base.size = NSSize(width: 1024, height: 1024)
    guard let rep = renderLauncherIcon(base: base, size: 1024, badge: true),
          let png = rep.representation(using: .png, properties: [:]) else { throw ZError("cannot render the icon") }
    try png.write(to: URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath))
    Out.ok("icon preview written")
}
