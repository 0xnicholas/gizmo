import SwiftUI
import UsageMonitorCore

struct MenuBarLabelView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // 图标恒为 Kimi 一家(#59):数字取 Kimi 最紧套餐窗、颜色随 Kimi 自身状态;
        // 别家更紧不改图标(popover 总览条仍报全局最紧)。
        let presentation = MenuBarPercentPresentation(state: model.state, scheme: scheme)
        // 一行说明(#45 + #59):VoiceOver 与 tooltip 共用同一文案——图标只有一个数字,
        // 说明就只讲这一个数字的来历:哪窗多少、哪档,以及「—」是哪一种没有
        // (未配置 / 凭据失效 / 读取失败 / 到期 / 加载失败 / 尚无数据)。
        let oneLiner = MenuBarAccessibilityPresentation(state: model.state).text
        Text(presentation.text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(presentation.color)
            // 陈旧标记(IC-3):数字降透明度,不再假装新鲜;成功刷新后自然恢复。
            .opacity(presentation.isStale ? 0.55 : 1)
            // a11y 一行说明(IC-2):VoiceOver 读完整口径(哪窗多少 + 哪档),
            // 不只读图标本体的数字;tooltip 同文。
            .accessibilityLabel(oneLiner)
            .help(oneLiner)
    }
}
