#if DEBUG
import AppKit
import SwiftUI
import UserNotifications
import UsageMonitorCore
import Vision

/// 开发期离屏渲染:本机没有 Xcode(Xcode Previews 不可用),用真实视图渲染成 PNG 做形态检查。
///
/// 入口:`UsageMonitor --render-previews <目录>`(仅 DEBUG 构建)。
@MainActor
enum DevPreviewRenderer {
    /// 命令行里请求了离屏渲染则执行并返回 true(App 随后退出,不进常驻路径)。
    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--render-previews") else { return false }
        let directory = arguments.count > flag + 1
            ? arguments[flag + 1]
            : NSTemporaryDirectory() + "usage-monitor-previews"
        render(into: URL(fileURLWithPath: directory))
        return true
    }

    static func render(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // 每个形态都出浅色 + 深色两份(深色底对 OCR 更友好,便于核对文案)
        for provider in Provider.displayOrder {
            let model = seeded(PreviewData.overviewState())
            model.focusProvider = provider
            write(PopoverView(model: model).frame(width: 360), name: "popover-\(provider.rawValue).png", into: directory)
        }
        write(PopoverView(model: seeded(PreviewData.freshState())).frame(width: 360), name: "popover-fresh.png", into: directory)
        write(PopoverView(model: seeded(PreviewData.errorState())).frame(width: 360), name: "popover-errors.png", into: directory)
        write(PopoverView(model: seeded(PreviewData.normalState())).frame(width: 360), name: "popover-normal.png", into: directory)
        write(PopoverView(model: seeded(PreviewData.lowState())).frame(width: 360), name: "popover-low.png", into: directory)
        write(PopoverView(model: seeded(PreviewData.criticalState())).frame(width: 360), name: "popover-critical.png", into: directory)
        let readFailure = seeded(PreviewData.readFailureState())
        readFailure.focusProvider = .glm
        write(PopoverView(model: readFailure).frame(width: 360), name: "popover-credential-read-failure.png", into: directory)

        // G(P2-1):脚注刷新反馈——刷新中「刷新中…」+ 保留上次更新(完成高亮为瞬时态,人工确认)
        let refreshing = seeded(PreviewData.overviewState())
        refreshing.injectPreviewIsRefreshing(true)
        write(PopoverView(model: refreshing).frame(width: 360), name: "popover-refreshing.png", into: directory)

        // FC-5:DeepSeek 卡两态——popover-deepseek 不可用(红条),此处常态(无可用状态行)
        let deepseekNormal = seeded(PreviewData.normalState())
        deepseekNormal.focusProvider = .deepseek
        write(PopoverView(model: deepseekNormal).frame(width: 360), name: "popover-deepseek-available.png", into: directory)

        // 设置窗口:通用 + 三种凭据形态
        write(SettingsWindowView(model: seeded(PreviewData.overviewState(), selection: .general)), name: "settings-general.png", into: directory)
        // 登录开关两态(通用页;不注入则随本机 plist 漂移,固定两态便于核对)
        let loginOn = seeded(PreviewData.overviewState(), selection: .general)
        loginOn.injectPreviewLoginItemEnabled(true)
        write(SettingsWindowView(model: loginOn), name: "settings-login-on.png", into: directory)
        let loginOff = seeded(PreviewData.overviewState(), selection: .general)
        loginOff.injectPreviewLoginItemEnabled(false)
        write(SettingsWindowView(model: loginOff), name: "settings-login-off.png", into: directory)
        // 通知授权三种文案(通用页通知段;默认渲染只会拍到「查询中…」)
        let denied = seeded(PreviewData.overviewState(), selection: .general)
        denied.injectPreviewNotificationAuthorization(.denied)
        write(SettingsWindowView(model: denied), name: "settings-notification-denied.png", into: directory)
        let authorized = seeded(PreviewData.overviewState(), selection: .general)
        authorized.injectPreviewNotificationAuthorization(.authorized)
        write(SettingsWindowView(model: authorized), name: "settings-notification-authorized.png", into: directory)
        write(SettingsWindowView(model: seeded(PreviewData.overviewState(), selection: .provider(.glm))), name: "settings-configured.png", into: directory)
        write(SettingsWindowView(model: seeded(PreviewData.errorState(), selection: .provider(.kimi))), name: "settings-invalid.png", into: directory)
        write(SettingsWindowView(model: seeded(PreviewData.freshState(), selection: .provider(.deepseek))), name: "settings-missing.png", into: directory)

        // 设置窗口:保存成功 / 钥匙串写入失败横幅(与 --simulate-keychain-failure 同一文案路径)
        let savedNotice = seeded(PreviewData.overviewState(), selection: .provider(.glm))
        savedNotice.injectCredentialNotice(.saved, for: .glm)
        write(SettingsWindowView(model: savedNotice), name: "settings-saved-notice.png", into: directory)
        let keychainError = seeded(PreviewData.overviewState(), selection: .provider(.glm))
        keychainError.injectCredentialNotice(
            .error(KeychainCredentialStore.Failure.unexpectedStatus(-34018).localizedDescription),
            for: .glm
        )
        write(SettingsWindowView(model: keychainError), name: "settings-keychain-error.png", into: directory)

        // 菜单栏图标全态:三态色数字 + 灰「—」 + 陈旧标记(IC-3:超 2× 轮询间隔降透明度)
        write(MenuBarLabelView(model: seeded(PreviewData.normalState())), name: "menubar-icon-normal.png", into: directory, padding: 8, menubarContrast: .normal, menubarStaleness: true)
        write(MenuBarLabelView(model: seeded(PreviewData.lowState())), name: "menubar-icon-low.png", into: directory, padding: 8, menubarContrast: .low)
        write(MenuBarLabelView(model: seeded(PreviewData.criticalState())), name: "menubar-icon-critical.png", into: directory, padding: 8, menubarContrast: .critical)
        write(MenuBarLabelView(model: seeded(PreviewData.staleState())), name: "menubar-icon-stale.png", into: directory, padding: 8, menubarStaleness: true)
        write(MenuBarLabelView(model: seeded(PreviewData.freshState())), name: "menubar-icon-gray.png", into: directory, padding: 8)

        // 口径乙(IC-4+IC-5):DeepSeek 临界 + GLM 窗 65% → 数字绿(旧口径此处红);
        // DeepSeek-only 临界 → 彩色「—」(旧口径永久灰)。menubarContrast 报告字形 rgb 供验收。
        write(MenuBarLabelView(model: seeded(PreviewData.deepseekCriticalWithWindowsState())), name: "menubar-icon-deepseek-critical-window65.png", into: directory, padding: 8, menubarContrast: .normal)
        write(MenuBarLabelView(model: seeded(PreviewData.deepseekOnlyCriticalState())), name: "menubar-icon-deepseek-only-critical.png", into: directory, padding: 8, menubarContrast: .critical)

        print("已渲染到:\(directory.path)")
    }

    private static func seeded(_ state: EngineState, selection: AppModel.SettingsSelection = .general) -> AppModel {
        let model = AppModel()
        model.injectPreviewState(state)
        model.settingsSelection = selection
        return model
    }

    private static func write<V: View>(
        _ view: V,
        name: String,
        into directory: URL,
        appearance: NSAppearance.Name = .aqua,
        padding: CGFloat = 0,
        menubarContrast: ProviderStatus? = nil,
        menubarStaleness: Bool = false
    ) {
        let content = view.padding(padding)
        let hosting = NSHostingView(rootView: content)
        hosting.appearance = NSAppearance(named: appearance)
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        // 放进一个不显示的窗口:SwiftUI 才会构建可访问性树,便于把界面文本 dump 出来核对。
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            print("跳过 \(name):无法创建位图")
            return
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            print("跳过 \(name):无法编码 PNG")
            return
        }
        try? data.write(to: directory.appendingPathComponent(name))
        report(name: name, hosting: hosting, rep: rep, imageData: data)
        if let state = menubarContrast {
            menubarContrastReport(state: state, appearance: "浅色", rep: rep)
        }
        if menubarStaleness {
            menubarStalenessReport(appearance: "浅色", rep: rep)
        }

        // 深色形态仅供人工/OCR 核对文案与暗色适配
        hosting.appearance = NSAppearance(named: .darkAqua)
        hosting.layoutSubtreeIfNeeded()
        if let darkRep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: darkRep)
            if let darkData = darkRep.representation(using: .png, properties: [:]) {
                try? darkData.write(to: directory.appendingPathComponent("dark-" + name))
                report(name: "dark-" + name, hosting: hosting, rep: darkRep, imageData: darkData)
                if let state = menubarContrast {
                    menubarContrastReport(state: state, appearance: "深色", rep: darkRep)
                }
                if menubarStaleness {
                    menubarStalenessReport(appearance: "深色", rep: darkRep)
                }
            }
        }
    }

    /// 无 Xcode 时的形态检查手段:尺寸、留白像素占比、可访问性文本树。
    private static func report(name: String, hosting: NSView, rep: NSBitmapImageRep, imageData: Data) {
        let blank = blankPixelRatio(rep)
        print("- \(name)  size=\(Int(hosting.frame.width))x\(Int(hosting.frame.height))  blank=\(Int(blank * 100))%")
        // 本机没有 Xcode、模型也看不到图:用 Vision OCR 把界面上真正画出来的文字读回来核对。
        for line in recognizeText(in: imageData) {
            print("    \(line)")
        }
    }

    /// 对渲染结果做文本识别(中文 + 英文),输出按纵向位置排序的可见文案。
    private static func recognizeText(in imageData: Data) -> [String] {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return [] }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return ["(OCR 失败:\(error))"]
        }

        let observations = (request.results ?? []).sorted { lhs, rhs in
            let l = lhs.boundingBox, r = rhs.boundingBox
            if abs(l.midY - r.midY) > 0.01 { return l.midY > r.midY }
            return l.minX < r.minX
        }
        return observations.compactMap { $0.topCandidates(1).first?.string }
    }

    /// 菜单栏图标对比度报告(IC-1 验收):取样字形核心像素(不透明像素的众数,抗锯齿只影响边缘),
    /// 按审计 #25 的栏底基线算 WCAG 对比度。取原始像素值(设备色空间),与审计同口径。
    private static func menubarContrastReport(state: ProviderStatus, appearance: String, rep: NSBitmapImageRep) {
        let lightBaseline = StatusColorComponents(r8: 238, g8: 238, b8: 238) // 审计实测浅色栏
        let darkBaseline = StatusColorComponents(r8: 52, g8: 52, b8: 56) // 审计实测深色栏

        var counts: [Int: Int] = [:]
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.95 else { continue }
                guard let rgb = color.cgColor.components, rgb.count >= 3 else { continue }
                let key = (Int(rgb[0] * 255) << 16) | (Int(rgb[1] * 255) << 8) | Int(rgb[2] * 255)
                counts[key, default: 0] += 1
            }
        }
        guard let (key, _) = counts.max(by: { $0.value < $1.value }) else {
            print("- 菜单栏对比度(\(appearance) \(state.rawValue)):未取到字形像素")
            return
        }
        let glyph = StatusColorComponents(
            r8: (key >> 16) & 0xFF,
            g8: (key >> 8) & 0xFF,
            b8: key & 0xFF
        )
        let light = glyph.contrastRatio(against: lightBaseline)
        let dark = glyph.contrastRatio(against: darkBaseline)
        print("- 菜单栏对比度(\(appearance) \(state.rawValue)):字形 rgb=(\((key >> 16) & 0xFF),\((key >> 8) & 0xFF),\(key & 0xFF))  浅色栏 \(String(format: "%.2f", light)):1  深色栏 \(String(format: "%.2f", dark)):1")
    }

    /// 菜单栏图标陈旧标记报告(IC-3 验收):字形核心像素的不透明度众数——
    /// 陈旧时数字整体降透明度(~0.55),新鲜时 1.0。
    private static func menubarStalenessReport(appearance: String, rep: NSBitmapImageRep) {
        var buckets: [Int: Int] = [:] // 不透明度按 0.05 分桶,取众数(抗锯齿只影响边缘)
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.2 else { continue }
                buckets[Int((color.alphaComponent / 0.05).rounded()), default: 0] += 1
            }
        }
        guard let (bucket, _) = buckets.max(by: { $0.value < $1.value }) else {
            print("- 菜单栏陈旧(\(appearance)):未取到字形像素")
            return
        }
        let alpha = Double(bucket) * 0.05
        let verdict = alpha < 0.9 ? "带陈旧标记" : "不带标记"
        print("- 菜单栏陈旧(\(appearance)):字形不透明度 \(String(format: "%.2f", alpha)) → \(verdict)")
    }

    /// 完全透明/纯背景像素的占比:接近 100% 说明视图没画出来。
    private static func blankPixelRatio(_ rep: NSBitmapImageRep) -> Double {
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        guard width > 0, height > 0 else { return 1 }
        var transparent = 0
        var sampled = 0
        for x in stride(from: 0, to: width, by: 3) {
            for y in stride(from: 0, to: height, by: 3) {
                sampled += 1
                if let color = rep.colorAt(x: x, y: y), color.alphaComponent < 0.02 {
                    transparent += 1
                }
            }
        }
        return sampled == 0 ? 1 : Double(transparent) / Double(sampled)
    }

    /// 递归收集可访问性元素(角色 + 文本),作为「界面上有什么字」的机器可读快照。
    private static func accessibilityTree(_ view: NSView, depth: Int = 0) -> [String] {
        guard depth < 6 else { return [] }
        var lines: [String] = []
        if let children = view.accessibilityChildren() {
            for child in children {
                guard let element = child as? NSView else { continue }
                let role = element.accessibilityRole()?.rawValue ?? "?"
                let label = element.accessibilityLabel() ?? ""
                let value = (element as? NSTextField)?.stringValue ?? ""
                let text = [label, value].filter { !$0.isEmpty }.joined(separator: " | ")
                if !text.isEmpty {
                    lines.append(String(repeating: "  ", count: depth) + "\(role): \(text)")
                } else {
                    lines.append(contentsOf: accessibilityTree(element, depth: depth + 1))
                }
            }
        }
        return lines
    }
}
#endif
