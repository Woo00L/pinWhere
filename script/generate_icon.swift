import AppKit

let destination = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let p = CGFloat(pixels)
        let rect = NSRect(x: p * 0.07, y: p * 0.07, width: p * 0.86, height: p * 0.86)
        let path = NSBezierPath(roundedRect: rect, xRadius: p * 0.2, yRadius: p * 0.2)
        NSGradient(starting: NSColor(calibratedRed: 1, green: 0.97, blue: 0.95, alpha: 1),
                   ending: NSColor(calibratedRed: 0.95, green: 0.87, blue: 0.85, alpha: 1))!.draw(in: path, angle: -90)
        let symbol = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)!
        let config = NSImage.SymbolConfiguration(pointSize: p * 0.55, weight: .medium)
            .applying(.init(paletteColors: [.systemRed]))
        symbol.withSymbolConfiguration(config)!.draw(in: NSRect(x: p * 0.24, y: p * 0.2, width: p * 0.52, height: p * 0.6))
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let url = URL(fileURLWithPath: destination).appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }
}
