#!/usr/bin/env swift
/// Generates AppIcon.icns for the Android Connect Mac app.
/// Run once from project root: swift MacApp/generate_icon.swift
/// Output: MacApp/Resources/AppIcon.icns

import AppKit
import Foundation

func drawIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()

    // Rounded rect clip (macOS icon shape)
    let radius = size * 0.225
    let rect   = NSRect(x: 0, y: 0, width: size, height: size)
    let clip   = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    clip.addClip()

    // Blue gradient background
    let topBlue    = NSColor(red: 0.14, green: 0.56, blue: 1.00, alpha: 1)
    let bottomBlue = NSColor(red: 0.00, green: 0.32, blue: 0.88, alpha: 1)
    let grad = NSGradient(starting: topBlue, ending: bottomBlue)!
    grad.draw(in: rect, angle: -80)

    // Subtle inner shadow ring
    let ringInset = size * 0.04
    let ringPath  = NSBezierPath(ovalIn: rect.insetBy(dx: ringInset, dy: ringInset))
    NSColor.white.withAlphaComponent(0.10).setStroke()
    ringPath.lineWidth = size * 0.012
    ringPath.stroke()

    // White antenna symbol
    if let symbol = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right",
                             accessibilityDescription: nil) {
        let sw: CGFloat = size * 0.58
        let sh = symbol.size.height * (sw / max(symbol.size.width, 1))
        let drawRect = NSRect(x: (size - sw) / 2,
                              y: (size - sh) / 2 + size * 0.02,
                              width: sw, height: sh)
        let cfg = NSImage.SymbolConfiguration(paletteColors: [.white])
        (symbol.withSymbolConfiguration(cfg) ?? symbol).draw(in: drawRect)
    }

    img.unlockFocus()
    return img
}

func pngData(for img: NSImage) -> Data? {
    guard let tiff = img.tiffRepresentation,
          let rep  = NSBitmapImageRep(data: tiff) else { return nil }
    return rep.representation(using: .png, properties: [:])
}

// ── Create iconset ────────────────────────────────────────────────────────────

let root      = URL(fileURLWithPath: CommandLine.arguments.first ?? ".").deletingLastPathComponent()
let iconset   = URL(fileURLWithPath: "/tmp/AppIcon.iconset")
let outDir    = root.appendingPathComponent("MacApp/Resources")
let outFile   = outDir.appendingPathComponent("AppIcon.icns")

try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(at: outDir,  withIntermediateDirectories: true)

let specs: [(Int, String)] = [
    (16,   "icon_16x16"),
    (32,   "icon_16x16@2x"),
    (32,   "icon_32x32"),
    (64,   "icon_32x32@2x"),
    (128,  "icon_128x128"),
    (256,  "icon_128x128@2x"),
    (256,  "icon_256x256"),
    (512,  "icon_256x256@2x"),
    (512,  "icon_512x512"),
    (1024, "icon_512x512@2x"),
]

for (size, name) in specs {
    guard let png = pngData(for: drawIcon(size: CGFloat(size))) else {
        print("⚠ skipped \(name)"); continue
    }
    let dest = iconset.appendingPathComponent("\(name).png")
    try! png.write(to: dest)
}
print("✓ Iconset written")

// ── Convert to ICNS ───────────────────────────────────────────────────────────

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments     = ["-c", "icns", iconset.path, "-o", outFile.path]
try! proc.run(); proc.waitUntilExit()

if proc.terminationStatus == 0 {
    print("✓ AppIcon.icns → \(outFile.path)")
} else {
    print("✗ iconutil failed"); exit(1)
}
