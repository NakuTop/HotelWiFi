import AppKit
import Foundation
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale, side = CGFloat(pixels)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let rect = NSRect(x: side*0.06, y: side*0.06, width: side*0.88, height: side*0.88)
        NSColor(calibratedRed: 0.06, green: 0.42, blue: 0.35, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: side*0.22, yRadius: side*0.22).fill()
        let config = NSImage.SymbolConfiguration(pointSize: side*0.56, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        if let wifi = NSImage(systemSymbolName: "wifi", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let ratio = wifi.size.width/wifi.size.height
            let width = side*0.64, height = width/ratio
            wifi.draw(in: NSRect(x:(side-width)/2,y:(side-height)/2,width:width,height:height))
        }
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent(name))
    }
}
