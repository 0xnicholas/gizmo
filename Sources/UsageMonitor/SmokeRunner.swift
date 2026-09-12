#if DEBUG
import Foundation
import UsageMonitorCore

/// 真实链路只读冒烟(#19 验收):真实 URLSession 适配器 → 三家端点 → 解析归一化 → 原子落盘。
///
/// 入口(仅 DEBUG 构建,跑完即退,不进常驻路径):
///
///     UsageMonitor --smoke-fetch        一轮「启动读盘(先发缓存)→ 新鲜刷新 → 落盘回读」
///     UsageMonitor --smoke-poll <间隔秒> <轮数>   真实时钟短周期轮询,经 AppModel 真实轮询循环
///     UsageMonitor --smoke-auth [provider]        假凭据走真实 401 路径(重试一次 → 凭据失效)
///     UsageMonitor --smoke-outage [provider]      真实传输超时 ×3 轮 → 加载失败 → 恢复
///     UsageMonitor --smoke-login-item             真实 LaunchAgent 写删 + launchctl 即时加载/卸载(#22)
///
/// 凭据仅进程内存、永不回显:优先取环境变量 `SMOKE_DEEPSEEK` / `SMOKE_KIMI` / `SMOKE_GLM`,
/// 缺者回落真实 Keychain。输出只含归一化字段与脱敏失败描述,不含凭据原文、不含 raw。
@MainActor
enum SmokeRunner {
    static let isRequested = CommandLine.arguments.contains { $0.hasPrefix("--smoke-") }

    /// 冒烟凭据环境变量名(值为真实凭据,只进进程内存)。
    static let environmentNames: [Provider: String] = [
        .deepseek: "SMOKE_DEEPSEEK",
        .kimi: "SMOKE_KIMI",
        .glm: "SMOKE_GLM",
    ]

