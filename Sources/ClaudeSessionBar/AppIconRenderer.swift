import AppKit

/// Draws the app icon (a short session list on a dark macOS-style tile) and writes an .icns with
/// `--make-icon <path.icns>`; build.sh bundles the result.
enum AppIconRenderer {
    /// Draws on a 1024×1024 canvas with a top-left origin.
    private static func draw() {
        // Big Sur icon grid: an 824pt tile centred in the 1024pt canvas.
        let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
        let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
        NSGradient(
            starting: NSColor(srgbRed: 0.20, green: 0.19, blue: 0.18, alpha: 1),
            ending: NSColor(srgbRed: 0.09, green: 0.09, blue: 0.08, alpha: 1)
        )?.draw(in: tilePath, angle: 90)
        NSColor(white: 1, alpha: 0.08).setStroke()
        tilePath.lineWidth = 4
        tilePath.stroke()

        // Status dot colour and title length per row: waiting, running, done, idle.
        let rows: [(NSColor, CGFloat)] = [
            (NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1), 420),
            (NSColor(srgbRed: 0.29, green: 0.56, blue: 0.91, alpha: 1), 330),
            (NSColor(srgbRed: 0.36, green: 0.73, blue: 0.45, alpha: 1), 380),
            (NSColor(white: 0.55, alpha: 1), 290),
        ]
        let pitch: CGFloat = 132
        let top = 512 - pitch * CGFloat(rows.count - 1) / 2
        for (index, row) in rows.enumerated() {
            let centre = top + CGFloat(index) * pitch
            row.0.setFill()
            NSBezierPath(ovalIn: NSRect(x: 232, y: centre - 32, width: 64, height: 64)).fill()
            NSColor(white: 1, alpha: 0.24).setFill()
            NSBezierPath(roundedRect: NSRect(x: 340, y: centre - 22, width: row.1, height: 44), xRadius: 22, yRadius: 22).fill()
        }
    }

    private static func png(pixels: Int) -> Data? {
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let scale = CGFloat(pixels) / 1024
        let transform = NSAffineTransform()
        transform.translateX(by: 0, yBy: CGFloat(pixels))
        transform.scaleX(by: scale, yBy: -scale)
        transform.concat()
        draw()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    static func writeIcns(to path: String) -> Bool {
        let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
        try? FileManager.default.removeItem(at: iconset)
        try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                guard let data = png(pixels: points * scale) else { return false }
                try? data.write(to: iconset.appendingPathComponent(name))
            }
        }
        let out = Shell.run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", path], captureStderr: true)
        if out?.status != 0 { print(out?.stdout ?? "iconutil failed") }
        return out?.status == 0
    }

    static func writePreview(to path: String) -> Bool {
        guard let data = png(pixels: 1024) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}
