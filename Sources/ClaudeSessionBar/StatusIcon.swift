import AppKit

/// The menu bar icon, picked by how many sessions are waiting for you.
enum StatusIcon: Equatable {
    /// 0–1: tree.
    case clear
    /// 2–5: yellow banana.
    case few
    /// 7–10: orange.
    case many
    /// 11+: red flame.
    case overloaded
    /// Exactly 6 or 19: a cake, by request.
    case cake

    init(waiting: Int) {
        switch waiting {
        case 6, 19: self = .cake
        case ...1: self = .clear
        case 2...5: self = .few
        case 7...10: self = .many
        default: self = .overloaded
        }
    }

    var image: NSImage {
        let image: NSImage
        switch self {
        case .clear: image = Self.fitted(Self.emoji("🌳"), side: 16)
        case .few: image = Self.fitted(Self.emoji("🍌"), side: 16)
        case .many: image = Self.fitted(Self.emoji("🍊"), side: 16)
        case .overloaded: image = Self.fitted(Self.symbol("flame.fill", color: .systemRed), side: 16)
        case .cake: image = Self.fitted(Self.emoji("🎂"), side: 16)
        }
        image.isTemplate = false
        image.accessibilityDescription = "Claude Sessions"
        return image
    }

    /// A pale wash of the icon's own colour behind it, and a deep shade of it for the count.
    private var palette: (background: NSColor, text: NSColor) {
        switch self {
        case .clear: (NSColor(hex: 0xD1E7DD), NSColor(hex: 0x0A3622))
        case .few: (NSColor(hex: 0xFFF3CD), NSColor(hex: 0x664D03))
        case .many: (NSColor(hex: 0xFFE5D0), NSColor(hex: 0x7A3A06))
        case .overloaded: (NSColor(hex: 0xF8D7DA), NSColor(hex: 0x58151C))
        case .cake: (NSColor(hex: 0xF7D6E6), NSColor(hex: 0x6B1A43))
        }
    }

    /// The icon and the waiting count (if any) on a capsule, drawn as one image so the count's
    /// colour does not depend on the menu bar's appearance.
    func badge(count: Int) -> NSImage {
        let icon = image
        let colors = palette
        let text = NSAttributedString(
            string: count > 0 ? String(count) : "",
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold), .foregroundColor: colors.text])
        let textSize = text.size()
        let height: CGFloat = 20
        let leading: CGFloat = 4
        let trailing: CGFloat = count > 0 ? 8 : 4
        let gap: CGFloat = count > 0 ? 2 : 0
        let width = (leading + icon.size.width + gap + textSize.width + trailing).rounded(.up)
        let result = NSImage(size: NSSize(width: width, height: height), flipped: false) { bounds in
            colors.background.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: height / 2, yRadius: height / 2).fill()
            icon.draw(in: NSRect(x: leading, y: (height - icon.size.height) / 2, width: icon.size.width, height: icon.size.height))
            text.draw(at: NSPoint(x: leading + icon.size.width + gap, y: (height - textSize.height) / 2))
            return true
        }
        result.isTemplate = false
        result.accessibilityDescription = icon.accessibilityDescription
        return result
    }

    /// The status bar clips images taller than it is, and symbol/emoji images carry their own
    /// padding and baseline. Redraw them aspect-fit into an 18pt square so nothing is cut off.
    private static func fitted(_ source: NSImage, side: CGFloat) -> NSImage {
        let canvas: CGFloat = 18
        return NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { _ in
            let scale = min(side / source.size.width, side / source.size.height)
            let size = NSSize(width: source.size.width * scale, height: source.size.height * scale)
            source.draw(in: NSRect(
                x: (canvas - size.width) / 2, y: (canvas - size.height) / 2, width: size.width, height: size.height))
            return true
        }
    }

    private static func symbol(_ name: String, color: NSColor) -> NSImage {
        // Drawn large and scaled down by `fitted`, which keeps it sharp on Retina.
        let configuration = NSImage.SymbolConfiguration(pointSize: 48, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) ?? NSImage()
    }

    private static func emoji(_ character: String) -> NSImage {
        let text = NSAttributedString(string: character, attributes: [.font: NSFont.systemFont(ofSize: 48)])
        let size = text.size()
        return NSImage(size: size, flipped: false) { _ in
            text.draw(at: .zero)
            return true
        }
    }
}

extension NSColor {
    convenience init(hex: Int) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
