import Foundation
import UsageMonitorCore

// MARK: - 假件:注入四端口 + 可拨时钟

final class TestClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date = Fixture.epoch) {
        self.date = date
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func advance(_ interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        date = date.addingTimeInterval(interval)
    }
}

final class FakeCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Provider: String]
    private var readError: (any Error)?
    private var writeError: (any Error)?

    init(values: [Provider: String] = [:]) {
        self.values = values
    }

    /// 构造「凭据读取层异常」(如钥匙串锁定)。
    func failReads(with error: any Error) {
        lock.lock()
        defer { lock.unlock() }
        readError = error
    }

    /// 解除读取异常(钥匙串解锁)。
    func allowReads() {
        lock.lock()
        defer { lock.unlock() }
        readError = nil
    }

    /// 构造「写入/清除失败」(设置面保存失败红横幅路径)。
    func failWrites(with error: any Error) {
        lock.lock()
        defer { lock.unlock() }
        writeError = error
    }

    func set(_ value: String?, for provider: Provider) {
        lock.lock()
        defer { lock.unlock() }
        values[provider] = value
    }

    func credential(for provider: Provider) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let readError { throw readError }
        guard let value = values[provider] else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func save(_ value: String, for provider: Provider) throws {
        lock.lock()
        defer { lock.unlock() }
        if let writeError { throw writeError }
        values[provider] = value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func delete(for provider: Provider) throws {
        lock.lock()
        defer { lock.unlock() }
        if let writeError { throw writeError }
        values[provider] = nil
    }
}

final class StubFetcher: ProviderFetching, @unchecked Sendable {
    typealias Outcome = Result<ProviderPayload, any Error>

    let provider: Provider

    private let lock = NSLock()
    private var outcomes: [Outcome]
    private var callCountStorage = 0
    private var receivedCredentialsStorage: [String] = []

    /// - Parameter outcomes: 依次消费;用尽后重复最后一个(便于表达「持续同一行为」)。
    init(provider: Provider, outcomes: [Outcome] = []) {
        self.provider = provider
        self.outcomes = outcomes
    }

    convenience init(provider: Provider, payload: ProviderPayload) {
        self.init(provider: provider, outcomes: [.success(payload)])
    }

    /// 换成新的持续行为。
    func setOutcomes(_ outcomes: [Outcome]) {
        lock.lock()
        defer { lock.unlock() }
        self.outcomes = outcomes
    }

    /// 持续返回同一份响应。
    func respond(with payload: ProviderPayload) {
        setOutcomes([.success(payload)])
    }

    /// 持续抛出同一失败。
    func respond(with failure: FetchFailure) {
        setOutcomes([.failure(failure)])
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCountStorage
    }

    /// 假件实际收到的凭据值:用于断言引擎确实把端口读到的值原样递给了网络端口
    /// (以及反向断言凭据不会出现在引擎对外发布的任何东西里)。
    var lastCredential: String? {
        lock.lock()
        defer { lock.unlock() }
        return receivedCredentialsStorage.last
    }

    func fetch(credential: String) async throws -> ProviderPayload {
        try nextOutcome(credential: credential).get()
    }

    /// 同步取下一份行为(锁只在同步上下文中使用)。
    private func nextOutcome(credential: String) -> Outcome {
        lock.lock()
        defer { lock.unlock() }
        callCountStorage += 1
        receivedCredentialsStorage.append(credential)
        guard !outcomes.isEmpty else {
            return .failure(FetchFailure.transport("stub 未配置响应"))
        }
        return outcomes.count == 1 ? outcomes[0] : outcomes.removeFirst()
    }
}

final class RecordingCache: SnapshotCache, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Provider: Snapshot]
    private var saveCountStorage = 0

    init(snapshots: [Provider: Snapshot] = [:]) {
        self.stored = snapshots
    }

    var saveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return saveCountStorage
    }

    func snapshots() -> [Provider: Snapshot] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func loadSnapshots() throws -> [Provider: Snapshot] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func saveSnapshot(_ snapshot: Snapshot) throws {
        lock.lock()
        defer { lock.unlock() }
        stored[snapshot.meta.provider] = snapshot
        saveCountStorage += 1
    }
}

// MARK: - 录制形状的响应构造

