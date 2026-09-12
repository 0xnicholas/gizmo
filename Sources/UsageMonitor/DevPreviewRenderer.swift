#if DEBUG
import AppKit
import ApplicationServices
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

        // 菜单栏图标全态:三态色数字 + 灰「—」 + 陈旧标记(IC-3:超 2× 轮询间隔降透明度);
        // 每态顺带打印 a11y 一行说明(IC-2 验收)
        menubarIcon(PreviewData.normalState(), name: "menubar-icon-normal.png", into: directory, contrast: .normal, staleness: true)
        menubarIcon(PreviewData.lowState(), name: "menubar-icon-low.png", into: directory, contrast: .low)
        menubarIcon(PreviewData.criticalState(), name: "menubar-icon-critical.png", into: directory, contrast: .critical)
        menubarIcon(PreviewData.staleState(), name: "menubar-icon-stale.png", into: directory, staleness: true)
        menubarIcon(PreviewData.freshState(), name: "menubar-icon-gray.png", into: directory)

        // 口径乙(IC-4+IC-5):DeepSeek 临界 + GLM 窗 65% → 数字绿(旧口径此处红);
        // DeepSeek-only 临界 → 彩色「—」(旧口径永久灰)。menubarContrast 报告字形 rgb 供验收。
        menubarIcon(PreviewData.deepseekCriticalWithWindowsState(), name: "menubar-icon-deepseek-critical-window65.png", into: directory, contrast: .normal)
        menubarIcon(PreviewData.deepseekOnlyCriticalState(), name: "menubar-icon-deepseek-only-critical.png", into: directory, contrast: .critical)

        print("已渲染到:\(directory.path)")
    }

    private static func seeded(_ state: EngineState, selection: AppModel.SettingsSelection = .general) -> AppModel {
        let model = AppModel()
        model.injectPreviewState(state)
        model.settingsSelection = selection
        return model
    }

    /// 菜单栏图标渲染:统一挂 a11y 一行说明报告(IC-2 验收),口径文案与渲染用同一 state。
    private static func menubarIcon(
        _ state: EngineState,
        name: String,
        into directory: URL,
        contrast: ProviderStatus? = nil,
        staleness: Bool = false
    ) {
        write(
            MenuBarLabelView(model: seeded(state)),
            name: name,
            into: directory,
            padding: 8,
            menubarContrast: contrast,
            menubarStaleness: staleness,
            menubarAccessibility: IconAccessibilityPresentation(state: state).text
        )
    }

    private static func write<V: View>(
        _ view: V,
        name: String,
        into directory: URL,
        appearance: NSAppearance.Name = .aqua,
        padding: CGFloat = 0,
        menubarContrast: ProviderStatus? = nil,
        menubarStaleness: Bool = false,
        menubarAccessibility: String? = nil
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
        window.isReleasedWhenClosed = false
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

        // a11y 报告放最后:要把窗口上屏才能走 AX 运行时,读完即撤下。
        if let a11y = menubarAccessibility {
            menubarAccessibilityReport(expected: a11y, window: window)
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

    /// 菜单栏图标 a11y 一行说明报告(IC-2 验收):先打印口径文案,再把窗口短暂上屏、
    /// 用 AX 运行时从可访问性树里读回真实挂上的 label——验证 .accessibilityLabel
    /// 真正生效,而不只是字符串算得对。读完即撤下窗口,不污染下一个状态的查询;
    /// 树里读不到时以口径文案为准、Accessibility Inspector 手检。
    private static func menubarAccessibilityReport(expected: String, window: NSWindow) {
        print("- 菜单栏 a11y 一行(IC-2):\(expected)")
        window.orderFrontRegardless()
        for _ in 0..<6 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        let read = axTextStrings()
        window.orderOut(nil)
        window.close()
        if read.contains(where: { $0.contains(expected) }) {
            print("    树中读到:\(expected)")
        } else if !read.isEmpty {
            print("    树中文案:\(read.joined(separator: " | ")) ——未见口径文案,人工核对")
        } else {
            print("    (可访问性树未暴露;以口径文案为准,Accessibility Inspector 手检)")
        }
    }

    /// 收集当前上屏窗口可访问性子树的全部文案(desc/value)。SwiftUI 的 a11y
    /// 元素不经 NSView(NSHostingView 的 accessibilityChildren() 恒空),须走
    /// AX 运行时桥;本进程自查免辅助功能授权。
    private static func axTextStrings() -> [String] {
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement]
        else { return [] }
        return windows.flatMap { axTextStrings(of: $0) }
    }

    private static func axTextStrings(of element: AXUIElement, depth: Int = 0) -> [String] {
        guard depth < 6 else { return [] }
        var strings: [String] = []
        for attribute in [kAXDescriptionAttribute, kAXValueAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
               let text = value as? String, !text.isEmpty {
                strings.append(text)
            }
        }
        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children {
                strings.append(contentsOf: axTextStrings(of: child, depth: depth + 1))
            }
        }
        return strings
    }
}
#endif
