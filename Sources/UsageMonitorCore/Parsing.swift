import Foundation

/// 三家响应的归一化入口:只用 provider 各自的形状知识,产出统一快照。
public protocol ProviderParser: Sendable {
    func parse(payload: ProviderPayload, fetchedAt: Date) throws -> Snapshot
}

// MARK: - 容错 JSON 读取

/// JSONSerialization 之上的容错读取:字段缺失/类型变化返回 nil 而不崩溃,
/// 未知字段由 `raw` 原文保留。
enum JSONReader {
    static func object(from data: Data, context: String) throws -> [String: Any] {
        guard !data.isEmpty else { throw FetchFailure.parse("\(context):响应体为空") }
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw FetchFailure.parse("\(context):JSON 无法解析")
        }
        guard let object = value as? [String: Any] else {
            throw FetchFailure.parse("\(context):顶层不是对象")
        }
        return object
    }

    static func object(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func array(_ value: Any?) -> [Any]? {
        value as? [Any]
    }

    static func string(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        return nil
    }

    /// 接受数字与数字字符串(`"100"` 与 `100` 均视为 100)。
    static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    /// 接受数字与数字字符串(`"12000"` 与 `12000` 均可)。
    static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    static func bool(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            switch string.lowercased() {
            case "true": return true
            case "false": return false
            default: return nil
            }
        }
        return nil
    }

    /// 金额/额度字符串 → Decimal;固定 POSIX 小数点,避免随系统区域设置漂移。
    static func decimal(_ value: Any?) -> Decimal? {
        if let string = value as? String {
            return Decimal(string: string, locale: Locale(identifier: "en_US_POSIX"))
        }
        if let number = value as? NSNumber {
            return Decimal(string: number.stringValue, locale: Locale(identifier: "en_US_POSIX"))
        }
        return nil
    }

    /// RFC3339(Kimi `resetTime`);接受带/不带小数秒。
    static func rfc3339Date(_ value: Any?) -> Date? {
        guard let string = string(value) else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    /// epoch 毫秒(GLM `nextResetTime`)。
    static func epochMilliseconds(_ value: Any?) -> Date? {
        guard let milliseconds = double(value) else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }

    /// 业务错误体:`{"code":500,"msg":"...","success":false}`。
    static func businessError(in root: [String: Any], context: String) throws {
        if let success = bool(root["success"]), success == false {
            let code = int(root["code"]) ?? -1
            let message = string(root["msg"]) ?? string(root["message"]) ?? "未知业务错误"
            throw FetchFailure.business(code: code, message: "\(context):\(message)")
        }
        if let code = int(root["code"]), code != 200, root["data"] == nil {
            let message = string(root["msg"]) ?? string(root["message"]) ?? "未知业务错误"
            throw FetchFailure.business(code: code, message: "\(context):\(message)")
        }
    }
}

// MARK: - raw 组装

/// 原始响应原文:单分片即响应体本身,多分片按 `{"<part>": <原文>}` 拼接,
/// 原文逐字保留(未知字段不丢),且从不包含请求头。
enum RawResponses {
    /// 按给定顺序取出存在的分片原文(缺失分片不占位)。
    static func entries(from payload: ProviderPayload, parts: [FetchPart]) -> [(FetchPart, Data)] {
        parts.compactMap { part in
            guard let response = payload.response(part) else { return nil }
            return (part, response.body)
        }
    }

    static func compose(_ entries: [(FetchPart, Data)]) -> String {
        let decoded = entries.compactMap { part, data -> (String, String)? in
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            return (part.rawValue, text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if decoded.count == 1 { return decoded[0].1 }
        let body = decoded.map { #""\#($0.0)":\#($0.1)"# }.joined(separator: ",")
        return "{" + body + "}"
    }
}
