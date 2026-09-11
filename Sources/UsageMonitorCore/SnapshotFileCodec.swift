import Foundation

/// 快照文件的可测部分:每 provider 最近一次成功快照的合并、编码与解码。
///
/// 文件 I/O 与原子写在 App 适配器(薄转发);这里只放「一份文件、无历史」的语义,
/// 便于在核心模块里断言「原子写后重读」。
public struct SnapshotFileCodec: Sendable {
    public struct File: Codable, Equatable, Sendable {
        public var version: Int
        public var snapshots: [Snapshot]

        public init(version: Int = SnapshotFileCodec.currentVersion, snapshots: [Snapshot]) {
            self.version = version
            self.snapshots = snapshots
        }
    }

    public static let currentVersion = 1

    public init() {}

    /// 成功快照覆盖该 provider 的旧条目,其他家原样保留。
    public func merging(_ snapshot: Snapshot, into current: [Provider: Snapshot]) -> [Provider: Snapshot] {
        var merged = current
        merged[snapshot.meta.provider] = snapshot
        return merged
    }

    /// 结果按 provider 枚举顺序排列,输出稳定(便于 diff 与人工检查)。
    public func encode(_ snapshots: [Provider: Snapshot]) throws -> Data {
        let file = File(snapshots: Provider.allCases.compactMap { snapshots[$0] })
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(file)
    }

    public func decode(_ data: Data) throws -> [Provider: Snapshot] {
        guard !data.isEmpty else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(File.self, from: data)
        return Dictionary(file.snapshots.map { ($0.meta.provider, $0) }, uniquingKeysWith: { _, latest in latest })
    }
}
