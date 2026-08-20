//
//  generate-app-icon.swift
//  Renders the app icon into Assets.xcassets/AppIcon.appiconset.
//
//  The icon is drawn programmatically so it can be regenerated: a dark
//  terminal squircle with tmux-style split panes, one state dot per pane in
//  the app's traffic-light colors (blocked red, working green, idle gray),
//  and the green tmux status bar at the bottom. Sizes at or below 64 px use
//  a simplified composition (dots + status bar only) so the icon still
//  reads in the Dock's smallest renditions.
//
//  Usage (from the project root):
//      xcrun swift scripts/generate-app-icon.swift
//

import AppKit

// MARK: - Palette

let backgroundTop = NSColor(srgbRed: 0.161, green: 0.196, blue: 0.247, alpha: 1)
let backgroundBottom = NSColor(srgbRed: 0.075, green: 0.094, blue: 0.125, alpha: 1)
let paneBorder = NSColor(srgbRed: 0.235, green: 0.278, blue: 0.349, alpha: 1)
let textBar = NSColor(srgbRed: 0.275, green: 0.325, blue: 0.416, alpha: 1)
let textBarDim = NSColor(srgbRed: 0.227, green: 0.271, blue: 0.353, alpha: 1)
let statusGreen = NSColor(srgbRed: 0.137, green: 0.557, blue: 0.298, alpha: 1)
let statusGreenDark = NSColor(srgbRed: 0.098, green: 0.412, blue: 0.224, alpha: 1)
let dotGreen = NSColor(srgbRed: 0.196, green: 0.843, blue: 0.294, alpha: 1)
let dotRed = NSColor(srgbRed: 1.0, green: 0.271, blue: 0.227, alpha: 1)
let dotGray = NSColor(srgbRed: 0.596, green: 0.596, blue: 0.616, alpha: 1)

// MARK: - Drawing helpers (1024-point canvas, y-up)

func roundedBar(centerX: CGFloat, centerY: CGFloat, width: CGFloat, height: CGFloat = 36) -> NSBezierPath {
    NSBezierPath(
        roundedRect: NSRect(
            x: centerX - width / 2, y: centerY - height / 2, width: width, height: height),
        xRadius: height / 2, yRadius: height / 2)
}

func fillDot(center: NSPoint, radius: CGFloat, color: NSColor) {
    NSGraphicsContext.current?.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = color.withAlphaComponent(0.55)
    glow.shadowBlurRadius = 34
    glow.shadowOffset = .zero
    glow.set()
    color.setFill()
    NSBezierPath(
        ovalIn: NSRect(
            x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    ).fill()
    NSGraphicsContext.current?.restoreGraphicsState()
}

func drawIcon(simplified: Bool) {
    // Apple icon grid: an 824-point squircle centered on a 1024 canvas.
    let squircleRect = NSRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: squircleRect, xRadius: 186, yRadius: 186)

    // Baked drop shadow, as in Apple's icon template.
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 22
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    backgroundBottom.setFill()
    squircle.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    NSGraphicsContext.current?.saveGraphicsState()
    squircle.addClip()

    NSGradient(starting: backgroundTop, ending: backgroundBottom)?
        .draw(in: squircleRect, angle: -90)

    // tmux status bar along the bottom edge.
    statusGreen.setFill()
    NSRect(x: 100, y: 100, width: 824, height: 126).fill()
    statusGreenDark.setFill()
    if simplified {
        NSRect(x: 160, y: 136, width: 220, height: 54).fill()
    } else {
        NSBezierPath(
            roundedRect: NSRect(x: 150, y: 134, width: 190, height: 58), xRadius: 12, yRadius: 12
        ).fill()
        NSBezierPath(
            roundedRect: NSRect(x: 700, y: 134, width: 150, height: 58), xRadius: 12, yRadius: 12
        ).fill()
    }

    if simplified {
        // Small sizes: only the three state dots, oversized.
        fillDot(center: NSPoint(x: 288, y: 590), radius: 108, color: dotRed)
        fillDot(center: NSPoint(x: 512, y: 590), radius: 108, color: dotGreen)
        fillDot(center: NSPoint(x: 736, y: 590), radius: 108, color: dotGray)
        NSGraphicsContext.current?.restoreGraphicsState()
        return
    }

    // Pane borders: one vertical split, right column split horizontally.
    paneBorder.setFill()
    NSRect(x: 100, y: 226, width: 824, height: 8).fill()
    NSRect(x: 545, y: 226, width: 8, height: 698).fill()
    NSRect(x: 553, y: 573, width: 371, height: 8).fill()

    // Left pane: a working agent (green), with terminal text and a cursor.
    fillDot(center: NSPoint(x: 232, y: 796), radius: 46, color: dotGreen)
    textBar.setFill()
    roundedBar(centerX: 405, centerY: 796, width: 210).fill()
    textBarDim.setFill()
    roundedBar(centerX: 322, centerY: 688, width: 315).fill()
    roundedBar(centerX: 276, centerY: 608, width: 223).fill()
    roundedBar(centerX: 216, centerY: 508, width: 103).fill()
    dotGreen.withAlphaComponent(0.9).setFill()
    NSRect(x: 300, y: 486, width: 52, height: 44).fill()

    // Right top pane: a blocked agent (red).
    fillDot(center: NSPoint(x: 632, y: 796), radius: 46, color: dotRed)
    textBar.setFill()
    roundedBar(centerX: 782, centerY: 796, width: 160).fill()
    textBarDim.setFill()
    roundedBar(centerX: 728, centerY: 688, width: 245).fill()

    // Right bottom pane: an idle agent (gray).
    fillDot(center: NSPoint(x: 632, y: 476), radius: 46, color: dotGray)
    textBar.setFill()
    roundedBar(centerX: 782, centerY: 476, width: 160).fill()
    textBarDim.setFill()
    roundedBar(centerX: 700, centerY: 368, width: 190).fill()

    NSGraphicsContext.current?.restoreGraphicsState()
}

// MARK: - Rendering

func renderPNG(pixels: Int, to url: URL) throws {
    guard
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: rep)
    else { throw NSError(domain: "icon", code: 1) }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let scale = NSAffineTransform()
    scale.scale(by: CGFloat(pixels) / 1024)
    scale.concat()
    drawIcon(simplified: pixels <= 64)
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icon", code: 2)
    }
    try png.write(to: url)
}

let iconSetPath = FileManager.default.currentDirectoryPath
    + "/TmuxAgentWatch/Assets.xcassets/AppIcon.appiconset"
guard FileManager.default.fileExists(atPath: iconSetPath) else {
    fputs("run from the project root: \(iconSetPath) not found\n", stderr)
    exit(1)
}

// (point size, scale) entries required for the mac idiom.
let entries: [(size: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
    (256, 1), (256, 2), (512, 1), (512, 2),
]

var images: [[String: String]] = []
for entry in entries {
    let pixels = entry.size * entry.scale
    let name = "icon_\(entry.size)x\(entry.size)\(entry.scale == 2 ? "@2x" : "").png"
    try renderPNG(pixels: pixels, to: URL(fileURLWithPath: "\(iconSetPath)/\(name)"))
    images.append([
        "filename": name,
        "idiom": "mac",
        "scale": "\(entry.scale)x",
        "size": "\(entry.size)x\(entry.size)",
    ])
    print("rendered \(name) (\(pixels)px)")
}

let contents: [String: Any] = [
    "images": images,
    "info": ["author": "xcode", "version": 1],
]
let json = try JSONSerialization.data(
    withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: URL(fileURLWithPath: "\(iconSetPath)/Contents.json"))
print("wrote Contents.json")
