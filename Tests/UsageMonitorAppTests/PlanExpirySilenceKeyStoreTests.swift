import Foundation
import Testing
import UsageMonitorCore
@testable import UsageMonitor

/// 到期提醒静默键的 UserDefaults 适配器(#57):跨重启的持久化靠它——「同一个有效期
/// 只提醒一次」在 App 重启后仍然成立(引擎与假件侧的单测见 Core 的
/// `PlanExpiryNoticeEngineTests`)。
@Suite("到期提醒静默键:UserDefaults 适配器(#57)")
struct PlanExpirySilenceKeyStoreAdapterTests {
    /// 每个用例独立域(套件内用例并行跑,共享域会互相串),用完即销。
    private static func scratchDefaults() -> (defaults: UserDefaults, suite: String) {
        let suite = "UsageMonitorTests.PlanExpirySilenceKeyStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    @Test("往返:按 provider 落盘、读回;有效期端点(Date)不失真")
    func roundTrip() {
        let scratch = Self.scratchDefaults()
        defer { scratch.defaults.removePersistentDomain(forName: scratch.suite) }
        let store = UserDefaultsPlanExpirySilenceKeyStore(defaults: scratch.defaults)
        let until = Date(timeIntervalSince1970: 1_792_029_600)  // 2026-10-15 10:00 +08:00

        store.save([
            .glm: PlanExpirySilenceKeys(approaching: until),
            .kimi: PlanExpirySilenceKeys(expired: until),
        ])

        // 「重启」:新实例读同一份盘
        let reopened = UserDefaultsPlanExpirySilenceKeyStore(defaults: scratch.defaults).load()
        #expect(reopened[.glm]?.approaching == until)
        #expect(reopened[.glm]?.expired == nil)
        #expect(reopened[.kimi]?.expired == until)
        #expect(reopened[.kimi]?.approaching == nil)
        #expect(reopened[.deepseek] == nil)
    }

    @Test("清除:不再持有的家对应键被移除,不残留空记录")
    func saveRemovesProvidersWithoutKeys() {
        let scratch = Self.scratchDefaults()
        defer { scratch.defaults.removePersistentDomain(forName: scratch.suite) }
        let store = UserDefaultsPlanExpirySilenceKeyStore(defaults: scratch.defaults)
        store.save([.glm: PlanExpirySilenceKeys(expired: Date(timeIntervalSince1970: 1_792_029_600))])

        store.save([:])

        #expect(store.load()[.glm] == nil)
    }

    @Test("损坏/非法值按「无记录」处理:不崩,方向偏「可能多提醒一次」而非静默失效")
    func corruptValuesAreIgnored() {
        let scratch = Self.scratchDefaults()
        defer { scratch.defaults.removePersistentDomain(forName: scratch.suite) }
        scratch.defaults.set(Data("not json".utf8), forKey: UserDefaultsPlanExpirySilenceKeyStore.keyPrefix + Provider.glm.rawValue)
        scratch.defaults.set("a string, not data", forKey: UserDefaultsPlanExpirySilenceKeyStore.keyPrefix + Provider.kimi.rawValue)

        let store = UserDefaultsPlanExpirySilenceKeyStore(defaults: scratch.defaults)
        #expect(store.load()[.glm] == nil)
        #expect(store.load()[.kimi] == nil)
    }
}
