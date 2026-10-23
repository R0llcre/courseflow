import AppKit

// Vector-drawn local asset; no downloaded artwork or image-generation dependency.
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
func render(_ pixels: Int, filename: String) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(pixels) / 1024
    NSGraphicsContext.current!.cgContext.scaleBy(x: scale, y: scale)
    let rect = NSRect(x: 0, y: 0, width: 1024, height: 1024)
    let background = NSBezierPath(roundedRect: rect.insetBy(dx: 22, dy: 22), xRadius: 224, yRadius: 224)
    let gradient = NSGradient(starting: NSColor(srgbRed: 0.9, green: 0.95, blue: 1, alpha: 1),
        ending: NSColor(srgbRed: 0.55, green: 0.73, blue: 0.96, alpha: 1))!
    gradient.draw(in: background, angle: -50)
    let back = NSBezierPath(roundedRect: NSRect(x: 240, y: 240, width: 500, height: 600), xRadius: 82, yRadius: 82)
    NSColor.white.withAlphaComponent(0.45).setFill(); back.fill()
    let front = NSBezierPath(roundedRect: NSRect(x: 190, y: 180, width: 500, height: 600), xRadius: 82, yRadius: 82)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = NSColor(srgbRed: 0.15, green: 0.3, blue: 0.6, alpha: 0.17)
    shadow.shadowBlurRadius = 30; shadow.shadowOffset = NSSize(width: 12, height: -18); shadow.set()
    NSColor.white.withAlphaComponent(0.96).setFill(); front.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor(srgbRed: 0.25, green: 0.43, blue: 0.73, alpha: 0.25).setFill()
    for width in [CGFloat(280), CGFloat(220)] {
        let y: CGFloat = width == 280 ? 650 : 550
        NSBezierPath(roundedRect: NSRect(x: 280, y: y, width: width, height: 24), xRadius: 12, yRadius: 12).fill()
    }
    let seal = NSBezierPath(ovalIn: NSRect(x: 492, y: 165, width: 300, height: 300))
    NSColor(srgbRed: 0.196, green: 0.412, blue: 0.855, alpha: 1).setFill(); seal.fill()
    let check = NSBezierPath(); check.lineWidth = 30; check.lineCapStyle = .round; check.lineJoinStyle = .round
    check.move(to: NSPoint(x: 566, y: 315)); check.line(to: NSPoint(x: 624, y: 262)); check.line(to: NSPoint(x: 726, y: 366))
    NSColor.white.setStroke(); check.stroke()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG export failed") }
    try png.write(to: destination.appendingPathComponent(filename))
}
var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let filename = "mac-\(size)@\(scale)x.png"
        try render(size * scale, filename: filename)
        images.append(["idiom":"mac", "size":"\(size)x\(size)", "scale":"\(scale)x", "filename":filename])
    }
}
try render(1024, filename: "ios-1024.png")
images.append(["idiom":"universal", "platform":"ios", "size":"1024x1024", "filename":"ios-1024.png"])
let contents: [String: Any] = ["images":images, "info":["author":"xcode", "version":1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: destination.appendingPathComponent("Contents.json"))
