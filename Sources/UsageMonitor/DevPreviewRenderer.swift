#if DEBUG
import AppKit
import SwiftUI
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

        // 设置窗口:通用 + 三种凭据形态
        write(SettingsWindowView(model: seeded(PreviewData.overviewState(), selection: .general)), name: "settings-general.png", into: directory)
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

        // 菜单栏图标全态:三态色数字 + 灰「—」(验收:数字/色/灰迁移、无角标)
        write(MenuBarLabelView(model: seeded(PreviewData.normalState())), name: "menubar-icon-normal.png", into: directory, padding: 8)
        write(MenuBarLabelView(model: seeded(PreviewData.lowState())), name: "menubar-icon-low.png", into: directory, padding: 8)
        write(MenuBarLabelView(model: seeded(PreviewData.criticalState())), name: "menubar-icon-critical.png", into: directory, padding: 8)
        write(MenuBarLabelView(model: seeded(PreviewData.freshState())), name: "menubar-icon-gray.png", into: directory, padding: 8)

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
        padding: CGFloat = 0
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

        // 深色形态仅供人工/OCR 核对文案与暗色适配
        hosting.appearance = NSAppearance(named: .darkAqua)
        hosting.layoutSubtreeIfNeeded()
        if let darkRep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: darkRep)
            if let darkData = darkRep.representation(using: .png, properties: [:]) {
                try? darkData.write(to: directory.appendingPathComponent("dark-" + name))
                report(name: "dark-" + name, hosting: hosting, rep: darkRep, imageData: darkData)
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
