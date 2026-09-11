import Foundation

/// 百分比展示口径的单一实现:图标数字、总览条、临界通知文案共用,
/// 避免同一数值在三处各算一次(用户故事 18:两处数字不打架)。
public enum Percent {
    /// 剩余占比 → 展示用整数百分比。
    /// 规则:四舍五入,最低 1%,真 0 显示 0(剩余渺茫时仍给出可见的 1%)。
    public static func display(_ fraction: Double) -> Int {
        if fraction <= 0 { return 0 }
        return max(1, Int((fraction * 100).rounded()))
    }

    /// 原样四舍五入,不做下限钳制(进度条等中性场景)。
    public static func rounded(_ fraction: Double) -> Int {
        Int((fraction * 100).rounded())
    }
}
