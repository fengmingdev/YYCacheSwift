import Foundation
/// YYCacheSwift 顶层配置与缓存 API。

/// 缓存全局配置（线程安全、可跨实例共享）。
public struct CacheConfiguration: Sendable {
    /// 内存缓存配置。
    public struct Memory: Sendable {
        /// 内存中允许的最大条目数（LRU 超限时逐条淘汰）。
        public var countLimit: Int
        /// 累计成本上限（配合 `set(_:cost:)` 控制内存占用，LRU 超限时淘汰）。
        public var costLimit: Int
        /// 访问年龄上限（最近一次访问距当前超过该时长将被修剪）。
        public var ageLimit: TimeInterval
        /// 自动修剪的时间间隔（秒），<=0 表示关闭定时修剪。
        public var autoTrimInterval: TimeInterval
        /// 兼容占位：异步释放对象的开关（当前实现不改变释放时机）。
        public var releaseAsynchronously: Bool
        /// 兼容占位：在主线程释放对象的开关（当前实现不改变释放时机）。
        public var releaseOnMainThread: Bool

        /// 初始化内存配置。
        /// - parameters:
        ///   - countLimit: 最大条目数
        ///   - costLimit: 成本上限（自定义成本）
        ///   - ageLimit: 访问年龄上限（秒）
        ///   - autoTrimInterval: 自动修剪间隔（秒）
        ///   - releaseAsynchronously: 兼容占位，当前不生效
        ///   - releaseOnMainThread: 兼容占位，当前不生效
        public init(
            countLimit: Int = 1000,
            costLimit: Int = 50 * 1024 * 1024,
            ageLimit: TimeInterval = .infinity,
            autoTrimInterval: TimeInterval = 5,
            releaseAsynchronously: Bool = true,
            releaseOnMainThread: Bool = false
        ) {
            self.countLimit = countLimit
            self.costLimit = costLimit
            self.ageLimit = ageLimit
            self.autoTrimInterval = autoTrimInterval
            self.releaseAsynchronously = releaseAsynchronously
            self.releaseOnMainThread = releaseOnMainThread
        }
    }

    /// 磁盘缓存配置。
    public struct Disk: Sendable {
        /// 是否启用磁盘层（关闭时仅使用内存层）。
        public var isEnabled: Bool
        /// 总字节数上限（超过后按 LRU 修剪）。
        public var byteLimit: Int
        /// 条目数上限（超过后按 LRU 修剪）。
        public var countLimit: Int
        /// 访问年龄上限（超过后按 LRU 修剪）。
        public var ageLimit: TimeInterval
        /// 自动修剪的时间间隔（秒）。
        public var autoTrimInterval: TimeInterval
        /// 小对象内联阈值（<= 阈值的对象写入 SQLite 列）。
        public var inlineThreshold: Int
        /// 存储模式：`mixed`（自动内联/文件）、`sqlite`（强制内联）、`file`（强制文件）。
        public var storageMode: StorageMode

        /// 磁盘存储模式。
        public enum StorageMode: Sendable {
            case mixed, sqlite, file
        }

        public init(
            isEnabled: Bool = false,
            byteLimit: Int = 1024 * 1024 * 1024,
            countLimit: Int = 100_000,
            ageLimit: TimeInterval = .infinity,
            autoTrimInterval: TimeInterval = 30,
            inlineThreshold: Int = 20 * 1024,
            storageMode: StorageMode = .mixed
        ) {
            self.isEnabled = isEnabled
            self.byteLimit = byteLimit
            self.countLimit = countLimit
            self.ageLimit = ageLimit
            self.autoTrimInterval = autoTrimInterval
            self.inlineThreshold = inlineThreshold
            self.storageMode = storageMode
        }
    }

    /// 缓存命名空间（用于磁盘目录划分）。
    public var name: String
    /// 自定义磁盘目录（不传则使用系统 Caches）。
    public var directoryURL: URL?
    /// 内存层配置。
    public var memory: Memory
    /// 磁盘层配置。
    public var disk: Disk
    /// 键编码器（默认直传）；建议在生产环境使用哈希（如 SHA256）。
    public var keyEncoder: @Sendable (String) -> String
    /// 是否开启日志输出（默认 Debug 开启）。
    public var loggingEnabled: Bool
    /// 是否开启指标采集（默认开启）。
    public var metricsEnabled: Bool

