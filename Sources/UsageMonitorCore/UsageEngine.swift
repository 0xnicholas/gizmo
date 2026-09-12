import Foundation

/// 刷新编排与边沿状态机:唯一被测试的模块(接缝 = 注入的四个端口 + 可拨时钟)。
///
/// 职责:
/// - 三家并行刷新(打开即刷 / 30 分钟后台 / 手动即时都走同一入口);
/// - 401 单请求重试一次 → 仍失败则凭据「失效」(与 networkError 分家);
/// - networkError 连续失败 ≥3 轮 →「加载失败」,恢复即清除,失败不清缓存;
/// - 跨入临界的通知边沿 + 24h 静默;
/// - 启动先发缓存快照,再后台刷新。
public actor UsageEngine {
    private let credentials: CredentialStore
    private let fetchers: [Provider: any ProviderFetching]
    private let parsers: [Provider: any ProviderParser]
    private let cache: SnapshotCache
    private let clock: Clock
    public let thresholds: Thresholds
    private let evaluator: StatusEvaluator

    private var providers: [Provider: ProviderRuntimeState]
    private var alerts: [Provider: AlertState]
    private var lastRefreshStartedAt: Date?
    private var lastRefreshFinishedAt: Date?
    private var isRefreshing = false
    private var inFlight: Set<Provider> = []
    private var credentialReadFailures: Set<Provider> = []

    /// 通知边沿状态:进入预警记一次,恢复才复位;`lastNotifiedAt` 做 24h 静默。
    private struct AlertState: Equatable {
        var usageCritical = false
        var lastUsageNotifiedAt: Date?
        var credentialInvalid = false
        var lastCredentialNotifiedAt: Date?
    }

    public init(
        credentials: CredentialStore,
        fetchers: [Provider: any ProviderFetching],
        parsers: [Provider: any ProviderParser],
        cache: SnapshotCache,
        clock: Clock,
        thresholds: Thresholds = Thresholds()
    ) {
        self.credentials = credentials
        self.fetchers = fetchers
        self.parsers = parsers
        self.cache = cache
        self.clock = clock
        self.thresholds = thresholds
        self.evaluator = StatusEvaluator(thresholds: thresholds)
        self.providers = Dictionary(uniqueKeysWithValues: Provider.allCases.map { ($0, ProviderRuntimeState(provider: $0)) })
        self.alerts = Dictionary(uniqueKeysWithValues: Provider.allCases.map { ($0, AlertState()) })
    }

    // MARK: - 只读状态

    public var state: EngineState {
        EngineState(
            providers: providers,
            lastRefreshStartedAt: lastRefreshStartedAt,
            lastRefreshFinishedAt: lastRefreshFinishedAt,
            isRefreshing: isRefreshing,
            credentialReadFailures: credentialReadFailures,
            overview: GlobalOverview.compute(
                snapshots: providers.compactMapValues(\.snapshot),
                evaluator: evaluator
            )
        )
    }

    /// 下一次后台轮询时刻;nil = 尚未轮询过,应立即刷。
    public var nextRefreshAt: Date? {
        lastRefreshStartedAt.map { $0.addingTimeInterval(thresholds.refreshInterval) }
    }

    public func shouldRefresh(at date: Date) -> Bool {
        guard let deadline = nextRefreshAt else { return true }
        return date >= deadline
    }

    // MARK: - 启动

    /// 读盘:启动即发布最近快照(不触发通知),随后由 App 触发后台刷新。
    @discardableResult
    public func start() -> [EngineEvent] {
        var events: [EngineEvent] = []
        let cached = (try? cache.loadSnapshots()) ?? [:]
        credentialReadFailures = []

        for provider in Provider.allCases {
            var state = providers[provider] ?? ProviderRuntimeState(provider: provider)
            // 凭据状态现读一次(值永不进入此层)。读取层异常记入 credentialReadFailures:
            // 「读不到」不等于「未配置」,UI 据此不误报未配置。
            do {
                let credential = try credentials.credential(for: provider)
                state.credential = (credential?.isEmpty == false) ? .configured : .missing
            } catch {
                credentialReadFailures.insert(provider)
                state.failureDescriptor = "凭据读取失败"
            }

            if let snapshot = cached[provider] {
                state.snapshot = snapshot
                state.status = evaluator.status(for: snapshot)
                state.lastSuccessAt = snapshot.meta.fetchedAt
                events.append(.snapshotUpdated(provider))
            }
            providers[provider] = state
        }
        return events
    }

    // MARK: - 刷新

    @discardableResult
    public func refreshAll() async -> [EngineEvent] {
        await refresh(targets: Provider.allCases)
    }

    @discardableResult
    public func refresh(_ provider: Provider) async -> [EngineEvent] {
        await refresh(targets: [provider])
    }

    private func refresh(targets: [Provider]) async -> [EngineEvent] {
        lastRefreshStartedAt = clock.now
        isRefreshing = true

        let active = targets.filter { fetchers[$0] != nil && parsers[$0] != nil && !inFlight.contains($0) }
        inFlight.formUnion(active)

        var events: [EngineEvent] = []
        if !active.isEmpty {
            // 三家并行:单家失败不影响他者。
            await withTaskGroup(of: [EngineEvent].self) { group in
                for provider in active {
                    group.addTask { await self.performRefresh(provider) }
                }
                for await result in group {
                    events.append(contentsOf: result)
                }
            }
        }

        inFlight.subtract(active)
        lastRefreshFinishedAt = clock.now
        isRefreshing = false
        return events
    }

    /// 用户清除凭据后即时调用:当刻进入「未配置」态,并按边沿发凭据失效通知。
    @discardableResult
    public func credentialCleared(_ provider: Provider) -> [EngineEvent] {
        guard var state = providers[provider] else { return [] }
        let wasConfigured = state.credential == .configured
        state.credential = .missing
        providers[provider] = state
        return wasConfigured ? credentialInvalidEvents(provider) : []
    }

    // MARK: - 单家刷新

    private func performRefresh(_ provider: Provider) async -> [EngineEvent] {
        guard let fetcher = fetchers[provider], let parser = parsers[provider] else { return [] }
        let now = clock.now

        let credential: String?
        do {
            credential = try credentials.credential(for: provider)
            credentialReadFailures.remove(provider)
        } catch {
            // 读取层异常(如钥匙串锁定):不改凭据状态、不计数、不误报失效。
            var state = providers[provider] ?? ProviderRuntimeState(provider: provider)
            state.lastAttemptAt = now
            state.failureDescriptor = "凭据读取失败"
            providers[provider] = state
            return []
        }

        guard let credential, !credential.isEmpty else {
            var state = providers[provider] ?? ProviderRuntimeState(provider: provider)
            let wasConfigured = state.credential == .configured
            state.credential = .missing
            state.lastAttemptAt = now
            providers[provider] = state
            return wasConfigured ? credentialInvalidEvents(provider) : []
        }

        // 现读到值 = 已配置(与启动态一致):否则网络一挂,配置了凭据的家会显示成「未配置」。
        // 已失效的判定保留到成功刷新才复位,不被「读到值」翻回(另一处判定在 successEvents)。
        var state = providers[provider] ?? ProviderRuntimeState(provider: provider)
        if state.credential == .missing {
            state.credential = .configured
            providers[provider] = state
        }

        var payload: ProviderPayload
        do {
            payload = try await fetcher.fetch(credential: credential)
        } catch let failure as FetchFailure {
            return failureEvents(provider, failure: failure, credential: credential)
        } catch {
            return failureEvents(provider, failure: .transport(Self.transportDescription(error)), credential: credential)
        }

        // 401/403:单请求重试一次。
        if let primary = payload.response(.primary), Self.isAuthStatus(primary.statusCode) {
            do {
                payload = try await fetcher.fetch(credential: credential)
            } catch let failure as FetchFailure {
                return failureEvents(provider, failure: failure, credential: credential)
            } catch {
                return failureEvents(provider, failure: .transport(Self.transportDescription(error)), credential: credential)
            }
        }

        guard let primary = payload.response(.primary) else {
            return failureEvents(provider, failure: .transport("响应缺失:primary"), credential: credential)
        }
        if Self.isAuthStatus(primary.statusCode) {
            return failureEvents(provider, failure: .auth(primary.statusCode), credential: credential)
        }
        guard primary.statusCode == 200 else {
            return failureEvents(provider, failure: .http(primary.statusCode), credential: credential)
        }

        let snapshot: Snapshot
        do {
            snapshot = try parser.parse(payload: payload, fetchedAt: now)
        } catch let failure as FetchFailure {
            return failureEvents(provider, failure: failure, credential: credential)
        } catch {
            return failureEvents(provider, failure: .parse(String(describing: error)), credential: credential)
        }

        return successEvents(provider, snapshot: snapshot)
    }

    private func successEvents(_ provider: Provider, snapshot: Snapshot) -> [EngineEvent] {
        var events: [EngineEvent] = [.snapshotUpdated(provider)]
        var state = providers[provider] ?? ProviderRuntimeState(provider: provider)

        state.snapshot = snapshot
        state.status = evaluator.status(for: snapshot)
        state.lastSuccessAt = snapshot.meta.fetchedAt
        state.lastAttemptAt = clock.now
        state.consecutiveFailures = 0
        state.failureDescriptor = nil
        if state.credential != .configured {
            let wasInvalid = state.credential == .invalid
            state.credential = .configured
            // 凭据恢复可用:复位失效边沿(下次再失效才重新通知)。
            var alert = alerts[provider] ?? AlertState()
            alert.credentialInvalid = false
            alerts[provider] = alert
            if wasInvalid { events.append(.credentialRestored(provider)) }
        }
        if state.loadFailed {
            state.loadFailed = false
            events.append(.loadRecovered(provider))
        }
        providers[provider] = state

        // 失败不清缓存:只有成功才覆盖最近一次成功快照。
        try? cache.saveSnapshot(snapshot)

        events.append(contentsOf: usageAlertEvents(provider, snapshot: snapshot, status: state.status))
        return events
    }

    private func failureEvents(_ provider: Provider, failure: FetchFailure, credential: String) -> [EngineEvent] {
        var state = providers[provider] ?? ProviderRuntimeState(provider: provider)
        state.lastAttemptAt = clock.now
        var events: [EngineEvent] = []
        let descriptor = Self.redactingCredential(failure.descriptor, credential: credential)

        if failure.isAuthFailure {
            // authError 与 networkError 分家:不计入加载失败轮数。
            if state.credential != .invalid {
                state.credential = .invalid
                events.append(contentsOf: credentialInvalidEvents(provider))
            }
            state.failureDescriptor = descriptor
        } else {
            state.failureDescriptor = descriptor
            state.consecutiveFailures += 1
            if state.consecutiveFailures >= thresholds.failureRoundsBeforeLoadFailure, !state.loadFailed {
                state.loadFailed = true
                events.append(.loadFailed(provider, lastSuccessAt: state.lastSuccessAt))
            }
        }

        providers[provider] = state
        return events
    }

    // MARK: - 通知边沿与静默

    private func usageAlertEvents(_ provider: Provider, snapshot: Snapshot, status: ProviderStatus) -> [EngineEvent] {
        var alert = alerts[provider] ?? AlertState()

        guard status == .critical else {
            guard alert.usageCritical else { return [] }
            alert.usageCritical = false
            alerts[provider] = alert
            return [.usageRecovered(provider)]
        }

        guard !alert.usageCritical else { return [] }  // 停留在临界不重复通知
        alert.usageCritical = true

        let now = clock.now
        let inCooldown = alert.lastUsageNotifiedAt.map { now.timeIntervalSince($0) < thresholds.notificationCooldown } ?? false
        guard !inCooldown, let basis = Self.alertBasis(for: snapshot) else {
            alerts[provider] = alert
            return []
        }

        alert.lastUsageNotifiedAt = now
        alerts[provider] = alert
        return [.usageCritical(UsageAlert(provider: provider, basis: basis))]
    }

    private func credentialInvalidEvents(_ provider: Provider) -> [EngineEvent] {
        var alert = alerts[provider] ?? AlertState()
        guard !alert.credentialInvalid else { return [] }

        alert.credentialInvalid = true
        let now = clock.now
        let inCooldown = alert.lastCredentialNotifiedAt.map { now.timeIntervalSince($0) < thresholds.notificationCooldown } ?? false
        if !inCooldown {
            alert.lastCredentialNotifiedAt = now
        }
        alerts[provider] = alert
        return inCooldown ? [] : [.credentialInvalid(provider)]
    }

    /// 临界依据:优先最低 plan-window(文案含剩余量/单位/百分比);无窗口者按余额分界。
    static func alertBasis(for snapshot: Snapshot) -> UsageAlert.Basis? {
        if let window = snapshot.planWindows.compactMap({ window -> (QuotaWindow, Double)? in
            guard let fraction = window.remainingFraction else { return nil }
            return (window, fraction)
        }).min(by: { $0.1 < $1.1 }) {
            return .window(
                label: window.0.label,
                remaining: window.0.remaining,
                limit: window.0.limit,
                unit: window.0.unit,
                percent: Percent.display(window.1)
            )
        }
        if snapshot.meta.accountAvailable == false {
            return .accountUnavailable
        }
        if let currency = snapshot.primaryCurrency {
            return .balance(amount: snapshot.totalBalance(currency: currency), currency: currency)
        }
        return nil
    }

    // MARK: - 工具

    static func isAuthStatus(_ statusCode: Int) -> Bool {
        statusCode == 401 || statusCode == 403
    }

    /// 端口约定是「错误文案不含凭据」;这里做纵深防御:适配器违约(如把请求描述当错误信息)
    /// 时,落进状态与事件的失败描述也抹掉凭据原文。
    /// 短于 `minimumRedactableCredentialLength` 的值不替换(这种值不构成有效凭据,替换只会误伤普通文案)。
    static func redactingCredential(_ text: String, credential: String) -> String {
        guard credential.count >= minimumRedactableCredentialLength else { return text }
        return text.replacingOccurrences(of: credential, with: "***")
    }

    /// 脱敏接受的最小凭据长度。
    static let minimumRedactableCredentialLength = 4

    static func transportDescription(_ error: Error) -> String {
        String(describing: type(of: error))
    }
}
