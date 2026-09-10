import AppKit
import SwiftUI

@main
struct UsageMonitorApp: App {
    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            PlaceholderPopoverView()
        } label: {
            Text("—")
        }
        .menuBarExtraStyle(.window)
    }
}

private struct PlaceholderPopoverView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("用量监视器")
                .font(.headline)
            Text("暂无用量数据")
                .font(.callout)
                .foregroundStyle(.secondary)
            Divider()
            Button("退出用量监视器") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
        .frame(width: 260)
    }
}
