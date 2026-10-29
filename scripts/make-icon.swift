// Рисует иконку Ait и собирает Resources/AppIcon.icns.
// Запуск: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Сетка иконок macOS: тело 824/1024 с отступом 100 и скруглением ~185.
    let inset = s * 100 / 1024
    let body = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let shape = NSBezierPath(roundedRect: body, xRadius: s * 185 / 1024, yRadius: s * 185 / 1024)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = s * 18 / 1024
    shadow.shadowOffset = NSSize(width: 0, height: -s * 8 / 1024)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    let gradient = NSGradient(colors: [
        NSColor(red: 0.07, green: 0.78, blue: 0.66, alpha: 1),
        NSColor(red: 0.16, green: 0.42, blue: 0.93, alpha: 1),
        NSColor(red: 0.29, green: 0.25, blue: 0.85, alpha: 1),
    ])!
    gradient.draw(in: shape, angle: -60)

    // Белая звуковая волна по центру.
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let white = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let rect = NSRect(x: (s - symbol.size.width) / 2, y: (s - symbol.size.height) / 2,
                          width: symbol.size.width, height: symbol.size.height)
        white.draw(in: rect)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! render(1024).write(to: root.appendingPathComponent("Resources/AppIcon-1024.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "AppIcon.icns ready" : "iconutil failed")
