import AppKit

enum PinArtwork {
    static func image(size: CGFloat, template: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let inset = rect.insetBy(dx: size * 0.08, dy: size * 0.08)
            if let symbol = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "图钉") {
                let config = NSImage.SymbolConfiguration(pointSize: size * 0.8, weight: .medium)
                    .applying(.init(paletteColors: [template ? .black : .systemRed]))
                symbol.withSymbolConfiguration(config)?.draw(in: inset)
            }
            return true
        }
        image.isTemplate = template
        return image
    }

    static let cursor = NSCursor(image: image(size: 34), hotSpot: NSPoint(x: 12, y: 30))
}