enum Payloads {
    static func glm(fiveHourRemaining: Int = 11_358, weeklyRemaining: Int = 15_929) -> ProviderPayload {
        .ok("""
        {"code":200,"data":{"limits":[
          {"type":"CREDIT_LIMIT","unit":3,"number":5,"usage":12000,"currentValue":\(12_000 - fiveHourRemaining),"remaining":\(fiveHourRemaining),"nextResetTime":1788937420709},
          {"type":"CREDIT_LIMIT","unit":6,"number":1,"usage":60000,"currentValue":\(60_000 - weeklyRemaining),"remaining":\(weeklyRemaining),"nextResetTime":1789177578997}
        ],"level":"pro"},"success":true}
        """)
    }

    static func glmRollingUsage(tokens: Double = 7_500_000) -> ProviderPayload {
        .ok("""
        {"code":200,"data":{"x_time":["2026-09-03"],"tokensUsage":[\(tokens)],"granularity":"daily"},"success":true}
        """, part: .rollingUsage)
    }

    static func kimi(weekRemaining: Int = 66, rollingRemaining: Int = 90) -> ProviderPayload {
        .ok("""
        {"user":{"membership":{"level":"LEVEL_INTERMEDIATE"}},
         "usage":{"limit":"100","used":"\(100 - weekRemaining)","remaining":"\(weekRemaining)","resetTime":"2026-09-10T08:24:54Z"},
         "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},
                    "detail":{"used":"10","limit":"100","remaining":"\(rollingRemaining)","resetTime":"2026-09-09T06:24:54Z"}}],
         "parallel":{"limit":"20"},
         "boosterWallet":{"balance":{"amount":"3500000","unit":"UNIT_CURRENCY"},"monthlyChargeLimit":{"currency":"CNY"}},
         "domain":"DOMAIN_NEXUS"}
        """)
    }

    static func deepseek(total: String, available: Bool = true) -> ProviderPayload {
        .ok("""
        {"is_available":\(available),"balance_infos":[{"currency":"CNY","total_balance":"\(total)","granted_balance":"0.00","topped_up_balance":"\(total)"}]}
        """)
    }

    static func unauthorized() -> ProviderPayload {
        .response(#"{"error":{"message":"Authentication Fails"}}"#, statusCode: 401)
    }

    static func serverError() -> ProviderPayload {
        .response("{}", statusCode: 500)
    }
}

// MARK: - 引擎测试台

struct EngineHarness {
    let engine: UsageEngine
    let clock: TestClock
    let credentials: FakeCredentialStore
    let cache: RecordingCache
    let fetchers: [Provider: StubFetcher]

    init(
        thresholds: Thresholds = Thresholds(),
        cached: [Provider: Snapshot] = [:],
        credentials credentialValues: [Provider: String] = [.deepseek: "sk-ds", .kimi: "kimi-token", .glm: "glm-key"],
        payloads: [Provider: ProviderPayload] = [:],
        activeProviders: Set<Provider>? = nil,
        clock: TestClock = TestClock()
    ) {
        let clock = clock
        let credentials = FakeCredentialStore(values: credentialValues)
        let cache = RecordingCache(snapshots: cached)
        let active = activeProviders ?? Set(payloads.keys)
        var allFetchers: [Provider: StubFetcher] = [:]
        for provider in Provider.allCases {
            allFetchers[provider] = StubFetcher(
                provider: provider,
                outcomes: payloads[provider].map { [.success($0)] } ?? []
            )
        }
        var fetchers: [Provider: StubFetcher] = [:]
        var parsers: [Provider: any ProviderParser] = [:]
        for provider in active {
            fetchers[provider] = allFetchers[provider]
            switch provider {
            case .deepseek: parsers[provider] = DeepSeekParser()
            case .kimi: parsers[provider] = KimiParser()
            case .glm: parsers[provider] = GLMParser()
            }
        }
        self.clock = clock
        self.credentials = credentials
        self.cache = cache
        self.fetchers = fetchers
        self.engine = UsageEngine(
            credentials: credentials,
            fetchers: fetchers,
            parsers: parsers,
            cache: cache,
            clock: clock,
            thresholds: thresholds
        )
    }

    static func harness(payloads: [Provider: ProviderPayload]) -> EngineHarness {
        EngineHarness(payloads: payloads)
    }
}

extension EngineEvent {
    var notificationKind: String? {
        switch self {
        case .usageCritical: return "usage"
        case .credentialInvalid: return "credential"
        default: return nil
        }
    }
}
