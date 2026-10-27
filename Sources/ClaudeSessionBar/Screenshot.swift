import AppKit

/// Composes the README picture: a menu bar strip with the status item, and the open popover below it.
enum Screenshot {
    static func write(to path: String, button: NSView, buttonFrame: NSRect, content: NSView, contentFrame: NSRect) -> Bool {
        let scale: CGFloat = 2
        let margin: CGFloat = 24
        let barHeight = buttonFrame.height
        let gap: CGFloat = 6
        let left = min(buttonFrame.minX, contentFrame.minX) - margin
        let right = max(buttonFrame.maxX, contentFrame.maxX) + margin
        let size = NSSize(width: right - left, height: barHeight + gap + contentFrame.height + margin)
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return false }
        rep.size = size
        let dark = content.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        content.effectiveAppearance.performAsCurrentDrawingAppearance {
            (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.97, alpha: 1)).setFill()
            NSRect(origin: .zero, size: size).fill()
            (dark ? NSColor(white: 0.24, alpha: 1) : NSColor(white: 0.88, alpha: 1)).setFill()
            NSRect(x: 0, y: size.height - barHeight, width: size.width, height: barHeight).fill()

            draw(button, in: NSRect(
                x: buttonFrame.minX - left, y: size.height - barHeight, width: buttonFrame.width, height: barHeight))

            let panel = NSRect(
                x: contentFrame.minX - left, y: size.height - barHeight - gap - contentFrame.height,
                width: contentFrame.width, height: contentFrame.height)
            let outline = NSBezierPath(roundedRect: panel, xRadius: 12, yRadius: 12)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.6 : 0.25)
            shadow.shadowBlurRadius = 14
            shadow.shadowOffset = NSSize(width: 0, height: -4)
            shadow.set()
            NSColor.windowBackgroundColor.setFill()
            outline.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState()
            outline.addClip()
            draw(content, in: panel)
            NSGraphicsContext.restoreGraphicsState()
            NSColor.separatorColor.setStroke()
            outline.lineWidth = 0.5
            outline.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    /// A window showing only the desktop picture behind the menu bar, so other apps' windows don't show through the
    /// translucent popover in a screen capture.
    static func wallpaperBackdrop(for screen: NSScreen?) -> NSWindow? {
        guard let screen, let url = NSWorkspace.shared.desktopImageURL(for: screen), let picture = NSImage(contentsOf: url)
        else { return nil }
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer?.contents = picture
        view.layer?.contentsGravity = .resizeAspectFill
        // Blue labels in the translucent popover are hard to read over a bright or bluish picture,
        // so only the menu bar keeps it; below that is a plain dark grey, like a window behind.
        let shade = CALayer()
        shade.frame = NSRect(x: 0, y: 0, width: screen.frame.width, height: screen.visibleFrame.maxY - screen.frame.minY)
        shade.backgroundColor = NSColor(white: 0.17, alpha: 1).cgColor
        view.layer?.addSublayer(shade)
        window.contentView = view
        window.orderFrontRegardless()
        return window
    }

    private static func draw(_ view: NSView, in rect: NSRect) {
        guard let cached = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: cached)
        cached.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
