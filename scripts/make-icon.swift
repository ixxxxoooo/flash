// 生成 Flash 应用图标：青蓝渐变圆角方块 + 白色闪电
// 用法：swift scripts/make-icon.swift <输出 appiconset 目录>
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Flash/Assets.xcassets/AppIcon.appiconset"

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()
    let rect = NSRect(x: s * 0.06, y: s * 0.06, width: s * 0.88, height: s * 0.88)
    let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.2, yRadius: s * 0.2)

    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = s * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    let gradient = NSGradient(colors: [
        NSColor(red: 0.20, green: 0.86, blue: 0.86, alpha: 1),
        NSColor(red: 0.10, green: 0.50, blue: 0.92, alpha: 1),
        NSColor(red: 0.30, green: 0.30, blue: 0.85, alpha: 1),
    ])!
    gradient.draw(in: path, angle: -60)

    // 顶部高光，模拟玻璃质感
    NSGraphicsContext.current?.saveGraphicsState()
    path.addClip()
    let hl = NSGradient(colors: [NSColor.white.withAlphaComponent(0.38), NSColor.white.withAlphaComponent(0)])!
    hl.draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    let config = NSImage.SymbolConfiguration(pointSize: s * 0.5, weight: .bold)
        .applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let sz = symbol.size
        let target = NSRect(x: (s - sz.width) / 2, y: (s - sz.height) / 2, width: sz.width, height: sz.height)
        NSGraphicsContext.current?.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        glow.shadowBlurRadius = s * 0.02
        glow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
        glow.set()
        symbol.draw(in: target)
        NSGraphicsContext.current?.restoreGraphicsState()
    }
    image.unlockFocus()
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(pt: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [[String: String]] = []
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for (pt, scale) in sizes {
    let name = "icon_\(pt)x\(pt)@\(scale)x.png"
    try render(size: pt * scale).write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(scale)x", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
let data = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent("Contents.json"))
print("已生成 \(images.count) 个图标尺寸 → \(outDir)")
