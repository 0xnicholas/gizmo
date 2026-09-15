import Foundation

/// 手动到期声明(#58):用户对「App 无从得知有效期」的家(Kimi)的显式表态——
/// 「这个套餐已经不能用了」。
///
/// 与「登录自启已表态」同类:这是**用户声明**,不是 provider 事实。存储在 App 侧
/// UserDefaults(重启后仍在),不进快照缓存、不进 raw;呈现时必须标注
/// 「手动标记于 MM-dd」,不冒充官方结论。provider 侧能判时声明永不覆盖
/// (见 `PlanState.evaluate` 的判定顺序)。
public struct ManualPlanExpiry: Equatable, Sendable {
    /// 标记时刻:展示归属「手动标记于 MM-dd」,也是「这不是 provider 事实」的坐标。
    public var markedAt: Date

    public init(markedAt: Date) {
        self.markedAt = markedAt
    }
}

/// 手动标记到期的纯编辑逻辑:标记 / 取消 / 读取。
///
/// 只管声明值的语义——时间戳由调用方给(时钟单源)、取消 = 无声明、
/// 存储原文里只有 Date 才算声明(类型不符/缺失不误报已标记);
/// 存储键与 I/O 在 App 侧(不新增协议;先例 `LoginItemEditing` / `CredentialEditing` 的收口)。
public enum ManualPlanExpiryEditing {
    /// 标记为已到期:声明时刻 = 调用方给的当刻(App 用系统时钟,测试可拨)。
    public static func mark(at now: Date) -> ManualPlanExpiry {
        ManualPlanExpiry(markedAt: now)
    }

    /// 取消标记(已续订 / 恢复显示):结果是无声明,调用方据此移除存储条目。
    public static func clear() -> ManualPlanExpiry? { nil }

    /// 读取存储原文(UserDefaults 里的任意值):只有 Date 才构成声明。
    /// 非法存储值(类型不符/被外部改写)与缺失一样按「无声明」处理——不误报已标记。
    public static func declaration(fromStored value: Any?) -> ManualPlanExpiry? {
        guard let markedAt = value as? Date else { return nil }
        return ManualPlanExpiry(markedAt: markedAt)
    }
}

extension Provider {
    /// 是否提供手动到期标记(#58)。只给 App **无从得知有效期**、且「套餐到期」语义
    /// 成立的家(Kimi);有自动来源的家(GLM)不提供——自动判定优先,避免二义;
    /// DeepSeek 是余额型(恒 unknown),不在这套机制里。
    public var supportsManualPlanExpiry: Bool {
        self == .kimi
    }
}
