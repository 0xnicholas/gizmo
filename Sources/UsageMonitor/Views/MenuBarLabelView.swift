import SwiftUI
import UsageMonitorCore

struct MenuBarLabelView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let presentation = GlobalPercentPresentation(state: model.state, scheme: scheme)
        Text(presentation.text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(presentation.color)
            // 陈旧标记(IC-3):数字降透明度,不再假装新鲜;成功刷新后自然恢复。
            .opacity(presentation.isStale ? 0.55 : 1)
            // a11y 一行说明(IC-2):VoiceOver 读完整口径(最紧窗 + 全局最差),
            // 不只读图标本体的数字。
            .accessibilityLabel(IconAccessibilityPresentation(state: model.state).text)
    }
}