    public init(
        name: String,
        directoryURL: URL? = nil,
        memory: Memory = Memory(),
        disk: Disk = Disk(),
        keyEncoder: @escaping @Sendable (String) -> String = { $0 },
        loggingEnabled: Bool = {
            #if DEBUG
            return true
            #else
            return false
            #endif
        }(),
        metricsEnabled: Bool = true
    ) {
        self.name = name
        self.directoryURL = directoryURL
        self.memory = memory
        self.disk = disk
        self.keyEncoder = keyEncoder
        self.loggingEnabled = loggingEnabled
        self.metricsEnabled = metricsEnabled
    }

    /// 默认配置工厂（便捷构造）。
    public static func `default`(name: String) -> CacheConfiguration {
        .init(name: name)
    }
}

/// 缓存错误类型。
public enum CacheError: Error, Sendable {
    case encoding
    case decoding
    case io
    case sqlite
    case invalidKey
    case cancelled
}

/// 通用编码/解码协议。实现者负责将 Value 与 Data 互转。
public protocol DataTransforming<Value> {
    associatedtype Value
    func encode(_ value: Value) throws -> Data
    func decode(_ data: Data) throws -> Value
}

/// 直接存取二进制数据的 transformer。
public struct RawDataTransform: DataTransforming {
    public typealias Value = Data
    public init() {}
    public func encode(_ value: Data) throws -> Data { value }
    public func decode(_ data: Data) throws -> Data { data }
}

/// 使用 Codable（默认 JSON）实现的 transformer。
public struct CodableTransform<T: Codable>: DataTransforming {
    public typealias Value = T
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(encoder: JSONEncoder = JSONEncoder(), decoder: JSONDecoder = JSONDecoder()) {
        self.encoder = encoder
        self.decoder = decoder
    }

    public func encode(_ value: T) throws -> Data { try encoder.encode(value) }
    public func decode(_ data: Data) throws -> T { try decoder.decode(T.self, from: data) }
}

/// 分层 Key-Value 缓存：内存（LRU）+ 磁盘（SQLite 混合存储）。
/// - thread-safety: 线程安全（内部使用 actor/串行化访问）
/// - performance: get/set 为异步 API；内存命中 O(1)。
public final class Cache<Value: Sendable> {
    public let configuration: CacheConfiguration

    // Memory layer
    private let memory: MemoryCache<Value>

    // Disk layer (placeholder for now)
    private let disk: DiskStorage?

    private let encode: ((Value) throws -> Data)?
    private let decode: ((Data) throws -> Value)?
    private let transformer: AnyTransformer<Value>?

    public let metrics: YCMetrics
    private let loggingEnabled: Bool
    private let metricsEnabled: Bool
    private let pending = PendingOps<Value>()
    private let writer = CoalescingWriter()

    /// 初始化缓存。
    /// - parameters:
    ///   - configuration: 全局配置。
    ///   - encode/decode: 兼容旧用法的闭包 transformer（可选）。
    ///   - transformer: 推荐的类型安全 transformer（优先于 encode/decode）。
    ///   - metrics: 外部注入指标（不传则内部创建）。
    public init(configuration: CacheConfiguration, encode: ((Value) throws -> Data)? = nil, decode: ((Data) throws -> Value)? = nil, transformer: AnyTransformer<Value>? = nil, metrics: YCMetrics? = nil) {
        self.configuration = configuration
        self.memory = MemoryCache<Value>(config: configuration.memory)
        self.encode = encode
        self.decode = decode
        self.transformer = transformer
        self.metrics = metrics ?? YCMetrics()
        self.loggingEnabled = configuration.loggingEnabled
        self.metricsEnabled = configuration.metricsEnabled
        if configuration.disk.isEnabled {
            self.disk = DiskStorage(configuration: configuration, metrics: self.metrics, loggingEnabled: loggingEnabled, metricsEnabled: metricsEnabled)
        } else {
            self.disk = nil
        }
    }

    // MARK: - Public API (async)

