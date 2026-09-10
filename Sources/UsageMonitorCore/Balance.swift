import Foundation

public struct Balance: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case topUp
        case granted
        case wallet
    }

    public var type: Kind
    public var amount: Decimal
    public var currency: String

    public init(type: Kind, amount: Decimal, currency: String) {
        self.type = type
        self.amount = amount
        self.currency = currency
    }
}
