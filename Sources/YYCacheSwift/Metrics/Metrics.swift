import Foundation
/// 指标快照（不可变）。

public struct YCMetricsSnapshot: Sendable {
    public let memoryHits: Int
    public let memoryMisses: Int
    public let diskHits: Int
    public let diskMisses: Int
    public let readsBytes: Int64
    public let writesBytes: Int64
    public let trimsCount: Int
    public let trimsBytes: Int64
    public let getCalls: Int
    public let getLatencyTotalNs: UInt64
    public let setCalls: Int
    public let setLatencyTotalNs: UInt64
}

/// 轻量指标聚合器（actor）。
/// - note: 默认按调用累加总量，可在上层计算均值/百分位。
public final actor YCMetrics {
    private var memoryHits = 0
    private var memoryMisses = 0
    private var diskHits = 0
    private var diskMisses = 0
    private var readsBytes: Int64 = 0
    private var writesBytes: Int64 = 0
    private var trimsCount = 0
    private var trimsBytes: Int64 = 0
    private var getCalls = 0
    private var getLatencyTotalNs: UInt64 = 0
    private var setCalls = 0
    private var setLatencyTotalNs: UInt64 = 0

    public init() {}

    // MARK: - Recorders（累加计数）
    public func recordMemoryHit() { memoryHits &+= 1 }
    public func recordMemoryMiss() { memoryMisses &+= 1 }
    public func recordDiskHit() { diskHits &+= 1 }
    public func recordDiskMiss() { diskMisses &+= 1 }
    public func recordRead(bytes: Int64) { readsBytes &+= bytes }
    public func recordWrite(bytes: Int64) { writesBytes &+= bytes }
    public func recordTrim(count: Int, bytes: Int64) { trimsCount &+= count; trimsBytes &+= bytes }
    public func recordGetLatency(ns: UInt64) { getCalls &+= 1; getLatencyTotalNs &+= ns }
    public func recordSetLatency(ns: UInt64) { setCalls &+= 1; setLatencyTotalNs &+= ns }

    // MARK: - Snapshot（抓取当前快照）
    public func snapshot() -> YCMetricsSnapshot {
        .init(
            memoryHits: memoryHits,
            memoryMisses: memoryMisses,
            diskHits: diskHits,
            diskMisses: diskMisses,
            readsBytes: readsBytes,
            writesBytes: writesBytes,
            trimsCount: trimsCount,
            trimsBytes: trimsBytes,
            getCalls: getCalls,
            getLatencyTotalNs: getLatencyTotalNs,
            setCalls: setCalls,
            setLatencyTotalNs: setLatencyTotalNs
        )
    }
}
