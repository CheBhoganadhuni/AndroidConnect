import AppKit

/// O+Connect-inspired color palette — always light, matches asset screenshots.
enum OPTheme {

    // MARK: - Accent
    static let accent      = NSColor(red: 0.04, green: 0.47, blue: 1.00, alpha: 1)   // #0A78FF
    static let accentTint  = NSColor(red: 0.04, green: 0.47, blue: 1.00, alpha: 0.10)

    // MARK: - Backgrounds
    static let appBg       = NSColor(red: 0.965, green: 0.965, blue: 0.965, alpha: 1) // #F7F7F7
    static let sidebarBg   = NSColor.white
    static let popoverBg   = NSColor.white
    static let cardBg      = NSColor.white
    static let toolbarBg   = NSColor.white

    // MARK: - Text
    static let title       = NSColor(white: 0.08, alpha: 1)
    static let body        = NSColor(white: 0.30, alpha: 1)
    static let dim         = NSColor(white: 0.60, alpha: 1)

    // MARK: - Borders
    static let border      = NSColor(white: 0, alpha: 0.08)
    static let divider     = NSColor(white: 0, alpha: 0.05)

    // MARK: - Status
    static let online      = NSColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1)
    static let offline     = NSColor(white: 0.75, alpha: 1)

    // MARK: - Source indicator dots (matches O+Connect)
    static let dotWhatsApp  = NSColor(red: 0.07, green: 0.77, blue: 0.45, alpha: 1)
    static let dotDownloads = NSColor(red: 0.04, green: 0.47, blue: 1.00, alpha: 1)
    static let dotDCIM      = NSColor(red: 1.00, green: 0.58, blue: 0.00, alpha: 1)
    static let dotBluetooth = NSColor(red: 0.39, green: 0.51, blue: 1.00, alpha: 1)
    static let dotRecent    = NSColor(red: 0.55, green: 0.35, blue: 1.00, alpha: 1)

    // MARK: - Helpers

    /// Round NSView painted in `color` — use for source indicator dots.
    static func dot(color: NSColor, size: CGFloat = 8) -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        v.wantsLayer = true
        v.layer?.cornerRadius  = size / 2
        v.layer?.backgroundColor = color.cgColor
        return v
    }

    /// Blue circle icon container matching the O+Connect header logo look.
    static func iconBadge(symbolName: String, badgeSize: CGFloat = 28) -> NSView {
        let badge = NSView(frame: NSRect(x: 0, y: 0, width: badgeSize, height: badgeSize))
        badge.wantsLayer = true
        badge.layer?.cornerRadius    = badgeSize / 2
        badge.layer?.backgroundColor = accent.cgColor

        let img = NSImageView()
        img.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        img.contentTintColor = .white
        img.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(img)
        NSLayoutConstraint.activate([
            img.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            img.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            img.widthAnchor.constraint(equalToConstant: badgeSize * 0.55),
            img.heightAnchor.constraint(equalToConstant: badgeSize * 0.55),
        ])
        return badge
    }
}
