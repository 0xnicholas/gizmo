import Foundation
import UsageMonitorCore

/// 三家端点契约(`docs/research/*.md`):
///
/// | provider | 端点 | 认证 | 超时 |
/// |---|---|---|---|
/// | DeepSeek | `GET api.deepseek.com/user/balance` | `Authorization: Bearer <key>` | 8s |
/// | Kimi for Coding | `GET api.kimi.com/coding/v1/usages` + `/me` | `Bearer <token>` | 8s |
/// | GLM Coding Plan | `GET open.bigmodel.cn/api/monitor/usage/quota/limit` + `/model-usage` | `Authorization: <裸 key>` | 10s |
///
/// 解析集中封装在 UsageMonitorCore(单一改点);此层只发请求、带回状态码与响应体。
enum Endpoints {
    static let deepseekBalance = URL(string: "https://api.deepseek.com/user/balance")!
    static let kimiUsages = URL(string: "https://api.kimi.com/coding/v1/usages")!
    static let kimiProfile = URL(string: "https://api.kimi.com/coding/v1/me")!
    static let glmQuota = URL(string: "https://open.bigmodel.cn/api/monitor/usage/quota/limit")!
    static let glmModelUsage = URL(string: "https://open.bigmodel.cn/api/monitor/usage/model-usage")!
}

/// 薄 HTTP 客户端:每个请求现设超时;响应体原样返回。
///
/// 红线:凭据只进请求头,绝不进日志、不进快照 raw。
struct HTTPClient: Sendable {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    /// 附加分片:单独失败不抛出,记录为 `.failure` 交给解析层决定降级形态
    /// (Kimi 套餐元信息可退;GLM 近 7 天消耗显示「— 获取失败」)。
    func optional(_ part: FetchPart, url: URL, headers: [String: String], timeout: TimeInterval) async -> FetchPartResult {
        do {
            return .response(try await get(url, headers: headers, timeout: timeout))
        } catch {
            return .failure(.transport(String(describing: type(of: error))))
        }
    }

    func get(_ url: URL, headers: [String: String], timeout: TimeInterval) async throws -> FetchResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        return FetchResponse(statusCode: statusCode, body: data)
    }
}

// MARK: - DeepSeek

struct DeepSeekFetcher: ProviderFetching {
    let provider: Provider = .deepseek
    let http: HTTPClient

    init(http: HTTPClient = HTTPClient()) {
        self.http = http
    }

    func fetch(credential: String) async throws -> ProviderPayload {
        let response = try await http.get(
            Endpoints.deepseekBalance,
            headers: ["Authorization": "Bearer \(credential)"],
            timeout: 8
        )
        return ProviderPayload(parts: [.primary: .response(response)])
    }
}

// MARK: - Kimi for Coding

struct KimiFetcher: ProviderFetching {
    let provider: Provider = .kimi
    let http: HTTPClient

    init(http: HTTPClient = HTTPClient()) {
        self.http = http
    }

    func fetch(credential: String) async throws -> ProviderPayload {
        let headers = ["Authorization": "Bearer \(credential)"]
        let primary = try await http.get(Endpoints.kimiUsages, headers: headers, timeout: 8)

        // 套餐元信息是附加分片:单独失败不影响主数据(plan 退回 /usages 字段)。
        let profile = await http.optional(.profile, url: Endpoints.kimiProfile, headers: headers, timeout: 8)

        return ProviderPayload(parts: [.primary: .response(primary), .profile: profile])
    }
}

// MARK: - GLM Coding Plan

struct GLMFetcher: ProviderFetching {
    let provider: Provider = .glm
    let http: HTTPClient
    let clock: Clock

    init(http: HTTPClient = HTTPClient(), clock: Clock = SystemClock()) {
        self.http = http
        self.clock = clock
    }

    func fetch(credential: String) async throws -> ProviderPayload {
        // 套餐 API Key 直接放 Authorization,无 Bearer 前缀。
        let headers = [
            "Authorization": credential,
            "Accept-Language": "en-US,en",
        ]
        let primary = try await http.get(Endpoints.glmQuota, headers: headers, timeout: 10)

        // 近 7 天消耗是附加分片:取不到时归为 .failed,卡片该行显示「— 获取失败」,其余额度照常。
        let rolling = await http.optional(.rollingUsage, url: rollingUsageURL(), headers: headers, timeout: 10)

        return ProviderPayload(parts: [.primary: .response(primary), .rollingUsage: rolling])
    }

    /// 自然滚动 7 天窗口(近 7 天消耗的唯一口径)。
    func rollingUsageURL() -> URL {
        let end = clock.now
        let start = end.addingTimeInterval(-7 * 24 * 3_600)
        var components = URLComponents(url: Endpoints.glmModelUsage, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "startTime", value: Self.timestampFormatter.string(from: start)),
            URLQueryItem(name: "endTime", value: Self.timestampFormatter.string(from: end)),
        ]
        return components.url!
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
