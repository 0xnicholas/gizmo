import Foundation

public struct QuotaWindow: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case planWindow = "plan-window"
        case rateLimit = "rate-limit"
    }

    public var kind: Kind
    public var unit: String
    public var limit: Int
    public var used: Int
    public var remaining: Int
    public var resetAt: Date?

    public init(kind: Kind, unit: String, limit: Int, used: Int, remaining: Int, resetAt: Date?) {
        self.kind = kind
        self.unit = unit
        self.limit = limit
        self.used = used
        self.remaining = remaining
        self.resetAt = resetAt
    }
}
