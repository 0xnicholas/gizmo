import Foundation
import UsageMonitorCore

/// 系统时钟适配器。
struct SystemClock: Clock {
    var now: Date { Date() }
}
