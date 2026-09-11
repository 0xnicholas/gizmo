import Foundation
import Testing
@testable import UsageMonitorCore

@Suite("引擎:刷新编排与状态机")
struct UsageEngineTests {

    // MARK: - 成功路径与缓存

    @Test("成功刷新:发布快照、写缓存、status 按快照推导")
    func successRefresh() async {
        let harness = EngineHarness(payloads: [.glm: Payloads.glm()])
        let events = await harness.engine.refreshAll()

        let state = await harness.engine.state
        #expect(events.contains(.snapshotUpdated(.glm)))
        #expect(state.provider(.glm).snapshot != nil)
        #expect(state.provider(.glm).status == .low)  // 7 天窗 26.5%
        #expect(state.provider(.glm).credential == .configured)
        #expect(state.provider(.glm).lastSuccessAt == Fixture.epoch)
        #expect(harness.cache.saveCount == 1)
        #expect(harness.cache.snapshots()[.glm]?.meta.provider == .glm)
        // 未配置响应的家不被当作失败
        #expect(state.provider(.kimi).snapshot == nil)
        #expect(state.provider(.kimi).consecutiveFailures == 0)
        #expect(state.provider(.kimi).failureDescriptor == nil)
    }

    @Test("启动:先读缓存发布最近快照,随后刷新发新鲜快照")
    func startPublishesCacheThenFreshSnapshot() async {
        let cached = Fixture.snapshot(
            provider: .glm,
            windows: [Fixture.planWindow(limit: 12_000, remaining: 9_600, label: "5 小时窗")],
            fetchedAt: Fixture.epoch.addingTimeInterval(-3_600)
        )
        let harness = EngineHarness(
            cached: [.glm: cached],
            payloads: [.glm: Payloads.glm(fiveHourRemaining: 11_358, weeklyRemaining: 15_929)]
        )

        let startEvents = await harness.engine.start()
        let cachedState = await harness.engine.state
        #expect(startEvents == [.snapshotUpdated(.glm)])
        #expect(cachedState.provider(.glm).snapshot == cached)
        #expect(cachedState.overview.iconPercent == 80)

        let refreshEvents = await harness.engine.refreshAll()
        let freshState = await harness.engine.state
        #expect(refreshEvents.contains(.snapshotUpdated(.glm)))
        #expect(freshState.provider(.glm).snapshot != cached)
        #expect(freshState.provider(.glm).snapshot?.planWindows.first?.remaining == 11_358)
    }

    @Test("启动不触发通知(避免重启重复告警)")
    func startDoesNotNotify() async {
        let cached = Fixture.snapshot(
            provider: .glm,
            windows: [Fixture.planWindow(limit: 12_000, remaining: 120, label: "5 小时窗")]
        )
        let harness = EngineHarness(cached: [.glm: cached])
        let events = await harness.engine.start()
        #expect(!events.contains { $0.notificationKind != nil })
    }

    // MARK: - 凭据:缺失 / 失效 / 恢复 / 清除

    @Test("未配置凭据:不发请求、不计数、状态未配置")
    func missingCredential() async {
        let harness = EngineHarness(credentials: [:], payloads: [.glm: Payloads.glm()])
        let events = await harness.engine.refreshAll()

        let state = await harness.engine.state
        #expect(events.isEmpty)
        #expect(harness.fetchers[.glm]?.callCount == 0)
        #expect(state.provider(.glm).credential == .missing)
        #expect(state.provider(.glm).consecutiveFailures == 0)
        #expect(state.provider(.glm).loadFailed == false)
        #expect(state.pendingCredentialCount == 3)
    }

    @Test("401 重试一次:第二次成功则照常成快照")
    func retriesUnauthorizedOnce() async {
        let harness = EngineHarness(activeProviders: [.glm])
        harness.fetchers[.glm]?.setOutcomes([
            .success(Payloads.unauthorized()),
            .success(Payloads.glm()),
        ])

        let events = await harness.engine.refreshAll()
        let state = await harness.engine.state
        #expect(harness.fetchers[.glm]?.callCount == 2)
        #expect(events.contains(.snapshotUpdated(.glm)))
        #expect(state.provider(.glm).credential == .configured)
    }

    @Test("重试后仍 401 → 凭据失效,且不计入网络失败轮数")
    func persistentUnauthorizedMarksInvalid() async {
        let harness = EngineHarness(activeProviders: [.glm])
        harness.fetchers[.glm]?.setOutcomes([.success(Payloads.unauthorized())])

        let events = await harness.engine.refreshAll()
        let state = await harness.engine.state
        #expect(harness.fetchers[.glm]?.callCount == 2)  // 单请求重试一次
        #expect(events.contains(.credentialInvalid(.glm)))
        #expect(state.provider(.glm).credential == .invalid)
        #expect(state.provider(.glm).consecutiveFailures == 0)
        #expect(state.provider(.glm).loadFailed == false)
    }

