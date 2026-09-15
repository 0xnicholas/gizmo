import Foundation
import UsageMonitorCore

/// 测试用快照构造助手:只描述行为相关字段,减少测试噪音。
enum Fixture {
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    static func window(
        kind: QuotaWindow.Kind,
        label: String = "",
        unit: String = "积分",
        limit: Int,
        used: Int? = nil,
        remaining: Int? = nil,
        resetAt: Date? = nil
    ) -> QuotaWindow {
        let usedValue = used ?? (limit - (remaining ?? limit))
        return QuotaWindow(
            kind: kind,
            label: label,
            unit: unit,
            limit: limit,
            used: usedValue,
            remaining: remaining ?? (limit - usedValue),
            resetAt: resetAt
        )
    }

    static func planWindow(limit: Int, remaining: Int, label: String = "窗口", unit: String = "积分", resetAt: Date? = nil) -> QuotaWindow {
        window(kind: .planWindow, label: label, unit: unit, limit: limit, remaining: remaining, resetAt: resetAt)
    }

    static func rateLimitWindow(limit: Int, remaining: Int, label: String = "频限") -> QuotaWindow {
        window(kind: .rateLimit, label: label, unit: "请求", limit: limit, remaining: remaining)
    }

    static func snapshot(
        provider: Provider,
        windows: [QuotaWindow] = [],
        balances: [Balance] = [],
        rollingUsage: RollingUsage? = nil,
        planValidity: PlanValidity? = nil,
        plan: Plan? = nil,
        fetchedAt: Date = Fixture.epoch,
        concurrencyLimit: Int? = nil,
        accountAvailable: Bool? = nil,
        raw: String = "{}"
    ) -> Snapshot {
        Snapshot(
            meta: SnapshotMeta(
                provider: provider,
                plan: plan,
                fetchedAt: fetchedAt,
                concurrencyLimit: concurrencyLimit,
                accountAvailable: accountAvailable
            ),
            windows: windows,
            balances: balances,
            rollingUsage: rollingUsage,
            planValidity: planValidity,
            raw: raw
        )
    }

    /// 套餐有效期样例:默认取实测区间(2026-09-15 10:00 → 2026-10-15 10:00, +08:00)。
    static func validity(
        validFrom: Date = Date(timeIntervalSince1970: 1_789_437_600),
        validUntil: Date = Date(timeIntervalSince1970: 1_792_029_600),
        status: String? = "VALID",
        autoRenew: Bool? = false,
        productName: String? = "GLM Coding Pro"
    ) -> PlanValidity {
        PlanValidity(
            validFrom: validFrom,
            validUntil: validUntil,
            status: status,
            autoRenew: autoRenew,
            productName: productName
        )
    }

    static func balance(_ kind: Balance.Kind, _ amount: String, currency: String = "CNY") -> Balance {
        Balance(type: kind, amount: Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX"))!, currency: currency)
    }
}

// MARK: - ProviderPayload 构造助手

extension ProviderPayload {
    /// 单分片成功响应。
    static func ok(_ json: String, part: FetchPart = .primary) -> ProviderPayload {
        ProviderPayload(parts: [part: .response(FetchResponse(statusCode: 200, body: Data(json.utf8)))])
    }

    static func response(_ json: String, part: FetchPart = .primary, statusCode: Int = 200) -> ProviderPayload {
        ProviderPayload(parts: [part: .response(FetchResponse(statusCode: statusCode, body: Data(json.utf8)))])
    }

    static func failure(_ failure: FetchFailure, part: FetchPart = .primary) -> ProviderPayload {
        ProviderPayload(parts: [part: .failure(failure)])
    }

    func merging(_ other: ProviderPayload) -> ProviderPayload {
        ProviderPayload(parts: parts.merging(other.parts) { _, new in new })
    }
}
