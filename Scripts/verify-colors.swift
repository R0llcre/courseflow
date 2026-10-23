import AppKit
// Resolve the compiled catalog, not its JSON. Integer strings such as "1" in
// Xcode colorsets are parsed as 8-bit 1/255, not normalized floating point 1.0.
guard CommandLine.arguments.count == 2, let bundle = Bundle(path: CommandLine.arguments[1]) else {
    fatalError("Pass the built .app path")
}
for appearance in [NSAppearance.Name.aqua, .darkAqua] {
    NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
        for name in ["AccentColor", "Canvas", "Paper"] {
            guard let color = NSColor(named: name, bundle: bundle)?.usingColorSpace(.sRGB) else {
                fatalError("Missing color: \(name)")
            }
            precondition(color.alphaComponent > 0.99, "Transparent color: \(name)")
            if appearance == .aqua && name == "Paper" {
                precondition(min(color.redComponent, color.greenComponent, color.blueComponent) > 0.99, "Light page must be white")
            }
            print("\(appearance.rawValue) \(name): RGBA \(color.redComponent), \(color.greenComponent), \(color.blueComponent), \(color.alphaComponent)")
        }
    }
}
