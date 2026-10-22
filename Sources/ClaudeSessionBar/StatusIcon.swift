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