    static func run() async -> Never {
        let arguments = CommandLine.arguments
        do {
            switch arguments.first(where: { $0.hasPrefix("--smoke-") }) {
            case "--smoke-fetch":
                exit(await smokeFetch())
            case "--smoke-poll":
                let interval = Double(argument(after: "--smoke-poll", in: arguments) ?? "") ?? 5
                let cycles = Int(argument(after: "--smoke-poll", at: 2, in: arguments) ?? "") ?? 2
                guard interval >= 2, cycles >= 1, cycles <= 10 else {
                    throw UsageError("间隔至少 2 秒(轮询循环最小睡眠 1 秒),轮数 1–10")
                }
                exit(await smokePoll(intervalSeconds: interval, cycles: cycles))
            case "--smoke-auth":
                let provider = argument(after: "--smoke-auth", in: arguments).flatMap(Provider.init(rawValue:)) ?? .deepseek
                exit(await smokeAuth(provider: provider))
            case "--smoke-outage":
                let provider = argument(after: "--smoke-outage", in: arguments).flatMap(Provider.init(rawValue:)) ?? .deepseek
                exit(await smokeOutage(provider: provider))
            case "--smoke-login-item":
                exit(smokeLoginItem())
            default:
                throw UsageError("未知冒烟模式:\(arguments.first(where: { $0.hasPrefix("--smoke-") }) ?? "")")
            }
        } catch let error as UsageError {
            FileHandle.standardError.write("冒烟参数错误:\(error.message)\n".data(using: .utf8)!)
            exit(2)
        } catch {
            FileHandle.standardError.write("冒烟执行异常:\(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    struct UsageError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    // MARK: - --smoke-fetch:启动先发缓存,再新鲜刷新,再落盘回读

    /// 覆盖验收:「三家端点冒烟 200、归一化快照与调研文档字段一致」
    /// 与「杀 App 重启先显示旧数据、随后自动刷新为新鲜数据」(连跑两次,第二次的
    /// 阶段 1 应显示第一次的 fetchedAt)。
    private static func smokeFetch() async -> Int32 {
        print("== 冒烟:smoke-fetch(真实适配器 → 三家端点 → 归一化 → 落盘)==")
        let store = SmokeCredentialStore(environment: environmentOverrides)
        reportCredentialSources(store)

        let engine = realEngine(credentials: store)

        print("\n-- 阶段 1:启动读盘(先发缓存,不触发网络、不触发通知)")
        _ = await engine.start()
        let cachedState = await engine.state
        for provider in Provider.displayOrder {
            let state = cachedState.provider(provider)
            if let snapshot = state.snapshot {
                print("[\(provider.rawValue)] 缓存快照 fetchedAt=\(Self.iso.string(from: snapshot.meta.fetchedAt)) status=\(state.status)")
            } else {
                print("[\(provider.rawValue)] 无缓存")
            }
        }

        print("\n-- 阶段 2:新鲜刷新(三家并行;成快照即主端点 HTTP 200)")
        let events = await engine.refreshAll()
        let freshState = await engine.state
        var failures: [Provider] = []
        for provider in Provider.displayOrder {
            let state = freshState.provider(provider)
            if store.knowsCredential(for: provider) {
                if let snapshot = state.snapshot, state.failureDescriptor == nil, snapshot.meta.fetchedAt == state.lastSuccessAt {
                    print("[\(provider.rawValue)] HTTP 200 ✓")
                    for line in describe(snapshot: snapshot) { print("    " + line) }
                } else {
                    failures.append(provider)
                    print("[\(provider.rawValue)] 失败:\(state.failureDescriptor ?? "未知")")
                    if let snapshot = state.snapshot {
                        print("    (保留最近成功快照 fetchedAt=\(Self.iso.string(from: snapshot.meta.fetchedAt)))")
                    }
                }
            } else {
                print("[\(provider.rawValue)] 凭据缺失:跳过(不算失败)")
            }
        }
        print("    事件:\(events.map { Self.describe(event: $0) }.joined(separator: ", "))")

        print("\n-- 阶段 3:落盘回读(原子写后重读)")
        let reloaded = (try? FileSnapshotCache().loadSnapshots()) ?? [:]
        var reloadFailures: [Provider] = []
        for provider in Provider.displayOrder where freshState.provider(provider).snapshot != nil {
            let onDisk = reloaded[provider]?.meta.fetchedAt
            let expected = freshState.provider(provider).snapshot?.meta.fetchedAt
            // iso8601 落盘舍去亚秒精度:按秒级容差比对。
            if let onDisk, let expected, abs(onDisk.timeIntervalSince(expected)) < 1 {
                print("[\(provider.rawValue)] 落盘一致 ✓ fetchedAt=\(Self.iso.string(from: onDisk))")
            } else {
                reloadFailures.append(provider)
                print("[\(provider.rawValue)] 落盘不一致 ✗")
            }
        }

        if failures.isEmpty, reloadFailures.isEmpty, !reloaded.isEmpty {
            print("\n冒烟通过 ✓")
            return 0
        }
        if reloaded.isEmpty {
            print("\n冒烟失败:没有任何家成功落盘")
        } else {
            print("\n冒烟失败 ✗ 失败家:\((failures + reloadFailures).map { $0.rawValue }.sorted().joined(separator: ", "))")
        }
        return 1
    }

    // MARK: - --smoke-poll:真实时钟短周期轮询(经 AppModel 真实循环)

    /// 覆盖验收:「30 分钟轮询在真实运行方式下验证」——注入短周期 Thresholds,
    /// 走的仍是 AppModel.startPolling 的真实循环(deadline → sleep → shouldRefresh → refreshAll)。
    private static func smokePoll(intervalSeconds: Double, cycles: Int) async -> Int32 {
        print("== 冒烟:smoke-poll 间隔 \(intervalSeconds)s × \(cycles) 轮(真实时钟,AppModel 真实轮询循环)==")
        let store = SmokeCredentialStore(environment: environmentOverrides)
        reportCredentialSources(store)

        let model = AppModel(credentials: store, thresholds: Thresholds(refreshInterval: intervalSeconds))
        model.start()

        // 观察真实完成时刻:bootstrap 一轮 + 轮询 N 轮。
        let expectedCompletions = cycles + 1
        let timeout = Date().addingTimeInterval(intervalSeconds * Double(cycles) * 2 + 60)
        var completions: [Date] = []
        while Date() < timeout {
            let finishedAt = model.state.lastRefreshFinishedAt
            if let finishedAt, finishedAt != completions.last {
                completions.append(finishedAt)
                let snapshotCount = model.state.providers.values.filter(\.hasSnapshot).count
                print("刷新 #\(completions.count) 完成于 \(Self.iso.string(from: finishedAt))(持有快照家数 \(snapshotCount))")
                if completions.count >= expectedCompletions { break }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        guard completions.count >= expectedCompletions else {
            print("\n冒烟失败:期望 \(expectedCompletions) 轮刷新,实际 \(completions.count)(超时)")
            return 1
        }
        // 轮询间隔:不得早于周期(0.9× 容差);迟到上限给足真实网络时延余量。
        let spacings = zip(completions, completions.dropFirst()).map { $1.timeIntervalSince($0) }
        let tooEarly = spacings.filter { $0 < intervalSeconds * 0.9 }
        let tooLate = spacings.filter { $0 > intervalSeconds * 2 + 15 }
        print("\n轮询间隔:\(spacings.map { String(format: "%.1fs", $0) }.joined(separator: ", "))")
        if tooEarly.isEmpty, tooLate.isEmpty {
            print("冒烟通过 ✓(周期无提前、无异常迟到)")
            return 0
        }
        print("冒烟失败 ✗ 间隔越界(过早:\(tooEarly.count),过晚:\(tooLate.count))")
        return 1
    }

    // MARK: - --smoke-auth:假凭据走真实 401 路径

    /// 覆盖验收:「401 路径:重试一次 → 凭据失效事件」——对真实端点用假凭据,
    /// 预期引擎重试一次后仍 401 → credentialInvalid 事件 + 该家进入「失效」。
    /// 只影响该家,其余家照常;失败路径不写缓存。
    private static func smokeAuth(provider: Provider) async -> Int32 {
        print("== 冒烟:smoke-auth [\(provider.rawValue)](假凭据 → 真实端点 401 → 重试一次 → 失效)==")
        let engine = realEngine(credentials: FixedCredentialStore(target: provider, value: bogusCredential))

        _ = await engine.start()
        let events = await engine.refresh(provider)
        let state = await engine.state.provider(provider)

        print("事件:\(events.map { Self.describe(event: $0) }.joined(separator: ", "))")
        print("凭据状态:\(state.credential)")
        print("失败描述:\(state.failureDescriptor ?? "无")")

        let invalid = state.credential == .invalid
        let hasEvent = events.contains { if case .credentialInvalid = $0 { return true } else { return false } }
        let countedAsNetworkFailure = await engine.state.provider(provider).consecutiveFailures
        if invalid, hasEvent, countedAsNetworkFailure == 0 {
            print("\n冒烟通过 ✓(authError 与 networkError 分家:不计入失败轮数)")
            return 0
        }
        print("\n冒烟失败 ✗(失效=\(invalid),事件=\(hasEvent),失败轮数=\(countedAsNetworkFailure))")
        return 1
    }

    // MARK: - --smoke-outage:真实传输超时 ×3 轮 → 加载失败 → 恢复

    /// 覆盖验收:「单家失败不影响其他;连续 3 轮后该家呈加载失败,网络恢复后自动复原」。
    /// 黑洞期间该家请求指向不可路由地址(RFC 5737 TEST-NET-1)制造真实传输超时。
    private static func smokeOutage(provider: Provider) async -> Int32 {
        print("== 冒烟:smoke-outage [\(provider.rawValue)](真实传输超时 ×3 轮 → 加载失败 → 恢复)==")
        let blackhole = BlackholeToggleFetcher(wrapping: realFetcher(provider: provider, clock: SystemClock()))
        let store = SmokeCredentialStore(environment: environmentOverrides)
        reportCredentialSources(store)

        let engine = realEngine(credentials: store, fetcherOverrides: [provider: blackhole])

        _ = await engine.start()
        guard store.knowsCredential(for: provider) else {
            print("冒烟失败:该家没有可用凭据(环境变量或 Keychain),无法制造断网场景")
            return 2
        }
        // 失败不清缓存的前提:先让该家成功一次,持有可保留的快照。
        let seeded = await engine.refresh(provider)
        let hadSnapshotAtStart = await engine.state.provider(provider).hasSnapshot
        if hadSnapshotAtStart {
            print("预置成功快照 ✓(失败期间应一直保留):\(seeded.map { Self.describe(event: $0) }.joined(separator: ", "))")
        } else {
            print("预置成功快照失败(该家当前拉不通),后续不再断言缓存保留")
        }

        var pass = true
        blackhole.isBlackholed = true
        for round in 1...3 {
            let others = Provider.allCases.filter { $0 != provider && store.knowsCredential(for: $0) }
            let events = await engine.refreshAll()
            let target = await engine.state.provider(provider)
            let othersSucceeded = await othersAllFresh(engine: engine, others: others)
            let loadFailed = events.contains { if case .loadFailed(let p, _) = $0 { return p == provider } else { return false } }
            print("第 \(round) 轮:目标[\(provider.rawValue)] \(target.failureDescriptor ?? "?") 连续失败=\(target.consecutiveFailures) 加载失败=\(target.loadFailed) | 其余家本轮成快照=\(othersSucceeded ? "✓" : "✗") | 事件:\(events.map { Self.describe(event: $0) }.joined(separator: ", "))")
            // 失败不清缓存:快照仍持有(仅在预置成功过时才可断言)。
            if hadSnapshotAtStart, target.snapshot == nil { pass = false; print("  ✗ 失败期间丢了最近成功快照") }
            if round < 3, target.loadFailed { pass = false; print("  ✗ 未满 3 轮就进入加载失败") }
            if round == 3, !loadFailed { pass = false; print("  ✗ 第 3 轮未发 loadFailed 事件") }
            if !othersSucceeded { pass = false; print("  ✗ 单家失败影响了其他家") }
        }

        print("\n-- 恢复:切回真实路由,单刷该家")
        blackhole.isBlackholed = false
        let events = await engine.refresh(provider)
        let target = await engine.state.provider(provider)
        let recovered = events.contains { if case .loadRecovered = $0 { return true } else { return false } }
        print("事件:\(events.map { Self.describe(event: $0) }.joined(separator: ", "))")
        print("凭据状态:\(target.credential) 失败轮数:\(target.consecutiveFailures) 加载失败:\(target.loadFailed)")
        if !recovered { pass = false; print("  ✗ 未发 loadRecovered 事件") }
        if target.loadFailed || target.consecutiveFailures != 0 { pass = false; print("  ✗ 恢复未清除失败状态") }
        if target.credential != .configured { pass = false; print("  ✗ 网络失败被误判为凭据问题") }

        print(pass ? "\n冒烟通过 ✓" : "\n冒烟失败 ✗")
        return pass ? 0 : 1
    }

    // MARK: - --smoke-login-item:真实 LaunchAgent 写删 + 真实 launchctl 即时生效

    /// 覆盖验收(#22):「开关即时生效(不需重启);plist 内容正确指向可执行文件」。
    /// 用冒烟专用 label + 无害程序(/usr/bin/true,避免 RunAtLoad 递归拉起自身):
    /// 真实写 ~/Library/LaunchAgents 下冒烟 plist、真实 bootstrap/bootout,
    /// 结束无残留;生产 label 的真实开关不受影响。下次登录的自启本身需人工验证。
    private static func smokeLoginItem() -> Int32 {
        print("== 冒烟:smoke-login-item(真实 plist 写删 + 真实 launchctl 即时加载/卸载)==")
        let item = LaunchAgentLoginItem(label: "com.nicholasli.usagemonitor.smoke", executablePath: "/usr/bin/true")
        var pass = true

        func check(_ condition: Bool, _ message: String) {
            print((condition ? "✓ " : "✗ ") + message)
            if !condition { pass = false }
        }

        // 无论成败,恢复无残留。
        defer {
            try? item.setEnabled(false)
            if FileManager.default.fileExists(atPath: item.plistURL.path) {
                print("清理:冒烟 plist 仍在,请手动删除 \(item.plistURL.path)")
            }
        }
        if item.isEnabled {
            print("发现上次冒烟残留,先清理再开始")
            try? item.setEnabled(false)
        }

        print("\n-- 阶段 1:开启(写 plist + bootstrap 即时加载)")
        do {
            try item.setEnabled(true)
        } catch {
            print("✗ 开启抛错:\(error)")
            return 1
        }
        check(item.isEnabled, "plist 已落盘:\(item.plistURL.path)")
        if let plist = try? PropertyListSerialization.propertyList(
            from: Data(contentsOf: item.plistURL), options: [], format: nil
        ) as? [String: Any] {
            check(plist["Label"] as? String == item.label, "plist Label = \(item.label)")
            check((plist["RunAtLoad"] as? Bool) == true, "plist RunAtLoad = true")
            check(plist["ProgramArguments"] as? [String] == ["/usr/bin/true"], "plist ProgramArguments 指向可执行文件")
        } else {
            check(false, "plist 可解析")
        }
        let loaded = LaunchAgentLoginItem.launchctl(["print", item.sessionTarget])
        check(loaded.status == 0, "launchctl print:服务已在当前会话加载(即时生效,无需重启)")
        if loaded.status != 0, !loaded.output.isEmpty { print(loaded.output) }

        print("\n-- 阶段 2:关闭(bootout + 删 plist,即时卸载)")
        do {
            try item.setEnabled(false)
        } catch {
            print("✗ 关闭抛错:\(error)")
            return 1
        }
        check(!item.isEnabled, "plist 已删除")
        let unloaded = LaunchAgentLoginItem.launchctl(["print", item.sessionTarget])
        check(unloaded.status != 0, "launchctl print:服务已从当前会话卸载")

        print(pass ? "\n冒烟通过 ✓" : "\n冒烟失败 ✗")
        return pass ? 0 : 1
    }

    // MARK: - 真实组件工厂

    /// 与 AppModel 同构的真实引擎:真实适配器 + 真实 Keychain(或环境变量覆盖)+ 真实落盘。
    /// `fetcherOverrides` 供断网冒烟替换个别家的适配器(如黑洞开关),其余家仍走真实适配器。
    static func realEngine(
        credentials: CredentialStore,
        fetcherOverrides: [Provider: any ProviderFetching] = [:]
    ) -> UsageEngine {
        let clock = SystemClock()
        return UsageEngine(
            credentials: credentials,
            fetchers: Dictionary(uniqueKeysWithValues: Provider.allCases.map { provider in
                (provider, fetcherOverrides[provider] ?? realFetcher(provider: provider, clock: clock))
            }),
            parsers: [ .deepseek: DeepSeekParser(), .kimi: KimiParser(), .glm: GLMParser() ],
            cache: FileSnapshotCache(),
            clock: clock
        )
    }

    static func realFetcher(provider: Provider, clock: Clock) -> any ProviderFetching {
        switch provider {
        case .deepseek: return DeepSeekFetcher()
        case .kimi: return KimiFetcher()
        case .glm: return GLMFetcher(clock: clock)
        }
    }

    // MARK: - 冒烟专用凭据存储

    /// 环境变量覆盖 + Keychain 回落:值只在进程内存,trim 后使用;写入/清除一律拒绝(只读冒烟)。
    struct SmokeCredentialStore: CredentialStore {
        private let overrides: [Provider: String]
        private let base: KeychainCredentialStore

        init(environment: [Provider: String], base: KeychainCredentialStore = KeychainCredentialStore()) {
            self.overrides = environment
            self.base = base
        }

        func credential(for provider: Provider) throws -> String? {
            if let value = overrides[provider]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
            return try base.credential(for: provider)
        }

        func save(_ value: String, for provider: Provider) throws {
            throw ReadOnly.error
        }

        func delete(for provider: Provider) throws {
            throw ReadOnly.error
        }

        /// 报告用:该家是否有可用凭据(不暴露值)。
        func knowsCredential(for provider: Provider) -> Bool {
            (try? credential(for: provider)).flatMap { ($0?.isEmpty == false) } == true
        }

        enum ReadOnly: LocalizedError {
            case error
            var errorDescription: String? { "冒烟为只读,不写钥匙串" }
        }
    }

    /// 只对目标家返回固定值(假凭据),其余家返回 nil(不发请求)。
    struct FixedCredentialStore: CredentialStore {
        let target: Provider
        let value: String

        func credential(for provider: Provider) throws -> String? {
            provider == target ? value : nil
        }

        func save(_ value: String, for provider: Provider) throws { throw SmokeCredentialStore.ReadOnly.error }
        func delete(for provider: Provider) throws { throw SmokeCredentialStore.ReadOnly.error }
    }

    /// 黑洞开关:黑洞期间把请求发往不可路由地址,制造真实传输层超时;切回后透传真实适配器。
    final class BlackholeToggleFetcher: ProviderFetching, @unchecked Sendable {
        let provider: Provider
        var isBlackholed: Bool
        private let real: any ProviderFetching
        private let http = HTTPClient()

        init(wrapping real: any ProviderFetching, isBlackholed: Bool = false) {
            self.provider = real.provider
            self.real = real
            self.isBlackholed = isBlackholed
        }

        func fetch(credential: String) async throws -> ProviderPayload {
            guard isBlackholed else {
                return try await real.fetch(credential: credential)
            }
            // RFC 5737 TEST-NET-1:保证不可路由;真实 URLSession 超时路径。
            do {
                _ = try await http.get(
                    URL(string: "https://192.0.2.1/")!,
                    headers: [:],
                    timeout: 8
                )
            } catch {
                throw FetchFailure.transport(String(describing: type(of: error)))
            }
            throw FetchFailure.transport("黑洞地址意外可达")
        }
    }

    /// 假凭据:长度足够触发脱敏下限,格式形似真实 key,但绝不可能是有效值。
    static let bogusCredential = "sk-smoke-invalid-000000000000000000000000000"

    static var environmentOverrides: [Provider: String] {
        let environment = ProcessInfo.processInfo.environment
        return Dictionary(
            uniqueKeysWithValues: environmentNames.compactMap { provider, name in
                environment[name].map { (provider, $0) }
            }
        )
    }

    // MARK: - 报告

    static func reportCredentialSources(_ store: SmokeCredentialStore) {
        let parts = environmentNames.sorted { $0.value < $1.value }.map { provider, name -> String in
            if environmentOverrides.index(forKey: provider) != nil {
                return "\(provider.rawValue)=环境变量\(name)"
            }
            return ((try? store.credential(for: provider)) ?? nil) != nil
                ? "\(provider.rawValue)=Keychain"
                : "\(provider.rawValue)=缺失"
        }
        print("凭据来源(不回显值):\(parts.joined(separator: " | "))")
    }

    /// 归一化快照摘要:字段口径与 docs/research/*.md 一致,供人工对照。
    static func describe(snapshot: Snapshot) -> [String] {
        var lines: [String] = []
        let meta = snapshot.meta
        if let plan = meta.plan {
            lines.append("套餐:\(plan.level)\(plan.domain.map { "(\($0))" } ?? "")")
        }
        if let concurrency = meta.concurrencyLimit {
            lines.append("并发上限:\(concurrency)")
        }
        if let available = meta.accountAvailable {
            lines.append("账户可用:\(available ? "是" : "否")")
        }
        for window in snapshot.windows {
            let percent = window.remainingFraction.map { "\(Percent.display($0))%" } ?? "—"
            let reset = window.resetAt.map { Self.iso.string(from: $0) } ?? "—"
            lines.append("窗口[\(window.kind == .planWindow ? "plan" : "rate")] \(window.label) \(window.used)/\(window.limit) 剩余 \(window.remaining) \(window.unit)(\(percent),重置 \(reset))")
        }
        for currency in snapshot.currencies {
            let entries = snapshot.balances.filter { $0.currency == currency }
            let parts = entries.map { "\(Self.describe(kind: $0.type)) \($0.amount)" }
            lines.append("余额[\(currency)]:\(parts.joined(separator: " + "))")
        }
        if let rolling = snapshot.rollingUsage {
            switch rolling {
            case .value(let amount, let unit):
                lines.append("近 7 天用量:\(amount) \(unit)")
            case .failed:
                lines.append("近 7 天用量:获取失败(行级降级,其余照常)")
            }
        } else {
            lines.append("近 7 天用量:—(该家无直接来源,不渲染)")
        }
        lines.append("status:\(StatusEvaluator(thresholds: Thresholds()).status(for: snapshot))")
        return lines
    }

    static func describe(kind: Balance.Kind) -> String {
        switch kind {
        case .topUp: return "充值"
        case .granted: return "赠送"
        case .wallet: return "钱包"
        }
    }

    static func describe(event: EngineEvent) -> String {
        switch event {
        case .snapshotUpdated(let provider): return "snapshotUpdated(\(provider.rawValue))"
        case .credentialInvalid(let provider): return "credentialInvalid(\(provider.rawValue))"
        case .credentialRestored(let provider): return "credentialRestored(\(provider.rawValue))"
        case .usageCritical(let alert):
            return "usageCritical(\(alert.provider.rawValue))"
        case .usageRecovered(let provider): return "usageRecovered(\(provider.rawValue))"
        case .loadFailed(let provider, _): return "loadFailed(\(provider.rawValue))"
        case .loadRecovered(let provider): return "loadRecovered(\(provider.rawValue))"
        }
    }

    static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    // MARK: - 参数解析

    /// 其余家是否仍健康持有快照(未被断网家牵连)。
    static func othersAllFresh(engine: UsageEngine, others: [Provider]) async -> Bool {
        for provider in others {
            let state = await engine.state.provider(provider)
            if !state.hasSnapshot || state.loadFailed { return false }
        }
        return true
    }

    static func argument(after flag: String, at offset: Int = 1, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let target = index + offset
        guard target < arguments.count, !arguments[target].hasPrefix("--") else { return nil }
        return arguments[target]
    }
}
#endif
