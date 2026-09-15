import Foundation
import Testing
@testable import UsageMonitorCore

/// 引擎侧的到期提醒三类(#57):边沿 + 静默键。
///
/// 静默键是**有效期端点本身**,不是 24h 滚动静默:同一个端点只提醒一次,改系统时间或
/// 重启都不重复;端点一变(续订推后)自然复位。重启不重复用「两个引擎实例共享同一
/// 静默键存储」表达(start 读缓存 + 刷新两条路径都算,靠键去重,不靠不求值)。
@Suite("引擎:到期提醒三类(#57)")
struct PlanExpiryNoticeEngineTests {
    /// 与 Fixture.epoch 同刻:2023-11-15 06:13:20 +08:00。
    private let epoch = Fixture.epoch

    // MARK: - 构造:GLM 额度主分片 + 订阅分片(有效期端点用北京时间串)

    private static func glmPayload(validUntil: Date, autoRenew: Bool? = false) -> ProviderPayload {
        let from = subscriptionTime(validUntil.addingTimeInterval(-30 * 86_400))
        let to = subscriptionTime(validUntil)
        let autoRenewField = autoRenew.map { $0 ? "1" : "0" } ?? "null"
        let json = #"{"code":200,"data":[{"productName":"GLM Coding Pro","status":"VALID","valid":"\#(from)-\#(to)","autoRenew":\#(autoRenewField)}],"success":true}"#
        return Payloads.glm().merging(.ok(json, part: .subscription))
    }

    private static func subscriptionTime(_ date: Date) -> String {
        subscriptionFormatter.string(from: date)
    }

    private static let subscriptionFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = PlanValidity.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    /// 带有效期的缓存快照(start 路径用;刷新路径由订阅分片解析产出)。
    private static func cachedSnapshot(provider: Provider = .glm, validUntil: Date, autoRenew: Bool? = false) -> Snapshot {
        Fixture.snapshot(
            provider: provider,
            planValidity: PlanValidity(
                validFrom: validUntil.addingTimeInterval(-30 * 86_400),
                validUntil: validUntil,
                status: "VALID",
                autoRenew: autoRenew,
                productName: "GLM Coding Pro",
                observedAt: Fixture.epoch
            )
        )
    }

    private static func notice(
        _ kind: PlanExpiryNotice.Kind,
        validUntil: Date,
        provider: Provider = .glm,
        autoRenew: Bool? = false
    ) -> PlanExpiryNotice {
        PlanExpiryNotice(provider: provider, validUntil: validUntil, autoRenew: autoRenew, kind: kind)
    }

    // MARK: - 边沿:即将到期 → 已到期

    @Test("跨入「距到期 ≤ 3 天」发一次、到期当刻发一次,两者互不吞没;同一端点不重复")
    func approachingThenExpiredNeitherSwallowsTheOther() async {
        let validUntil = epoch.addingTimeInterval(5 * 86_400)
        let harness = EngineHarness(payloads: [.glm: Self.glmPayload(validUntil: validUntil)])

        // 窗外的常规轮询:不提醒
        var events = await harness.engine.refreshAll()
        #expect(events.planNotices.isEmpty)

        // 跨入 3 天窗(剩 2.5 天 → 剩 3 天,向上取整)
        harness.clock.advance(2.5 * 86_400)
        events = await harness.engine.refreshAll()
        #expect(events.planNotices == [Self.notice(.approaching(daysRemaining: 3), validUntil: validUntil)])

        // 停在窗内:不重复
        harness.clock.advance(3_600)
        events = await harness.engine.refreshAll()
        #expect(events.planNotices.isEmpty)

        // 到期当刻(now == validUntil,与 PlanState 同一边界):一条「已到期」
        harness.clock.advance(2.5 * 86_400 - 3_600)
        events = await harness.engine.refreshAll()
        #expect(events.planNotices == [Self.notice(.expired, validUntil: validUntil)])

        // 到期后持续刷新、跨过 24h:同一端点不再重复(不是滚动静默)
        harness.clock.advance(25 * 3_600)
        events = await harness.engine.refreshAll()
        #expect(events.planNotices.isEmpty)
    }

