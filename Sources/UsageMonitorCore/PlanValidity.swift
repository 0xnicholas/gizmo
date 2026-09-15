import Foundation

/// 套餐有效期(planValidity):provider 侧订阅记录的归一化派生字段(词条见 CONTEXT「planValidity 套餐有效期」)。
///
/// 只承载展示与判定所需的派生值——有效期起止、「status」原值、是否自动续订、商品名。
/// 账单元数据(订单号/客户号/协议号/金额)在解析层即被丢弃:订阅分片原文**不进 raw**
/// (既有「raw 未知字段不丢」原则的明示例外,见 CONTEXT「raw 原文」)。
///
/// 快照里 `nil` = 无有效期信息(该 provider 无来源、分片失败、响应无记录或串畸形):
/// 界面不渲染有效期行,也不做任何到期断言。
public struct PlanValidity: Codable, Equatable, Sendable {
    public var validFrom: Date
    public var validUntil: Date
    /// provider 自报的状态原值(取值枚举未知):只作展示与诊断,不参与判定。
    public var status: String?
    /// 是否自动续订;nil = 响应未给该字段。
    public var autoRenew: Bool?
    public var productName: String?
    /// 该有效期最近一次成功取得的观测时刻(#54)。不是 provider 自报的字段,而是取数侧的
    /// 元数据:解析成功时 = 解析时刻;跨订阅分片失败保留旧值时**原样携带、不推进**——
    /// 到期结论的陈旧标注(见 `PlanState`)靠它区分「刚确认的到期」与「数据过旧的到期」。
    /// #54 前的旧缓存文件没有该字段,解出 nil(判定时回退快照 fetchedAt,见 `PlanState.evaluate`)。
    public var observedAt: Date?

    public init(
        validFrom: Date,
        validUntil: Date,
        status: String? = nil,
        autoRenew: Bool? = nil,
        productName: String? = nil,
        observedAt: Date? = nil
    ) {
        self.validFrom = validFrom
        self.validUntil = validUntil
        self.status = status
        self.autoRenew = autoRenew
        self.productName = productName
        self.observedAt = observedAt
    }

    /// 该区间是否覆盖某时刻:起刻含、末端不含(到期时刻当刻失效——与到期判定同一边界)。
    func covers(_ date: Date) -> Bool {
        validFrom <= date && date < validUntil
    }
}

extension PlanValidity {
    /// 有效期口径的时区:北京时间 +08:00。实测有效期串不带时区后缀,解析与展示**共用此常量**
    /// (任一处漂移都会让「有效期至」在跨时区机器上差一天)。
    public static let timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
}
