import Foundation

public protocol CredentialStore: Sendable {
    func credential(for provider: Provider) throws -> String?
}

public struct FetchResponse: Equatable, Sendable {
    public var statusCode: Int
    public var body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

public protocol ProviderFetching: Sendable {
    var provider: Provider { get }
    func fetch(credential: String) async throws -> FetchResponse
}

public protocol SnapshotCache: Sendable {
    func loadSnapshots() throws -> [Provider: Snapshot]
    func saveSnapshot(_ snapshot: Snapshot) throws
}

public protocol Clock: Sendable {
    var now: Date { get }
}