    @Test("改系统时间(倒拨出窗又拨回)不绕开静默键:同一端点只提醒一次")
    func clockChangesDoNotBypassTheSilenceKey() async {
        let validUntil = epoch.addingTimeInterval(2 * 86_400)  // 首次观察即落在窗内
        let harness = EngineHarness(payloads: [.glm: Self.glmPayload(validUntil: validUntil)])

        var events = await harness.engine.refreshAll()
        #expect(events.planNotices == [Self.notice(.approaching(daysRemaining: 2), validUntil: validUntil)])

        // 时钟倒拨出窗,再拨回窗内:静默键按端点比对,不因「又跨入一次」重发
        harness.clock.advance(-30 * 86_400)
        events = await harness.engine.refreshAll()
        #expect(events.planNotices.isEmpty)
        harness.clock.advance(29 * 86_400)
        events = await harness.engine.refreshAll()
        #expect(events.planNotices.isEmpty)
    }

    @Test("提醒天数参数化:expiryReminderDays 换实例即改提前量")
    func reminderDaysInjectable() async {
        var thresholds = Thresholds()
        thresholds.expiryReminderDays = 7
        let validUntil = epoch.addingTimeInterval(6 * 86_400)
        let harness = EngineHarness(
            thresholds: thresholds,
            payloads: [.glm: Self.glmPayload(validUntil: validUntil)]
        )

        let events = await harness.engine.refreshAll()
        #expect(events.planNotices == [Self.notice(.approaching(daysRemaining: 6), validUntil: validUntil)])
    }

    // MARK: - 重启不重复(共享静默键存储)

    @Test("启动读缓存即首次观察:缓存里的有效期已到期 → 当刻提醒一次,并落进静默键")
    func startFromCacheNotifiesOnFirstObservation() async {
        let validUntil = epoch.addingTimeInterval(-3_600)
        let store = InMemoryPlanExpirySilenceKeyStore()
        let harness = EngineHarness(cached: [.glm: Self.cachedSnapshot(validUntil: validUntil)], silenceKeys: store)

        let events = await harness.engine.start()
        #expect(events.planNotices == [Self.notice(.expired, validUntil: validUntil)])
        #expect(store.load()[.glm]?.expired == validUntil)
    }

    @Test("重启不重复「即将到期」:新引擎复用同一静默键存储,start 与刷新都静默")
    func restartDoesNotRepeatApproaching() async {
        let validUntil = epoch.addingTimeInterval(2 * 86_400)
        let store = InMemoryPlanExpirySilenceKeyStore()
        let clock = TestClock(epoch)
        let first = EngineHarness(
            payloads: [.glm: Self.glmPayload(validUntil: validUntil)],
            clock: clock,
            silenceKeys: store
        )
        let firstEvents = await first.engine.refreshAll()
        #expect(firstEvents.planNotices.count == 1)
        let persisted = first.cache.snapshots()[.glm]

        // 「重启」:新引擎实例、同一时钟、同一静默键存储,缓存里也带着同一个端点
        let restarted = EngineHarness(
            cached: [.glm: persisted].compactMapValues { $0 },
            payloads: [.glm: Self.glmPayload(validUntil: validUntil)],
            clock: clock,
            silenceKeys: store
        )
        #expect(await restarted.engine.start().planNotices.isEmpty)
        #expect(await restarted.engine.refreshAll().planNotices.isEmpty)
    }

    @Test("重启不重复「已到期」:静默键已记下端点,重启后 start 与刷新都静默")
    func restartDoesNotRepeatExpired() async {
        let validUntil = epoch.addingTimeInterval(86_400)
        let store = InMemoryPlanExpirySilenceKeyStore()
        let clock = TestClock(epoch)
        let first = EngineHarness(
            payloads: [.glm: Self.glmPayload(validUntil: validUntil)],
            clock: clock,
            silenceKeys: store
        )
        clock.advance(2 * 86_400)  // 跨过到期
        let expired = await first.engine.refreshAll()
        #expect(expired.planNotices == [Self.notice(.expired, validUntil: validUntil)])
        let persisted = first.cache.snapshots()[.glm]

        let restarted = EngineHarness(
            cached: [.glm: persisted].compactMapValues { $0 },
            payloads: [.glm: Self.glmPayload(validUntil: validUntil)],
            clock: clock,
            silenceKeys: store
        )
        #expect(await restarted.engine.start().planNotices.isEmpty)
        #expect(await restarted.engine.refreshAll().planNotices.isEmpty)
    }

