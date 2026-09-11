import SwiftUI
import UsageMonitorCore

struct MenuBarLabelView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let presentation = MenuBarPresentation(state: model.state)
        Text(presentation.text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(presentation.color)
    }
}
