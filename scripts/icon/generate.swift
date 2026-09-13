// 生成应用图标(#49,原型 A「菜单栏窗格」):深色石板 + 圆体「65%」+ 状态色下划条。
// 无 Xcode 依赖:AppKit/CoreGraphics 直接绘制,iconutil 成 icns。
//
// 用法:<swift> scripts/icon/generate.swift [输出目录]
//   <swift> 指 swift.org 独立工具链(本机系统 swift 不可用,见 AGENTS.md);
//   输出目录默认 scripts/icon/;产物 AppIcon.icns 与 *.iconset/(中间 PNG,便于人工核对)。
// 图标为静态(状态由菜单栏承载):数字/颜色取演示值 65% / 绿。
// 修改绘制参数后重跑即可全套重出;提交仓库的 icns 即本脚本产物。

import AppKit

// MARK: - 绘制参数(集中于此,改完重跑)

enum Spec {
    /// 数字(不含 %,小尺寸档不显 %)。
    static let percentDigits = "65"
    /// 石板渐变(与菜单栏/深色 popover 同族)。
    static let slabTop = NSColor(srgbRed: 0.227, green: 0.239, blue: 0.267, alpha: 1)   // #3a3d44
    static let slabBottom = NSColor(srgbRed: 0.110, green: 0.118, blue: 0.133, alpha: 1) // #1c1e22
    /// 状态条渐变(系统绿,App 三态口径的演示档)。
    static let barTop = NSColor(srgbRed: 0.188, green: 0.820, blue: 0.345, alpha: 1)    // #30d158
    static let barBottom = NSColor(srgbRed: 0.157, green: 0.655, blue: 0.271, alpha: 1) // #28a745
    static let figureColor = NSColor(srgbRed: 0.961, green: 0.961, blue: 0.969, alpha: 1) // #f5f5f7

    /// 单档布局:全部比例为 /size,小尺寸(<48px)与常规档各一套。
    /// 小尺寸取舍:顶栏横条退场(会糊成噪点)、去 %(读不出)、数字加粗占满、
    /// 状态条加厚——16px 的识别特征是「深色块 + 绿条」。
    struct Layout {
        var showsStrip: Bool        // 顶部菜单栏横条示意
        var showsPercentGlyph: Bool // 数字后是否带 %
        var stripWidthRatio: CGFloat
        var stripYRatio: CGFloat
        var stripHeightRatio: CGFloat
        var fontSizeRatio: CGFloat
        var weight: NSFont.Weight
        /// 常规档:数字基线(自底边);小尺寸档改用垂直居中,此值忽略。
        var figureBaselineRatio: CGFloat
        /// 小尺寸档:数字区垂直居中后再上移的比例(给下方状态条让位)。
        var centeredLiftRatio: CGFloat
        var barWidthRatio: CGFloat
        var barHeightRatio: CGFloat
        var barYRatio: CGFloat
    }

    /// 小于此值走 small 档。
    static let smallCutoff: CGFloat = 48

    static let regular = Layout(
        showsStrip: true,
        showsPercentGlyph: true,
        stripWidthRatio: 0.586,
        stripYRatio: 0.805,
        stripHeightRatio: 0.052,
        fontSizeRatio: 0.322,
        weight: .semibold,
        figureBaselineRatio: 0.402,
        centeredLiftRatio: 0,
        barWidthRatio: 0.449,
        barHeightRatio: 0.062,
        barYRatio: 0.176
    )

    static let small = Layout(
        showsStrip: false,
        showsPercentGlyph: false,
        stripWidthRatio: 0,
        stripYRatio: 0,
        stripHeightRatio: 0,
        fontSizeRatio: 0.56,
        weight: .bold,
        figureBaselineRatio: 0,
        centeredLiftRatio: 0.06,
        barWidthRatio: 0.62,
        barHeightRatio: 0.14,
        barYRatio: 0.10
    )

    static func layout(for size: CGFloat) -> Layout {
        size < smallCutoff ? small : regular
    }
}

// MARK: - 形状

