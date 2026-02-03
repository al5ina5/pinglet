import SwiftUI
import AppKit

struct PingletMenuBarIcon: View {
    private let iconImage = PingletMenuBarIcon.makeTemplateImage()

    var body: some View {
        Image(nsImage: iconImage)
            .resizable()
            .frame(width: 18, height: 18)
            .offset(y: 2)
            .accessibilityLabel("Pinglet")
    }

    private static func makeTemplateImage() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        let inset: CGFloat = 3
        let rect = NSRect(x: inset, y: inset + 1, width: size.width - inset * 2, height: size.height - inset * 2)
        let path = NSBezierPath()
        let corner: CGFloat = 2.4

        let topLeft = NSPoint(x: rect.minX, y: rect.maxY)
        let topRight = NSPoint(x: rect.maxX, y: rect.maxY)
        let bottom = NSPoint(x: rect.midX, y: rect.minY)

        path.move(to: NSPoint(x: topLeft.x + corner, y: topLeft.y))
        path.line(to: NSPoint(x: topRight.x - corner, y: topRight.y))
        path.curve(
            to: NSPoint(x: topRight.x, y: topRight.y - corner),
            controlPoint1: NSPoint(x: topRight.x - corner * 0.2, y: topRight.y),
            controlPoint2: NSPoint(x: topRight.x, y: topRight.y - corner * 0.2)
        )
        path.line(to: NSPoint(x: bottom.x + corner * 0.35, y: bottom.y + corner * 0.6))
        path.curve(
            to: NSPoint(x: bottom.x - corner * 0.35, y: bottom.y + corner * 0.6),
            controlPoint1: NSPoint(x: bottom.x + corner * 0.2, y: bottom.y + corner * 0.2),
            controlPoint2: NSPoint(x: bottom.x - corner * 0.2, y: bottom.y + corner * 0.2)
        )
        path.line(to: NSPoint(x: topLeft.x, y: topLeft.y - corner))
        path.curve(
            to: NSPoint(x: topLeft.x + corner, y: topLeft.y),
            controlPoint1: NSPoint(x: topLeft.x, y: topLeft.y - corner * 0.2),
            controlPoint2: NSPoint(x: topLeft.x + corner * 0.2, y: topLeft.y)
        )
        path.close()

        NSColor.black.setFill()
        path.fill()

        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}
