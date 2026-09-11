import Foundation
import UsageMonitorCore

/// 快照缓存适配器:`~/Library/Application Support/用量监视器/snapshots.json`(单份、无历史)。
///
/// 合并/编解码语义在 `UsageMonitorCore.SnapshotFileCodec`(有测试);这里只做文件 I/O 与原子写。
/// 读盘失败按「无缓存」处理,绝不影响 App 启动与凭据。
final class FileSnapshotCache: SnapshotCache, @unchecked Sendable {
    static let directoryName = "用量监视器"
    static let fileName = "snapshots.json"

    private let fileURL: URL
    private let codec: SnapshotFileCodec
    private let lock = NSLock()

    init(directory: URL? = nil, codec: SnapshotFileCodec = SnapshotFileCodec()) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Self.directoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent(Self.fileName)
        self.codec = codec
    }

    func loadSnapshots() throws -> [Provider: Snapshot] {
        lock.lock()
        defer { lock.unlock() }
        return try loadLocked()
    }

    func saveSnapshot(_ snapshot: Snapshot) throws {
        lock.lock()
        defer { lock.unlock() }

        // 读-改-写:只覆盖该 provider 的条目。
        let merged = codec.merging(snapshot, into: (try? loadLocked()) ?? [:])
        let data = try codec.encode(merged)
        // 原子写:先写临时文件再替换,避免半截 JSON。
        try data.write(to: fileURL, options: [.atomic])
    }

    private func loadLocked() throws -> [Provider: Snapshot] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        return try codec.decode(try Data(contentsOf: fileURL))
    }
}
