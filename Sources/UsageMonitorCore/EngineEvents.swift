import Foundation

/// 引擎对外发布的事件。App 壳把其中的预警事件翻译成 UNUserNotification 本地通知,
/// 其余用于刷新 UI 状态。通知限流(24h 静默)已在引擎内按注入时钟判定。
public enum EngineEvent: Equatable, Sendable {
    /// 快照已更新(含启动时从缓存发布)。
    case snapshotUpdated(Provider)
    /// 某家 plan-window / 余额档位跨入临界(已通过 24h 静默判定)。
    case usageCritical(UsageAlert)
    /// 某家从临界恢复。
    case usageRecovered(Provider)
    /// 凭据进入失效(401 重试后仍失败或被清除),已通过 24h 静默判定。
    case credentialInvalid(Provider)
    /// 凭据恢复可用。
    case credentialRestored(Provider)
    /// networkError 连续失败达到阈值 →「加载失败」态。
    case loadFailed(Provider, lastSuccessAt: Date?)
    /// 从「加载失败」态恢复。
    case loadRecovered(Provider)

    public var provider: Provider {
        switch self {
        case .snapshotUpdated(let provider),
             .usageRecovered(let provider),
             .credentialInvalid(let provider),
             .credentialRestored(let provider),
             .loadFailed(let provider, _),
             .loadRecovered(let provider):
            return provider
        case .usageCritical(let alert):
            return alert.provider
        }
    }
}
