// 生成 Flash 应用图标：遵循 macOS 图标网格（1024 画布内 824 圆角方块）的蓝青渐变底 + 白色闪电
// 用法：swift scripts/make-icon.swift [输出 appiconset 目录] [母版 PNG 路径]
// 说明：使用 CGBitmapContext 按“精确像素”绘制，不依赖屏幕缩放，保证 16@1x 就是 16 像素。
// @author ygw
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Flash/Assets.xcassets/AppIcon.appiconset"
let masterPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil

/// 在 1024×1024 的设计坐标系中绘制图标，再整体缩放到目标像素尺寸
/// - Parameter px: 目标边长（像素）
/// - Returns: PNG 数据
func render(px: Int) -> Data {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)

    // 苹果图标网格：824 的圆角方块居中，四周各留 100 给阴影
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // 1) 投影
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: CGColor(gray: 0, alpha: 0.32))
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.addPath(bodyPath)
    ctx.fillPath()
    ctx.restoreGState()

    // 2) 渐变底色（左上青 → 中间蓝 → 右下靛）
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let colors = [
        CGColor(red: 0.25, green: 0.88, blue: 0.90, alpha: 1),
        CGColor(red: 0.13, green: 0.52, blue: 0.96, alpha: 1),
        CGColor(red: 0.33, green: 0.27, blue: 0.86, alpha: 1),
    ] as CFArray
    let gradient = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 0.52, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 140, y: 924), end: CGPoint(x: 884, y: 100), options: [])

    // 3) 顶部柔和高光
    let glossColors = [CGColor(gray: 1, alpha: 0.30), CGColor(gray: 1, alpha: 0)] as CFArray
    let gloss = CGGradient(colorsSpace: cs, colors: glossColors, locations: [0, 1])!
    ctx.drawLinearGradient(gloss, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 520), options: [])
    ctx.restoreGState()

    // 4) 内描边，增强边缘质感
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: 183, cornerHeight: 183, transform: nil))
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.28))
    ctx.setLineWidth(4)
    ctx.strokePath()
    ctx.restoreGState()

    // 5) 闪电：圆角折线直接构造单一实心路径（顶点处用切线圆弧倒圆角）
    let base: [CGPoint] = [
        CGPoint(x: 596, y: 826), CGPoint(x: 312, y: 478), CGPoint(x: 492, y: 478),
        CGPoint(x: 430, y: 200), CGPoint(x: 726, y: 566), CGPoint(x: 548, y: 566),
    ]
    // 以画布中心为基准整体放大，让闪电更舒展
    let pts = base.map { CGPoint(x: 512 + ($0.x - 512) * 1.16, y: 512 + ($0.y - 512) * 1.12) }
    let solid = CGMutablePath()
    let radius: CGFloat = 30
    solid.move(to: CGPoint(x: (pts[0].x + pts[1].x) / 2, y: (pts[0].y + pts[1].y) / 2))
    for i in 1...pts.count {
        solid.addArc(tangent1End: pts[i % pts.count], tangent2End: pts[(i + 1) % pts.count], radius: radius)
    }
    solid.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 26, color: CGColor(gray: 0, alpha: 0.32))
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.addPath(solid)
    ctx.fillPath()
    ctx.restoreGState()

    // 闪电内部的轻微明暗，避免纯白显得扁平
    ctx.saveGState()
    ctx.addPath(solid)
    ctx.clip()
    let boltColors = [CGColor(gray: 1, alpha: 0), CGColor(red: 0.62, green: 0.82, blue: 1.0, alpha: 0.6)] as CFArray
    let boltGradient = CGGradient(colorsSpace: cs, colors: boltColors, locations: [0, 1])!
    ctx.drawLinearGradient(boltGradient, start: CGPoint(x: 512, y: 700), end: CGPoint(x: 512, y: 200), options: [])
    ctx.restoreGState()

    let image = ctx.makeImage()!
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

let sizes: [(pt: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [[String: String]] = []
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for (pt, scale) in sizes {
    let name = "icon_\(pt)x\(pt)@\(scale)x.png"
    try render(px: pt * scale).write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(scale)x", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
let data = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent("Contents.json"))
if let masterPath { try render(px: 1024).write(to: URL(fileURLWithPath: masterPath)) }
print("已生成 \(images.count) 个图标尺寸 → \(outDir)")
