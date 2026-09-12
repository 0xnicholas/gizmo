import Foundation

/// 有时间边界、会周期重置的额度容器,是剩余额度与健康状态的最小计算单位。
public struct QuotaWindow: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// 套餐窗口(GLM 5 小时窗/7 天窗、Kimi 周窗):参与 status 推导。
        case planWindow = "plan-window"
        /// 频限窗口(Kimi 300 分钟滚动窗):只展示,不参与 status 推导。
        case rateLimit = "rate-limit"
    }

    public var kind: Kind
    /// provider 侧的窗口展示名(如「5 小时窗」「频限 · 滚动窗(300 分钟)」),由解析层归一化给出。
    public var label: String
    public var unit: String
    public var limit: Int
    public var used: Int
    public var remaining: Int
    public var resetAt: Date?

    public init(
        kind: Kind,
        label: String = "",
        unit: String,
        limit: Int,
        used: Int,
        remaining: Int,
        resetAt: Date?
    ) {
        self.kind = kind
        self.label = label
        self.unit = unit
        self.limit = limit
        self.used = used
        self.remaining = remaining
        self.resetAt = resetAt
    }
}