    @Test("凭据失效后重配成功 → credentialRestored")
    func credentialRestoredAfterRepair() async {
        let harness = EngineHarness(activeProviders: [.glm])
        harness.fetchers[.glm]?.setOutcomes([.success(Payloads.unauthorized()), .success(Payloads.unauthorized())])
        _ = await harness.engine.refreshAll()

        harness.fetchers[.glm]?.setOutcomes([.success(Payloads.glm())])
        let events = await harness.engine.refreshAll()
        let state = await harness.engine.state
        #expect(events.contains(.credentialRestored(.glm)))
        #expect(state.provider(.glm).credential == .configured)
    }

    @Test("清除凭据:当刻进入未配置并通知;24h 内再次失效不重复通知")
    func clearingCredentialNotifiesOnce() async {
        let harness = EngineHarness(payloads: [.glm: Payloads.glm()])
        _ = await harness.engine.refreshAll()

        harness.credentials.set(nil, for: .glm)
        let events = await harness.engine.credentialCleared(.glm)
        let state = await harness.engine.state
        #expect(events == [.credentialInvalid(.glm)])
        #expect(state.provider(.glm).credential == .missing)

        // 24h 内重新配置又失效 → 静默
        harness.credentials.set("glm-key", for: .glm)
        harness.fetchers[.glm]?.respond(with: Payloads.glm())
        _ = await harness.engine.refreshAll()
        harness.fetchers[.glm]?.respond(with: Payloads.unauthorized())
        let silenced = await harness.engine.refreshAll()
        #expect(!silenced.contains { $0.notificationKind == "credential" })

        // 超过静默窗口后再次失效 → 再发
        harness.clock.advance(25 * 3_600)
        harness.fetchers[.glm]?.respond(with: Payloads.glm())
        _ = await harness.engine.refreshAll()
        harness.fetchers[.glm]?.respond(with: Payloads.unauthorized())
        let later = await harness.engine.refreshAll()
        #expect(later.contains { $0.notificationKind == "credential" })
    }

    @Test("启动时凭据读取异常:记为「状态未知」,不计入未配置")
    func startWithCredentialReadFailure() async {
        let harness = EngineHarness(activeProviders: [.glm])
        harness.credentials.failReads(with: NSError(domain: "keychain", code: -25308))

        let events = await harness.engine.start()
        let state = await harness.engine.state
        #expect(events.isEmpty)
        #expect(state.credentialReadFailures == [.glm, .kimi, .deepseek])
        #expect(state.pendingCredentialCount == 0)  // 不误报「尚未配置凭据」
        #expect(state.provider(.glm).failureDescriptor == "凭据读取失败")

        // 读取恢复(钥匙串解锁)后标记清除,凭据状态重新可判定
        harness.credentials.set("glm-key", for: .glm)
        harness.credentials.allowReads()
        harness.fetchers[.glm]?.respond(with: Payloads.glm())
        _ = await harness.engine.refreshAll()
        let recovered = await harness.engine.state
        #expect(!recovered.credentialReadFailures.contains(.glm))  // 未刷新的家仍标记未知
        #expect(recovered.provider(.glm).credential == .configured)
        #expect(recovered.provider(.glm).failureDescriptor == nil)
    }

    @Test("凭据读取层异常:不改状态、不误报失效、不发请求")
    func credentialReadFailureIsNotInvalid() async {
        let harness = EngineHarness(payloads: [.glm: Payloads.glm()])
        _ = await harness.engine.refreshAll()

        harness.credentials.failReads(with: NSError(domain: "keychain", code: -25308))
        let events = await harness.engine.refreshAll()
        let state = await harness.engine.state
        #expect(events.isEmpty)
        #expect(state.provider(.glm).credential == .configured)
        #expect(harness.fetchers[.glm]?.callCount == 1)
    }

    // MARK: - 加载失败轮数

    @Test("连续失败 3 轮 → 加载失败;第 4 轮恢复即清除")
    func loadFailureAfterThreeRounds() async {
        let harness = EngineHarness(activeProviders: [.glm])
        harness.fetchers[.glm]?.respond(with: .transport("timeout"))

        _ = await harness.engine.refreshAll()
        _ = await harness.engine.refreshAll()
        let beforeThreshold = await harness.engine.state
        #expect(beforeThreshold.provider(.glm).consecutiveFailures == 2)
        #expect(beforeThreshold.provider(.glm).loadFailed == false)

        let thirdEvents = await harness.engine.refreshAll()
        let afterThreshold = await harness.engine.state
        #expect(afterThreshold.provider(.glm).consecutiveFailures == 3)
        #expect(afterThreshold.provider(.glm).loadFailed)
        #expect(thirdEvents.contains(.loadFailed(.glm, lastSuccessAt: nil)))

        // 加载失败态不重复发事件
        let fourthFailure = await harness.engine.refreshAll()
        #expect(!fourthFailure.contains { if case .loadFailed = $0 { return true } else { return false } })

        harness.fetchers[.glm]?.respond(with: Payloads.glm())
        let recovered = await harness.engine.refreshAll()
        let recoveredState = await harness.engine.state
        #expect(recovered.contains(.loadRecovered(.glm)))
        #expect(recoveredState.provider(.glm).loadFailed == false)
        #expect(recoveredState.provider(.glm).consecutiveFailures == 0)
    }

