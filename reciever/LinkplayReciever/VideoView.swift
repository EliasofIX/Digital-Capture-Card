import Cocoa
import AppKit

// Simple NSView subclass to display a CGImage
class VideoView: NSView {
    var image: CGImage? {
        didSet {
            // Request redraw whenever the image changes
            // Ensure this happens on the main thread if image is set from background
             DispatchQueue.main.async {
                 self.needsDisplay = true
             }
        }
    }

    // Ensure drawing happens on a CALayer for better performance
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true // Back the view with a CALayer
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.wantsLayer = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Get the current graphics context
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Clear the background (optional, depends on desired behavior)
        context.setFillColor(NSColor.black.cgColor)
        context.fill(bounds)

        if let img = image {
            // Calculate destination rect to draw the image, maintaining aspect ratio
            let imgWidth = CGFloat(img.width)
            let imgHeight = CGFloat(img.height)
            let imgAspectRatio = imgWidth / imgHeight
            let viewAspectRatio = bounds.width / bounds.height

            var drawRect = bounds

            if imgAspectRatio > viewAspectRatio {
                // Image is wider than view aspect ratio; fit width, calculate height
                drawRect.size.height = bounds.width / imgAspectRatio
                drawRect.origin.y = (bounds.height - drawRect.size.height) / 2.0
            } else {
                // Image is taller than view aspect ratio; fit height, calculate width
                drawRect.size.width = bounds.height * imgAspectRatio
                drawRect.origin.x = (bounds.width - drawRect.size.width) / 2.0
            }

            // Flip the context vertically because CGImage origin is bottom-left, NSView is top-left
            context.saveGState()
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1.0, y: -1.0)

            // Draw the image in the calculated rect
            context.draw(img, in: drawRect)

            context.restoreGState()
        }
    }

    // Make the view resizable by default
    override var isFlipped: Bool {
        return true // Often simplifies coordinate handling, but we flipped manually above
    }
}

