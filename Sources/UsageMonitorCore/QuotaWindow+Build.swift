import Foundation

extension QuotaWindow {
    /// 从 provider 的松散字段构造窗口:limit / used / remaining 三者可互相补全。
    /// limit 与 remaining 都无法确定时返回 nil(该行不建窗口,原文仍留在 raw)。
    static func make(
        kind: Kind,
        label: String,
        unit: String,
        limit: Any?,
        used: Any?,
        remaining: Any?,
        resetAt: Date?
    ) -> QuotaWindow? {
        let limitValue = JSONReader.int(limit)
        let usedValue = JSONReader.int(used)
        let remainingValue = JSONReader.int(remaining)

        let resolvedLimit = limitValue ?? {
            guard let usedValue, let remainingValue else { return nil }
            return usedValue + remainingValue
        }()
        let resolvedRemaining = remainingValue ?? {
            guard let limitValue, let usedValue else { return nil }
            return limitValue - usedValue
        }()
        guard let resolvedLimit, let resolvedRemaining else { return nil }

        return QuotaWindow(
            kind: kind,
            label: label,
            unit: unit,
            limit: resolvedLimit,
            used: usedValue ?? (resolvedLimit - resolvedRemaining),
            remaining: resolvedRemaining,
            resetAt: resetAt
        )
    }
}