    @Test("失败不清缓存:仍保留并发布最近一次成功快照")
    func failuresKeepLastSnapshot() async {
        let cached = Fixture.snapshot(
            provider: .glm,
            windows: [Fixture.planWindow(limit: 12_000, remaining: 6_000, label: "5 小时窗")]
        )
        let harness = EngineHarness(cached: [.glm: cached], activeProviders: [.glm])
        _ = await harness.engine.start()
        harness.fetchers[.glm]?.respond(with: .transport("offline"))

        for _ in 0..<4 {
            _ = await harness.engine.refreshAll()
        }

        let state = await harness.engine.state
        #expect(state.provider(.glm).snapshot == cached)
        #expect(state.provider(.glm).loadFailed)
        #expect(state.provider(.glm).lastSuccessAt == cached.meta.fetchedAt)
        #expect(state.overview.iconPercent == 50)  // status 仍按持有快照推导
        #expect(harness.cache.snapshots()[.glm] == cached)
    }

    @Test("HTTP 500 与解析失败都计入失败轮数,描述已脱敏")
    func nonAuthFailuresCount() async {
        let harness = EngineHarness(activeProviders: [.glm])
        harness.fetchers[.glm]?.respond(with: .http(500))
        _ = await harness.engine.refreshAll()
        let httpState = await harness.engine.state
        #expect(httpState.provider(.glm).failureDescriptor == "HTTP 500")

        harness.fetchers[.glm]?.setOutcomes([.success(.ok(#"{"unexpected":true}"#))])
        _ = await harness.engine.refreshAll()
        let parseState = await harness.engine.state
        #expect(parseState.provider(.glm).consecutiveFailures == 2)
        #expect(parseState.provider(.glm).failureDescriptor?.hasPrefix("响应解析失败") == true)
    }

    @Test("单家失败不影响他者(并行刷新)")
    func oneFailureDoesNotAffectOthers() async {
        let harness = EngineHarness(
            payloads: [
                .kimi: Payloads.kimi(dayRemaining: 50),
                .deepseek: Payloads.deepseek(total: "100.00"),
            ],
            activeProviders: [.glm, .kimi, .deepseek]
        )
        harness.fetchers[.glm]?.respond(with: .transport("boom"))

        let events = await harness.engine.refreshAll()
        let state = await harness.engine.state
        #expect(events.contains(.snapshotUpdated(.kimi)))
        #expect(events.contains(.snapshotUpdated(.deepseek)))
        #expect(!events.contains(.snapshotUpdated(.glm)))
        #expect(state.provider(.kimi).snapshot != nil)
        #expect(state.provider(.deepseek).snapshot != nil)
        #expect(state.provider(.glm).snapshot == nil)
    }

    // MARK: - 临界通知边沿

    @Test("跨入临界:通知文案含剩余/单位/百分比;停留不重复")
    func criticalEdgeAndText() async {
        let harness = EngineHarness(payloads: [.glm: Payloads.glm(fiveHourRemaining: 590)])
        let first = await harness.engine.refreshAll()
        let expected = UsageAlert(
            provider: .glm,
            basis: .window(label: "5 小时窗", remaining: 590, limit: 12_000, unit: "积分", percent: 5)
        )
        #expect(first == [.snapshotUpdated(.glm), .usageCritical(expected)])
        #expect(expected.text == "GLM Coding Plan 剩余 590 积分(5%),已达临界")

        let second = await harness.engine.refreshAll()
        #expect(!second.contains { $0.notificationKind == "usage" })
    }

    @Test("恢复后再跨入才再发;24h 冷却期内静默")
    func criticalRecoveryAndCooldown() async {
        let harness = EngineHarness(payloads: [.glm: Payloads.glm(fiveHourRemaining: 590)])

        let critical = await harness.engine.refreshAll()
        #expect(critical.contains { $0.notificationKind == "usage" })

        harness.fetchers[.glm]?.respond(with: Payloads.glm(fiveHourRemaining: 9_000))  // 75%
        let recovered = await harness.engine.refreshAll()
        #expect(recovered.contains(.usageRecovered(.glm)))

        // 24h 内再跨入 → 静默
        harness.fetchers[.glm]?.respond(with: Payloads.glm(fiveHourRemaining: 100))
        let silenced = await harness.engine.refreshAll()
        #expect(!silenced.contains { $0.notificationKind == "usage" })
        #expect(silenced.contains(.usageRecovered(.glm)) == false)

        // 超过冷却窗口:恢复后再次跨入 → 再发
        harness.fetchers[.glm]?.respond(with: Payloads.glm(fiveHourRemaining: 9_000))
        _ = await harness.engine.refreshAll()
        harness.clock.advance(25 * 3_600)
        harness.fetchers[.glm]?.respond(with: Payloads.glm(fiveHourRemaining: 100))
        let again = await harness.engine.refreshAll()
        #expect(again.contains { $0.notificationKind == "usage" })
    }

    @Test("DeepSeek 余额跨入临界 → 余额文案")
    func deepseekBalanceAlert() async {
        let harness = EngineHarness(payloads: [.deepseek: Payloads.deepseek(total: "8.20")])
        let events = await harness.engine.refreshAll()
        let alert = UsageAlert(
            provider: .deepseek,
            basis: .balance(amount: Decimal(string: "8.20", locale: Locale(identifier: "en_US_POSIX"))!, currency: "CNY")
        )
        #expect(events.contains(.usageCritical(alert)))
        #expect(alert.text == "DeepSeek 余额 ¥8.20,已达临界")
    }

    @Test("is_available=false → 不可用文案")
    func unavailableAlert() async {
        let harness = EngineHarness(payloads: [.deepseek: Payloads.deepseek(total: "999.00", available: false)])
        let events = await harness.engine.refreshAll()
        let alert = UsageAlert(provider: .deepseek, basis: .accountUnavailable)
        #expect(events.contains(.usageCritical(alert)))
        #expect(alert.text == "DeepSeek 余额不可用,已达临界")
    }

    @Test("频限窗吃紧不触发临界(只展不判)")
    func rateLimitDoesNotAlert() async {
        let harness = EngineHarness(payloads: [.kimi: Payloads.kimi(dayRemaining: 66, rollingRemaining: 1)])
        let events = await harness.engine.refreshAll()
        #expect(!events.contains { $0.notificationKind == "usage" })
        let state = await harness.engine.state
        #expect(state.provider(.kimi).status == .normal)
    }

    // MARK: - 调度

    @Test("30 分钟轮询:截止时刻、手动刷新即时并顺延")
    func refreshSchedule() async {
        let harness = EngineHarness(payloads: [.glm: Payloads.glm()])

        let initial = await harness.engine.nextRefreshAt
        #expect(initial == nil)
        let initialShould = await harness.engine.shouldRefresh(at: Fixture.epoch)
        #expect(initialShould)

        _ = await harness.engine.refreshAll()
        let deadline = await harness.engine.nextRefreshAt
        #expect(deadline == Fixture.epoch.addingTimeInterval(30 * 60))

        let beforeDeadline = await harness.engine.shouldRefresh(at: Fixture.epoch.addingTimeInterval(29 * 60))
        #expect(beforeDeadline == false)
        let atDeadline = await harness.engine.shouldRefresh(at: Fixture.epoch.addingTimeInterval(30 * 60))
        #expect(atDeadline)

        harness.clock.advance(5 * 60)
        _ = await harness.engine.refreshAll()  // 手动刷新即拉即得
        let manualDeadline = await harness.engine.nextRefreshAt
        #expect(manualDeadline == Fixture.epoch.addingTimeInterval(35 * 60))
    }

    @Test("全局汇总:图标数字与颜色取全部快照")
    func overviewFromEngineState() async {
        let harness = EngineHarness(payloads: [
            .glm: Payloads.glm(fiveHourRemaining: 11_358, weeklyRemaining: 28_200),  // 47%
            .kimi: Payloads.kimi(dayRemaining: 36),
            .deepseek: Payloads.deepseek(total: "8.00"),
        ])
        _ = await harness.engine.refreshAll()
        let state = await harness.engine.state
        #expect(state.overview.iconPercent == 36)
        #expect(state.overview.tightest?.provider == .kimi)
        #expect(state.overview.worstStatus == .critical)  // DeepSeek ¥8
        #expect(state.hasAnyCredential)
        #expect(state.pendingCredentialCount == 0)
    }

    @Test("刷新期间的状态标记")
    func refreshFlags() async {
        let harness = EngineHarness(payloads: [.glm: Payloads.glm()])
        let before = await harness.engine.state
        #expect(before.isRefreshing == false)
        _ = await harness.engine.refreshAll()
        let after = await harness.engine.state
        #expect(after.isRefreshing == false)
        #expect(after.lastRefreshStartedAt == Fixture.epoch)
        #expect(after.lastRefreshFinishedAt == Fixture.epoch)
        #expect(after.lastUpdatedAt == Fixture.epoch)
    }
}
