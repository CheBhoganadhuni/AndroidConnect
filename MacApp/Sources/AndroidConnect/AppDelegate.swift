import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Always-light — O+Connect design language never goes dark
        NSApp.appearance = NSAppearance(named: .aqua)
        // Programmatic app icon — blue circle + antenna symbol
        NSApp.applicationIconImage = makeAppIcon()
        menuBar = MenuBarController()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // MARK: - App icon

    private func makeAppIcon() -> NSImage {
        let size: CGFloat = 512
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()

        // Blue filled circle with gentle padding
        let accent = NSColor(red: 0.04, green: 0.47, blue: 1.00, alpha: 1)
        accent.setFill()
        NSBezierPath(ovalIn: NSRect(x: 24, y: 24, width: size - 48, height: size - 48)).fill()

        // White antenna SF Symbol centred in the circle
        if let symbol = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right",
                                accessibilityDescription: nil) {
            let sw: CGFloat = 280
            let sh = symbol.size.height * (sw / max(symbol.size.width, 1))
            let drawRect = NSRect(x: (size - sw) / 2, y: (size - sh) / 2, width: sw, height: sh)

            let cfg = NSImage.SymbolConfiguration(paletteColors: [.white])
            (symbol.withSymbolConfiguration(cfg) ?? symbol).draw(in: drawRect)
        }
        img.unlockFocus()
        return img
    }
}