    // MARK: - 续订:已恢复 + 按新端点重新计时

    @Test("到期 → 续订翻回:发一次「已恢复」;此后按新端点重新计时,不继承旧静默键")
    func renewalAnnouncesRecoveryAndResetsSilenceKeys() async {
        let first = epoch.addingTimeInterval(2 * 86_400)
        let harness = EngineHarness(payloads: [.glm: Self.glmPayload(validUntil: first)])

        var events = await harness.engine.refreshAll()
        #expect(events.planNotices == [Self.notice(.approaching(daysRemaining: 2), validUntil: first)])

        harness.clock.advance(2 * 86_400)
        events = await harness.engine.refreshAll()
        #expect(events.planNotices == [Self.notice(.expired, validUntil: first)])

        // 续订:端点推后 30 天 → 一条「已恢复」;新端点远离到期,不补即将到期
        let renewed = first.addingTimeInterval(30 * 86_400)
        harness.fetchers[.glm]?.respond(with: Self.glmPayload(validUntil: renewed))
        events = await harness.engine.refreshAll()
        #expect(events.planNotices == [Self.notice(.renewed, validUntil: renewed, autoRenew: false)])

        // 新端点进入 3 天窗 → 重新计时后再提醒一次(旧端点的账不挂到新端点)
        harness.clock.advance(27 * 86_400)
        events = await harness.engine.refreshAll()
        #expect(events.planNotices == [Self.notice(.approaching(daysRemaining: 3), validUntil: renewed)])

        // 再往后不再重复
        harness.clock.advance(3_600)
        #expect(await harness.engine.refreshAll().planNotices.isEmpty)
    }

    @Test("没宣告过到期的端点变更(提前续订)不发「已恢复」;新端点照常按窗计时")
    func endpointChangeWithoutAnnouncedExpiryIsNotRecovery() async {
        let first = epoch.addingTimeInterval(2 * 86_400)
        let harness = EngineHarness(payloads: [.glm: Self.glmPayload(validUntil: first)])
        _ = await harness.engine.refreshAll()  // 即将到期(端点一)

        let second = first.addingTimeInterval(30 * 86_400)
        harness.fetchers[.glm]?.respond(with: Self.glmPayload(validUntil: second))
        let events = await harness.engine.refreshAll()
        #expect(events.planNotices.isEmpty, "没到期过就谈不上恢复")
    }

    // MARK: - 无断言 / 门控

    @Test("无有效期信息(从未成功、无来源)不做任何到期提醒;DeepSeek 恒不提醒")
    func unknownPlanStatesDoNotNotify() async {
        // Kimi:无 planValidity 字段(现实形状)
        let kimi = EngineHarness(payloads: [.kimi: Payloads.kimi()])
        #expect(await kimi.engine.refreshAll().planNotices.isEmpty)

        // DeepSeek:即使缓存快照里挂了有效期也不断言(PlanState 恒 unknown)
        let deepseekCache = Self.cachedSnapshot(provider: .deepseek, validUntil: epoch.addingTimeInterval(-86_400))
        let deepseek = EngineHarness(cached: [.deepseek: deepseekCache])
        #expect(await deepseek.engine.start().planNotices.isEmpty)
    }

    @Test("凭据读取异常(状态未知)与未配置凭据的家不做到期断言(凭据问题优先于到期)")
    func credentialsGateExpiryNotices() async {
        let validUntil = epoch.addingTimeInterval(-86_400)
        let cache = [Provider.glm: Self.cachedSnapshot(validUntil: validUntil)]

        // 读取层异常(如钥匙串锁定):状态未知,不误报到期
        let readFailure = EngineHarness(cached: cache)
        readFailure.credentials.failReads(with: NSError(domain: "keychain", code: -25308))
        #expect(await readFailure.engine.start().planNotices.isEmpty)

        // 凭据已被清除:卡上回到凭据占位,也不做到期断言
        let cleared = EngineHarness(cached: cache, credentials: [.kimi: "kimi-token", .deepseek: "sk-ds"])
        #expect(await cleared.engine.start().planNotices.isEmpty)
    }
}
