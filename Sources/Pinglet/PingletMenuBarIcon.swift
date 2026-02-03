import SwiftUI
import AppKit

struct PingletMenuBarIcon: View {
    private let iconImage = PingletMenuBarIcon.makeTemplateImage()

    var body: some View {
        Image(nsImage: iconImage)
            .resizable()
            .frame(width: 18, height: 18)
            .accessibilityLabel("Pinglet")
    }

    private static func makeTemplateImage() -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        let image = NSImage(systemSymbolName: "globe", accessibilityDescription: "Pinglet")?
            .withSymbolConfiguration(config)

        image?.isTemplate = true
        return image ?? NSImage(size: NSSize(width: 18, height: 18))
    }
}
