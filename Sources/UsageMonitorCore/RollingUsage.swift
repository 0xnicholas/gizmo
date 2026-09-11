import Foundation

/// 近 7 天用量(rollingUsage)。只在 provider 有直接用量数据源时提供。
///
/// `nil`(快照没有该字段)表示该 provider 无直接来源,卡片**不渲染**这一行;
/// `.failed` 表示有来源但本次获取失败,卡片渲染「— 获取失败」而其余字段照常。
public enum RollingUsage: Codable, Equatable, Sendable {
    case value(amount: Double, unit: String)
    case failed
}
