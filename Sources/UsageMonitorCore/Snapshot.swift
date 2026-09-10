import Foundation

public struct Snapshot: Codable, Equatable, Sendable {
    public var meta: SnapshotMeta
    public var windows: [QuotaWindow]
    public var balances: [Balance]
    public var raw: String

    public init(meta: SnapshotMeta, windows: [QuotaWindow], balances: [Balance], raw: String) {
        self.meta = meta
        self.windows = windows
        self.balances = balances
        self.raw = raw
    }
}

public struct SnapshotMeta: Codable, Equatable, Sendable {
    public var provider: Provider
    public var plan: Plan?
    public var fetchedAt: Date
    public var concurrencyLimit: Int?

    public init(provider: Provider, plan: Plan?, fetchedAt: Date, concurrencyLimit: Int?) {
        self.provider = provider
        self.plan = plan
        self.fetchedAt = fetchedAt
        self.concurrencyLimit = concurrencyLimit
    }
}

public struct Plan: Codable, Equatable, Sendable {
    public var level: String
    public var domain: String?

    public init(level: String, domain: String? = nil) {
        self.level = level
        self.domain = domain
    }
}
