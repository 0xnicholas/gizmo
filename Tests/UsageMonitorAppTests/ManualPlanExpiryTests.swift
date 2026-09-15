import Foundation
import Testing
import UsageMonitorCore
@testable import UsageMonitor

/// 手动到期声明的 UserDefaults 存储(#58):「标记重启后仍生效」的持久化端——
/// 写入后用新实例读回即模拟重启;取消移除条目;非法存储值按「无声明」处理。
/// (声明的判定与生效在 Core:`PlanState` 的手动案 + 引擎注入口,由 Core 单测覆盖。)
@Suite("手动到期声明:UserDefaults 存储(#58)")
struct ManualPlanExpiryStoreTests {
    /// 每个用例独立域(套件内用例并行跑,共享域会互相串),用完即销。
    private static func scratchDefaults() -> (defaults: UserDefaults, suite: String) {
        let suite = "UsageMonitorTests.ManualPlanExpiryStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    @Test("往返:标记落盘、新实例读回(重启后仍生效)")
    func roundTrip() {
        let scratch = Self.scratchDefaults()
        defer { scratch.defaults.removePersistentDomain(forName: scratch.suite) }
        let store = UserDefaultsManualPlanExpiryStore(defaults: scratch.defaults)
        let markedAt = Date(timeIntervalSince1970: 1_792_029_600)

        store.save(ManualPlanExpiry(markedAt: markedAt), for: .kimi)

        // 「重启」:新实例读同一份盘
        let reopened = UserDefaultsManualPlanExpiryStore(defaults: scratch.defaults)
        #expect(reopened.declaration(for: .kimi) == ManualPlanExpiry(markedAt: markedAt))
        #expect(reopened.all() == [.kimi: ManualPlanExpiry(markedAt: markedAt)])
        #expect(reopened.declaration(for: .glm) == nil)
    }

    @Test("取消:条目被移除,读回无声明(不是留一条空记录)")
    func clearRemovesEntry() {
        let scratch = Self.scratchDefaults()
        defer { scratch.defaults.removePersistentDomain(forName: scratch.suite) }
        let store = UserDefaultsManualPlanExpiryStore(defaults: scratch.defaults)
        store.save(ManualPlanExpiry(markedAt: Date(timeIntervalSince1970: 1_792_029_600)), for: .kimi)

        store.save(ManualPlanExpiryEditing.clear(), for: .kimi)

        #expect(store.declaration(for: .kimi) == nil)
        #expect(store.all().isEmpty)
    }

    @Test("非法存储值按「无声明」处理:不误报已标记,也不崩")
    func corruptValuesAreIgnored() {
        let scratch = Self.scratchDefaults()
        defer { scratch.defaults.removePersistentDomain(forName: scratch.suite) }
        scratch.defaults.set("a string, not a date", forKey: UserDefaultsManualPlanExpiryStore.keyPrefix + Provider.kimi.rawValue)

        let store = UserDefaultsManualPlanExpiryStore(defaults: scratch.defaults)
        #expect(store.declaration(for: .kimi) == nil)
        #expect(store.all().isEmpty)
    }
}

/// 手动标记的归属文案(#58):「手动标记于 MM-dd」——系统时区、到日
/// (「你何时标的」随本机钟,与 provider 有效期行的北京时间口径分家)。
@Suite("手动标记归属文案(#58)")
struct ManualPlanExpiryAttributionTests {
    @Test("按本机时区归日、月日补零")
    func formatsLocalDay() {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 5
        components.hour = 23
        components.minute = 30
        let date = Calendar.current.date(from: components)!
        #expect(Presentation.manualExpiryAttribution(date) == "手动标记于 09-05")
    }
}

/// App 壳接线(#58):一键标记 → 落盘 + 注入引擎 + 状态即更新;「重启」(新实例读同一份盘)
/// 后首个 state 就带声明。判定与口径由 Core 单测覆盖,这里只补「接线不断」。
@Suite("AppModel:手动标记接线(#58)")
@MainActor
struct AppModelManualPlanExpiryWiringTests {
    private struct StubCredentialStore: CredentialStore {
        func credential(for provider: Provider) throws -> String? { nil }
        func save(_ value: String, for provider: Provider) throws {}
        func delete(for provider: Provider) throws {}
    }

    private struct StubLoginItem: LoginItemControlling {
        var isEnabled: Bool { false }
        func setEnabled(_ enabled: Bool) throws {}
    }

    private static func scratchDefaults() -> (defaults: UserDefaults, suite: String) {
        let suite = "UsageMonitorTests.ManualPlanExpiryWiring.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    private static func makeModel(defaults: UserDefaults) -> AppModel {
        AppModel(defaults: defaults, credentials: StubCredentialStore(), loginItem: StubLoginItem())
    }

    @Test("标记/还原:落盘、注入、状态即更新;重启后仍在")
    func markAndUnmarkThroughTheAppShell() async {
        let scratch = Self.scratchDefaults()
        defer { scratch.defaults.removePersistentDomain(forName: scratch.suite) }
        let model = Self.makeModel(defaults: scratch.defaults)
        #expect(model.state.provider(.kimi).manualPlanExpiry == nil)

        model.setManualPlanExpiry(marked: true, for: .kimi)
        let marked = await Self.waitForDeclaration(of: model, provider: .kimi) { $0 != nil }
        #expect(marked != nil, "引擎状态应立即带上声明")

        // 「重启」:新实例读同一份盘 → 启动后的首次状态发布就带声明(引擎构造时注入;
        // AppModel 的占位 state 要等 bootstrap 那一次发布,这里用 refreshAll 驱动;
        // 凭据桩为空,读不到凭据即返回,不发网络请求)。
        let restarted = Self.makeModel(defaults: scratch.defaults)
        await restarted.refreshAll()
        #expect(restarted.state.provider(.kimi).manualPlanExpiry == marked)

        // 一键还原:状态与盘上条目一起复位
        restarted.setManualPlanExpiry(marked: false, for: .kimi)
        let cleared = await Self.waitForDeclaration(of: restarted, provider: .kimi) { $0 == nil }
        #expect(cleared == nil)
        #expect(UserDefaultsManualPlanExpiryStore(defaults: scratch.defaults).all().isEmpty)
    }

    @Test("入口适用面:GLM/DeepSeek 的标记请求不生效(有自动来源/不在这套机制里)")
    func unsupportedProvidersAreIgnored() async {
        let scratch = Self.scratchDefaults()
        defer { scratch.defaults.removePersistentDomain(forName: scratch.suite) }
        let model = Self.makeModel(defaults: scratch.defaults)

        model.setManualPlanExpiry(marked: true, for: .glm)
        model.setManualPlanExpiry(marked: true, for: .deepseek)
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(model.state.provider(.glm).manualPlanExpiry == nil)
        #expect(model.state.provider(.deepseek).manualPlanExpiry == nil)
        #expect(UserDefaultsManualPlanExpiryStore(defaults: scratch.defaults).all().isEmpty)
    }

    /// 等接线完成(Task 里注入引擎后再发布 state):轮询到条件成立或超时(上限 ~1s)。
    private static func waitForDeclaration(
        of model: AppModel,
        provider: Provider,
        until condition: (ManualPlanExpiry?) -> Bool
    ) async -> ManualPlanExpiry? {
        for _ in 0..<200 {
            let declaration = model.state.provider(provider).manualPlanExpiry
            if condition(declaration) { return declaration }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return model.state.provider(provider).manualPlanExpiry
    }
}