    /// 获取指定 key 的值（内存→磁盘读穿），不存在返回 nil。
    public func value(forKey key: String) async throws -> Value? {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let encodedKey = configuration.keyEncoder(key)
        if let v = await memory.value(forKey: encodedKey) {
            await metrics.recordMemoryHit()
            let dt = DispatchTime.now().uptimeNanoseconds - t0
            await metrics.recordGetLatency(ns: dt)
            if loggingEnabled { debugLog("Memory hit key=\(key)", category: "Cache") }
            return v
        }
        await metrics.recordMemoryMiss()
        if let disk {
            do {
                let fetched = try await pending.getOrStart(forKey: encodedKey) { [decode, transformer, memory, metrics, loggingEnabled] in
                    guard let data = await disk.data(forKey: encodedKey) else { return nil }
                    let value: Value
                    if let decode {
                        value = try decode(data)
                    } else if let transformer {
                        value = try transformer.decode(data)
                    } else {
                        throw CacheError.decoding
                    }
                    await memory.set(value, forKey: encodedKey)
                    await metrics.recordDiskHit()
                    if loggingEnabled { debugLog("Disk hit key=\(key) bytes=\(data.count)", category: "Cache") }
                    return value
                }
                if let fetched {
                    let dt = DispatchTime.now().uptimeNanoseconds - t0
                    await metrics.recordGetLatency(ns: dt)
                    return fetched
                }
            } catch {
                if loggingEnabled { errorLog("Decode failed key=\(key)", category: "Cache") }
                throw CacheError.decoding
            }
        }
        await metrics.recordDiskMiss()
        let dt = DispatchTime.now().uptimeNanoseconds - t0
        await metrics.recordGetLatency(ns: dt)
        if loggingEnabled { debugLog("Miss key=\(key)", category: "Cache") }
        return nil
    }

    /// 设置指定 key 的值（写穿内存→磁盘）。
    /// - parameters:
    ///   - cost: 影响内存修剪的“代价”。
    ///   - ttl: 逐项过期时间（秒）；不传则不过期。
    public func set(_ value: Value, forKey key: String, cost: Int = 0, ttl: TimeInterval? = nil) async throws {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let encodedKey = configuration.keyEncoder(key)
        await memory.set(value, forKey: encodedKey, cost: cost, ttl: ttl)
        if let disk {
            let data: Data
            do {
                if let encode {
                    data = try encode(value)
                } else if let transformer {
                    data = try transformer.encode(value)
                } else {
                    throw CacheError.encoding
                }
            } catch { throw CacheError.encoding }
            let payload = WritePayload(data: data, ttl: ttl)
            await writer.submit(key: encodedKey, payload: payload) { [weak disk] key, payload in
                guard let disk else { return }
                try? await disk.setData(payload.data, forKey: key, ttl: payload.ttl)
            }
        }
        let dt = DispatchTime.now().uptimeNanoseconds - t0
        await metrics.recordSetLatency(ns: dt)
        if loggingEnabled { debugLog("Set key=\(key) ttl=\(ttl ?? -1)", category: "Cache") }
    }

    /// 移除指定 key 的值（内存与磁盘）。
    public func removeValue(forKey key: String) async {
        let encodedKey = configuration.keyEncoder(key)
        await memory.removeValue(forKey: encodedKey)
        if let disk {
            await disk.removeData(forKey: encodedKey)
        }
    }

    /// 清空所有缓存。
    public func removeAll(keepingCapacity: Bool = false) async {
        await memory.removeAll(keepingCapacity: keepingCapacity)
        if let disk { await disk.removeAll() }
    }

    /// 是否包含指定 key（内存先查，磁盘次之）。
    public func contains(_ key: String) async -> Bool {
        let encodedKey = configuration.keyEncoder(key)
        if await memory.contains(encodedKey) { return true }
        if let disk, await disk.data(forKey: encodedKey) != nil { return true }
        return false
    }
}

// MARK: - Factories

/// Data 缓存（零拷贝 transformer）。
public func makeDataCache(configuration: CacheConfiguration) -> Cache<Data> {
    Cache<Data>(configuration: configuration, transformer: AnyTransformer(RawDataTransform()))
}

/// Codable 缓存（默认 JSON 编解码）。
public func makeCodableCache<T: Codable>(configuration: CacheConfiguration, encoder: JSONEncoder = JSONEncoder(), decoder: JSONDecoder = JSONDecoder()) -> Cache<T> {
    Cache<T>(configuration: configuration, transformer: AnyTransformer(CodableTransform<T>(encoder: encoder, decoder: decoder)))
}

// NSCoding / NSSecureCoding 便捷构造
/// NSCoding 缓存（非安全编码，向后兼容）。
public func makeNSCodingCache<T: NSObject & NSCoding>(configuration: CacheConfiguration) -> Cache<T> {
    Cache<T>(configuration: configuration, transformer: AnyTransformer(NSCodingTransform<T>()))
}

/// NSSecureCoding 缓存（推荐）。
public func makeNSSecureCodingCache<T: NSObject & NSSecureCoding>(configuration: CacheConfiguration, requiresSecureCoding: Bool = true) -> Cache<T> {
    Cache<T>(configuration: configuration, transformer: AnyTransformer(NSSecureCodingTransform<T>(requiresSecureCoding: requiresSecureCoding)))
}