/// macOS 图标的连续圆角近似:超椭圆 |x/a|ⁿ + |y/a|ⁿ = 1(n≈4.7),采样成闭合路径。
/// 圆角矩形 rx≈22.5% 的直角拐点在此被磨圆,更贴近平台 squircle。
func squirclePath(size: CGFloat) -> NSBezierPath {
    let a = size / 2
    let n: Double = 4.7
    let samples = 128
    let path = NSBezierPath()
    for i in 0..<samples {
        let t = Double(i) / Double(samples) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = a * CGFloat((ct < 0 ? -1.0 : 1.0) * pow(abs(ct), 2 / n))
        let y = a * CGFloat((st < 0 ? -1.0 : 1.0) * pow(abs(st), 2 / n))
        if i == 0 { path.move(to: NSPoint(x: a + x, y: a + y)) } else { path.line(to: NSPoint(x: a + x, y: a + y)) }
    }
    path.close()
    return path
}

func roundedRect(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, r: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r)
}

/// 圆体系统字(SF Pro Rounded);失败退回常规系统字,不致命。
func roundedFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    if let descriptor = base.fontDescriptor.withDesign(.rounded),
       let font = NSFont(descriptor: descriptor, size: size) {
        return font
    }
    return base
}

// MARK: - 单尺寸绘制

/// 图标本体,坐标系 0..size、原点左下(绘制前已平移)。布局参数见 `Spec.layout(for:)`。
func drawIcon(size: CGFloat) {
    let layout = Spec.layout(for: size)

    // 1. 石板:超椭圆 + 垂直渐变 + 内侧发丝线
    let slab = squirclePath(size: size)
    NSGradient(colors: [Spec.slabTop, Spec.slabBottom])!.draw(in: slab, angle: -90)
    let inset = max(1, size * 0.004)
    let hairline = squirclePath(size: size - inset * 2)
    NSColor(white: 1, alpha: 0.16).setStroke()
    hairline.lineWidth = max(1, size * 0.006)
    hairline.stroke()

    // 2. 顶栏横条(菜单栏条示意):小尺寸档退场
    if layout.showsStrip {
        let stripWidth = size * layout.stripWidthRatio
        NSColor(white: 1, alpha: 0.07).setFill()
        roundedRect(
            x: (size - stripWidth) / 2,
            y: size * layout.stripYRatio,
            w: stripWidth,
            h: size * layout.stripHeightRatio,
            r: size * layout.stripHeightRatio / 2
        ).fill()
    }

    // 3. 数字
    let text = layout.showsPercentGlyph ? Spec.percentDigits + "%" : Spec.percentDigits
    let font = roundedFont(size: size * layout.fontSizeRatio, weight: layout.weight)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Spec.figureColor]
    let bounds = (text as NSString).size(withAttributes: attrs)
    let textY = layout.showsStrip
        ? size * layout.figureBaselineRatio
        : (size - bounds.height) / 2 + size * layout.centeredLiftRatio
    (text as NSString).draw(at: NSPoint(x: (size - bounds.width) / 2, y: textY), withAttributes: attrs)

    // 4. 状态条:圆角矩形,小尺寸档加厚(16px 时是主要识别特征)
    let barHeight = size * layout.barHeightRatio
    let barWidth = size * layout.barWidthRatio
    let bar = roundedRect(
        x: (size - barWidth) / 2,
        y: size * layout.barYRatio,
        w: barWidth,
        h: barHeight,
        r: barHeight / 2
    )
    NSGradient(colors: [Spec.barTop, Spec.barBottom])!.draw(in: bar, angle: -90)
}

// MARK: - 位图与 iconset

func renderPNG(size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.cgContext.setShouldAntialias(true)
    NSGraphicsContext.current?.cgContext.interpolationQuality = .high
    drawIcon(size: size)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// iconset 全套(16–1024 含 @2x);绘制按像素逐档重出,小尺寸配比单独调优。
let iconsetSizes: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

let outputDir = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: #filePath) // scripts/icon/generate.swift → 同目录
        .deletingLastPathComponent()
let iconsetDir = outputDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

for entry in iconsetSizes {
    let data = renderPNG(size: CGFloat(entry.px))
    try data.write(to: iconsetDir.appendingPathComponent(entry.name))
}

// iconutil 成 icns(CLT 自带,无 Xcode 依赖)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetDir.path, "-o", outputDir.appendingPathComponent("AppIcon.icns").path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil 失败(退出码 \(process.terminationStatus))\n".data(using: .utf8)!)
    exit(1)
}
print("已生成:\(outputDir.appendingPathComponent("AppIcon.icns").path)(\(iconsetSizes.count) 档)")
