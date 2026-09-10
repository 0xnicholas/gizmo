import Foundation
import Testing
import UsageMonitorCore

@Test func snapshotCodableRoundTrip() throws {
    let snapshot = Snapshot(
        meta: SnapshotMeta(
            provider: .glm,
            plan: Plan(level: "pro"),
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            concurrencyLimit: nil
        ),
        windows: [
            QuotaWindow(
                kind: .planWindow,
                unit: "积分",
                limit: 12_000,
                used: 641,
                remaining: 11_359,
                resetAt: Date(timeIntervalSince1970: 1_700_003_600)
            ),
            QuotaWindow(
                kind: .rateLimit,
                unit: "请求",
                limit: 100,
                used: 10,
                remaining: 90,
                resetAt: nil
            ),
        ],
        balances: [
            Balance(type: .topUp, amount: Decimal(string: "12.34")!, currency: "CNY")
        ],
        raw: #"{"data":{"level":"pro"}}"#
    )

    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(Snapshot.self, from: data)

    #expect(decoded == snapshot)
}
