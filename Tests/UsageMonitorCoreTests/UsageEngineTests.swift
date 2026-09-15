import Foundation
import Testing
@testable import UsageMonitorCore

@Suite("凭据脱敏(纵深防御)")
struct CredentialRedactionTests {
    @Test("长值抹除,短值不动(短值不构成有效凭据,替换只会误伤普通文案)")
    func redactionRules() {
        let key = "sk-abcdef123456"
        #expect(UsageEngine.redactingCredential("Bearer \(key) 超时", credential: key) == "Bearer *** 超时")
        #expect(UsageEngine.redactingCredential("网络错误(timeout)", credential: key) == "网络错误(timeout)")
        #expect(UsageEngine.redactingCredential("HTTP abc 500", credential: "abc") == "HTTP abc 500")       // 3 字符:不换
        #expect(UsageEngine.redactingCredential("HTTP abcd 500", credential: "abcd") == "HTTP *** 500")   // 4 字符:换
        #expect(UsageEngine.redactingCredential(key + key, credential: key) == "******")  // 多次出现都抹
        #expect(UsageEngine.redactingCredential("", credential: key).isEmpty)
    }
}

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

    @Test("凭据失效是跳变沿:停留在失效不重发,恢复(或冷却期过)后再失效才再发")
    func credentialInvalidIsEdgeTriggered() async {
        let harness = EngineHarness(activeProviders: [.glm])
        harness.fetchers[.glm]?.respond(with: Payloads.unauthorized())

        let crossed = await harness.engine.refreshAll()
        #expect(crossed.contains(.credentialInvalid(.glm)))

        // 仍停留在失效(未恢复)→ 不再发
        let stayed = await harness.engine.refreshAll()
        let stayedState = await harness.engine.state
        #expect(!stayed.contains { $0.notificationKind == "credential" })
        #expect(stayedState.provider(.glm).credential == .invalid)
        #expect(stayedState.provider(.glm).consecutiveFailures == 0)  // 始终不计入加载失败轮数
        #expect(stayedState.provider(.glm).loadFailed == false)

        // 恢复可用 → 复位跳变沿;冷却期过再失效 → 再发
        harness.fetchers[.glm]?.respond(with: Payloads.glm())
        #expect(await harness.engine.refreshAll() == [.snapshotUpdated(.glm), .credentialRestored(.glm)])

        harness.clock.advance(25 * 3_600)
        harness.fetchers[.glm]?.respond(with: Payloads.unauthorized())
        let again = await harness.engine.refreshAll()
        #expect(again.contains(.credentialInvalid(.glm)))
    }

    @Test("刷新现读凭据:读到值即视为已配置,不因网络失败退回「未配置」")
    func refreshRecordsCredentialPresence() async {
        // 不跑 start():状态从零开始,只有刷新这一条路径
        let harness = EngineHarness(activeProviders: [.glm])
        harness.fetchers[.glm]?.respond(with: .transport("offline"))
        _ = await harness.engine.refreshAll()

        var state = await harness.engine.state
        #expect(state.provider(.glm).credential == .configured)  // 有值 ≠ 未配置
        #expect(state.provider(.glm).consecutiveFailures == 1)
        #expect(state.pendingCredentialCount == 2)  // 从未现读过的两家才算未配置

        // 已失效的判定不被「读到值」翻回:要成功刷新才复位
        harness.fetchers[.glm]?.respond(with: Payloads.unauthorized())
        _ = await harness.engine.refreshAll()
        state = await harness.engine.state
        #expect(state.provider(.glm).credential == .invalid)

        harness.fetchers[.glm]?.respond(with: .transport("offline"))
        _ = await harness.engine.refreshAll()
        state = await harness.engine.state
        #expect(state.provider(.glm).credential == .invalid)
        #expect(state.provider(.glm).failureDescriptor == "网络错误(offline)")
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
                .kimi: Payloads.kimi(weekRemaining: 50),
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
        #expect(expected.text == "GLM Coding Plan 5 小时窗 剩余 590 积分(5%),已达临界")
        #expect(expected.notificationIdentifier == "usage-critical-glm-5 小时窗")

        let second = await harness.engine.refreshAll()
        #expect(!second.contains { $0.notificationKind == "usage" })
    }

    @Test("窗口临界:窗口名 + 千位分组;双窗 identifier 不互顶;无名回退")
    func criticalWindowCopyAndIdentifiers() async {
        // 7 天窗 3,000/60,000 = 5% 为最紧(5 小时窗 94% 健康):文案带窗口名、数字千位分组
        let harness = EngineHarness(payloads: [.glm: Payloads.glm(fiveHourRemaining: 11_358, weeklyRemaining: 3_000)])
        let events = await harness.engine.refreshAll()
        let weekly = UsageAlert(
            provider: .glm,
            basis: .window(label: "7 天窗", remaining: 3_000, limit: 60_000, unit: "积分", percent: 5)
        )
        #expect(events.contains(.usageCritical(weekly)))
        #expect(weekly.text == "GLM Coding Plan 7 天窗 剩余 3,000 积分(5%),已达临界")

        // C5:5 小时窗与 7 天窗先后临界,identifier 不同 → 通知中心互不顶掉
        let fiveHour = UsageAlert(
            provider: .glm,
            basis: .window(label: "5 小时窗", remaining: 590, limit: 12_000, unit: "积分", percent: 5)
        )
        #expect(weekly.notificationIdentifier == "usage-critical-glm-7 天窗")
        #expect(fiveHour.notificationIdentifier == "usage-critical-glm-5 小时窗")
        #expect(weekly.notificationIdentifier != fiveHour.notificationIdentifier)

        // 窗口名缺失:文案回退现形态(仅千位分组)、identifier 回退 provider 粒度
        let unlabeled = UsageAlert(
            provider: .glm,
            basis: .window(label: "", remaining: 1_200, limit: 12_000, unit: "积分", percent: 10)
        )
        #expect(unlabeled.text == "GLM Coding Plan 剩余 1,200 积分(10%),已达临界")
        #expect(unlabeled.notificationIdentifier == "usage-critical-glm")
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
        #expect(alert.notificationIdentifier == "usage-critical-deepseek")
    }

    @Test("is_available=false → 不可用文案不含「已达临界」")
    func unavailableAlert() async {
        let harness = EngineHarness(payloads: [.deepseek: Payloads.deepseek(total: "999.00", available: false)])
        let events = await harness.engine.refreshAll()
        let alert = UsageAlert(provider: .deepseek, basis: .accountUnavailable)
        #expect(events.contains(.usageCritical(alert)))
        #expect(alert.text == "DeepSeek 账户余额不可用,请到平台查看")
        #expect(alert.text.contains("已达临界") == false)
        #expect(alert.notificationIdentifier == "usage-critical-deepseek")
    }

    @Test("Kimi 周窗口临界:同一带窗口名与窗口级 identifier")
    func kimiWindowAlert() async {
        // 周窗口 5/100 = 5%:另一家带窗口 provider 的同规则验证(文案 + identifier)
        let harness = EngineHarness(payloads: [.kimi: Payloads.kimi(weekRemaining: 5)])
        let events = await harness.engine.refreshAll()
        let alert = UsageAlert(
            provider: .kimi,
            basis: .window(label: "周窗口", remaining: 5, limit: 100, unit: "请求", percent: 5)
        )
        #expect(events.contains(.usageCritical(alert)))
        #expect(alert.text == "Kimi for Coding 周窗口 剩余 5 请求(5%),已达临界")
        #expect(alert.notificationIdentifier == "usage-critical-kimi-周窗口")
    }

    @Test("频限窗吃紧不触发临界(只展不判)")
    func rateLimitDoesNotAlert() async {
        let harness = EngineHarness(payloads: [.kimi: Payloads.kimi(weekRemaining: 66, rollingRemaining: 1)])
        let events = await harness.engine.refreshAll()
        #expect(!events.contains { $0.notificationKind == "usage" })
        let state = await harness.engine.state
        #expect(state.provider(.kimi).status == .normal)
    }

    @Test("24h 静默按 provider 隔离:一家在冷却,不牵连另一家首次跨入")
    func notificationCooldownIsPerProvider() async {
        let harness = EngineHarness(payloads: [
            .glm: Payloads.glm(fiveHourRemaining: 590),   // 5% → 临界
            .deepseek: Payloads.deepseek(total: "100.00"),
        ])
        let first = await harness.engine.refreshAll()
        #expect(first.contains(.usageCritical(UsageAlert(
            provider: .glm,
            basis: .window(label: "5 小时窗", remaining: 590, limit: 12_000, unit: "积分", percent: 5)
        ))))

        // GLM 仍停在临界(静默),DeepSeek 此刻首次跨入临界 → 照发
        harness.fetchers[.deepseek]?.respond(with: Payloads.deepseek(total: "8.00"))
        let second = await harness.engine.refreshAll()
        let notified = second.compactMap { event -> Provider? in
            guard case .usageCritical(let alert) = event else { return nil }
            return alert.provider
        }
        #expect(notified == [.deepseek])

        let state = await harness.engine.state
        #expect(state.provider(.glm).status == .critical)  // 确实是被冷却拦下,不是已恢复
        #expect(state.provider(.deepseek).status == .critical)
    }

    // MARK: - 端口边界:凭据不外泄、时间为注入时钟

    @Test("凭据原文不进事件、引擎状态、失败描述与落盘快照(适配器把原文写进错误文案也不外泄)")
    func credentialNeverEscapesThroughOutputs() async {
        let sentinel = "sk-SENTINEL-2f8c1d4a"
        let harness = EngineHarness(
            credentials: [.glm: sentinel, .kimi: sentinel, .deepseek: sentinel],
            payloads: [.glm: Payloads.glm(fiveHourRemaining: 590), .kimi: Payloads.kimi()]
        )
        // 适配器把原文拼进错误文案(常见于第三方库把请求描述当错误信息)
        harness.fetchers[.kimi]?.respond(with: .transport("Bearer \(sentinel) 请求超时"))

        let events = await harness.engine.refreshAll()
        let state = await harness.engine.state

        // 断言有意义的前提:凭据确实经端口流过
        #expect(harness.fetchers[.glm]?.lastCredential == sentinel)
        #expect(harness.fetchers[.kimi]?.lastCredential == sentinel)
        #expect(state.provider(.glm).credential == .configured)
        // 失败描述保留错误语义,但原文被抹掉
        #expect(state.provider(.kimi).failureDescriptor == "网络错误(Bearer *** 请求超时)")

        // 反射式转储:事件、状态、写盘快照里任何字段都不含原文
        let stateDump = String(reflecting: state)
        let cacheDump = String(reflecting: harness.cache.snapshots())
        let surfaces = events.map { String(reflecting: $0) } + [stateDump, cacheDump]
        for surface in surfaces {
            #expect(!surface.contains(sentinel))
        }

        // 转储确实能看到字段值(否则上面的断言是空转):状态里能看到 provider / 失败描述,
        // 快照里能看到窗口标签。
        #expect(stateDump.contains("glm"))
        #expect(stateDump.contains("Bearer *** 请求超时"))
        #expect(stateDump.contains("configured"))
        #expect(cacheDump.contains("5 小时窗"))
        #expect(events.map { String(reflecting: $0) }.joined().contains("usageCritical"))
    }

    @Test("时间一律取自注入时钟(1970 哨兵):引擎内不读系统时钟")
    func timestampsComeFromInjectedClock() async {
        let frozen = Date(timeIntervalSince1970: 0)
        let harness = EngineHarness(payloads: [.glm: Payloads.glm()], clock: TestClock(frozen))
        let events = await harness.engine.refreshAll()

        let state = await harness.engine.state
        #expect(state.lastRefreshStartedAt == frozen)
        #expect(state.lastRefreshFinishedAt == frozen)
        #expect(state.provider(.glm).lastAttemptAt == frozen)
        #expect(state.provider(.glm).lastSuccessAt == frozen)
        #expect(state.provider(.glm).snapshot?.meta.fetchedAt == frozen)  // 快照时间戳同样来自时钟
        #expect(events == [.snapshotUpdated(.glm)])
        #expect(await harness.engine.nextRefreshAt == frozen.addingTimeInterval(30 * 60))
    }

    @Test("阈值与静默窗口参数化:换一份 Thresholds 即改判定与冷却")
    func thresholdsAreInjectableThroughTheEngine() async {
        var thresholds = Thresholds()
        thresholds.criticalRemainingFraction = 0.5
        thresholds.lowRemainingFraction = 0.9
        thresholds.notificationCooldown = 60
        let harness = EngineHarness(
            thresholds: thresholds,
            payloads: [.glm: Payloads.glm(fiveHourRemaining: 5_900, weeklyRemaining: 31_000)]  // 49.2% / 51.7%
        )

        let first = await harness.engine.refreshAll()
        #expect(first.contains { $0.notificationKind == "usage" })  // 默认阈值下 49% 不告警
        let critical = await harness.engine.state
        #expect(critical.provider(.glm).status == .critical)
        #expect(critical.overview.worstStatus == .critical)
        #expect(critical.overview.iconPercent == 49)

        // 恢复(两种窗均 ≥90%)→ 1 分钟后再次跨入:自定义冷却(60s)已过 → 再发(默认 24h 下会静默)
        harness.fetchers[.glm]?.respond(with: Payloads.glm(fiveHourRemaining: 11_100, weeklyRemaining: 55_000))
        let recovered = await harness.engine.refreshAll()
        #expect(recovered.contains(.usageRecovered(.glm)))

        harness.clock.advance(61)
        harness.fetchers[.glm]?.respond(with: Payloads.glm(fiveHourRemaining: 5_900, weeklyRemaining: 31_000))
        let again = await harness.engine.refreshAll()
        #expect(again.contains { $0.notificationKind == "usage" })
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
            .kimi: Payloads.kimi(weekRemaining: 36),
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

/// 套餐有效期的跨分片失败保留(#54):有效期一旦取得,后续轮询里订阅分片失败不清掉它,
/// 观测时刻不动(陈旧标注靠它);分片成活(200 + 无业务错误)时以新结果为准。
/// 挂点在引擎成功路径的单一安装处:内存快照与落盘是同一份合并结果,不分叉。
@Suite("引擎:套餐有效期跨分片失败保留")
struct PlanValidityRetentionTests {
    /// 额度主分片 + 订阅分片(实测形状:有效期至 2026-10-15 10:00 +08:00)。
    private static func glmWithSubscription() -> ProviderPayload {
        Payloads.glm().merging(.ok(ParserFixtures.glmSubscription, part: .subscription))
    }

    @Test("首次成功取得:planValidity 落内存与缓存,observedAt = 取得时刻")
    func firstSuccessInstallsValidity() async {
        let harness = EngineHarness(payloads: [.glm: Self.glmWithSubscription()])
        _ = await harness.engine.refreshAll()

        let state = await harness.engine.state
        let validity = state.provider(.glm).snapshot?.planValidity
        #expect(validity?.validUntil == Date(timeIntervalSince1970: 1_792_029_600))
        #expect(validity?.observedAt == Fixture.epoch)
        #expect(harness.cache.snapshots()[.glm]?.planValidity == validity)
    }

    @Test("订阅分片失败:最近一次成功值保留,observedAt 不动(陈旧随失败时长增长)")
    func shardFailureRetainsLastValidity() async {
        let harness = EngineHarness(payloads: [.glm: Self.glmWithSubscription()])
        _ = await harness.engine.refreshAll()

        // 下一轮:额度照常,订阅分片传输失败
        harness.clock.advance(30 * 60)
        harness.fetchers[.glm]?.respond(with: Payloads.glm().merging(
            .failure(.transport("timeout"), part: .subscription)
        ))
        _ = await harness.engine.refreshAll()

        let state = await harness.engine.state
        let snapshot = state.provider(.glm).snapshot
        #expect(snapshot?.meta.fetchedAt == Fixture.epoch.addingTimeInterval(30 * 60), "额度数据照常刷新")
        #expect(snapshot?.planValidity?.validUntil == Date(timeIntervalSince1970: 1_792_029_600), "有效期不清掉")
        #expect(snapshot?.planValidity?.observedAt == Fixture.epoch, "观测时刻不随失败推进")
        // 内存与落盘同一份(单一安装处,不分叉)
        #expect(harness.cache.snapshots()[.glm]?.planValidity == snapshot?.planValidity)

        // 连续再失败一轮:仍保留
        harness.clock.advance(30 * 60)
        harness.fetchers[.glm]?.respond(with: Payloads.glm().merging(
            .response("{}", part: .subscription, statusCode: 500)
        ))
        _ = await harness.engine.refreshAll()
        let retained = await harness.engine.state.provider(.glm).snapshot?.planValidity
        #expect(retained?.validUntil == Date(timeIntervalSince1970: 1_792_029_600))
        #expect(retained?.observedAt == Fixture.epoch)
    }

    @Test("分片成活但无订阅记录:以新结果为准(退回无有效期信息,不保留旧值)")
    func successfulEmptyListReplaces() async {
        let harness = EngineHarness(payloads: [.glm: Self.glmWithSubscription()])
        _ = await harness.engine.refreshAll()

        harness.fetchers[.glm]?.respond(with: Payloads.glm().merging(
            .ok(#"{"code":200,"data":[],"success":true}"#, part: .subscription)
        ))
        _ = await harness.engine.refreshAll()

        let state = await harness.engine.state
        #expect(state.provider(.glm).snapshot?.planValidity == nil)
        #expect(harness.cache.snapshots()[.glm]?.planValidity == nil)
    }

    @Test("分片成活且续订:新区间替换旧值,observedAt 推进")
    func renewedRecordReplaces() async {
        let harness = EngineHarness(payloads: [.glm: Self.glmWithSubscription()])
        _ = await harness.engine.refreshAll()

        harness.clock.advance(30 * 60)
        let renewed = #"{"code":200,"data":[{"productName":"GLM Coding Pro","status":"VALID","valid":"2026-10-15 10:00:00-2026-11-15 10:00:00","autoRenew":1}],"success":true}"#
        harness.fetchers[.glm]?.respond(with: Payloads.glm().merging(.ok(renewed, part: .subscription)))
        _ = await harness.engine.refreshAll()

        let validity = await harness.engine.state.provider(.glm).snapshot?.planValidity
        #expect(validity?.validUntil == Date(timeIntervalSince1970: 1_794_708_000))
        #expect(validity?.observedAt == Fixture.epoch.addingTimeInterval(30 * 60))
    }

    @Test("他家的 profile 分片失败不触发保留逻辑(保留只认订阅分片)")
    func kimiProfileFailureIsIrrelevant() async {
        let harness = EngineHarness(payloads: [
            .kimi: Payloads.kimi().merging(.failure(.transport("timeout"), part: .profile))
        ])
        _ = await harness.engine.refreshAll()
        let state = await harness.engine.state
        #expect(state.provider(.kimi).snapshot != nil)
        #expect(state.provider(.kimi).snapshot?.planValidity == nil)
    }
}
