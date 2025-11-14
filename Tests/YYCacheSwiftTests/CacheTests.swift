import XCTest
@testable import YYCacheSwift

final class CacheTests: XCTestCase {
    func testSetGetMemoryOnly() async throws {
        let cfg = CacheConfiguration.default(name: "test")
        let cache = Cache<Int>(configuration: cfg)

        try await cache.set(42, forKey: "answer")
        let v = try await cache.value(forKey: "answer")
        XCTAssertEqual(v, 42)
        let contained = await cache.contains("answer")
        XCTAssertTrue(contained)
    }

    func testDiskDataReadWrite() async throws {
        var cfg = CacheConfiguration.default(name: "disk_test")
        cfg.disk.isEnabled = true
        cfg.disk.inlineThreshold = 8 // force small values inline
        let cache = makeDataCache(configuration: cfg)

        let key = "greeting"
        let data = Data("hello".utf8)
        try await cache.set(data, forKey: key)

        // 通过新建实例模拟内存未命中，但磁盘存在
        let cache2 = makeDataCache(configuration: cfg)
        let read = try await cache2.value(forKey: key)
        XCTAssertEqual(read, data)
        let contained2 = await cache2.contains(key)
        XCTAssertTrue(contained2)
    }

    func testDiskTTLExpiry() async throws {
        var cfg = CacheConfiguration.default(name: "disk_ttl")
        cfg.disk.isEnabled = true
        cfg.disk.inlineThreshold = 8
        let cache = makeDataCache(configuration: cfg)

        let key = "shortTTL"
        let data = Data([1,2,3])
        try await cache.set(data, forKey: key, ttl: 0.2)

        // 立即可读
        let immediate = try await cache.value(forKey: key)
        XCTAssertEqual(immediate, data)

        // 等待过期
        try? await Task.sleep(nanoseconds: 300_000_000)

        // 通过新实例触发磁盘端过期清理
        let cache2 = makeDataCache(configuration: cfg)
        let v = try await cache2.value(forKey: key)
        XCTAssertNil(v)
    }

    func testMetricsBasic() async throws {
        var cfg = CacheConfiguration.default(name: "metrics_test")
        cfg.disk.isEnabled = true
        let cache = makeDataCache(configuration: cfg)

        // 初始 snapshot
        var snap = await cache.metrics.snapshot()
        XCTAssertEqual(snap.memoryHits, 0)

        // 内存写读
        try await cache.set(Data([1]), forKey: "k1")
        _ = try await cache.value(forKey: "k1")
        snap = await cache.metrics.snapshot()
        XCTAssertGreaterThanOrEqual(snap.memoryHits, 1)

        // 触发磁盘读（通过新实例）
        let cache2 = makeDataCache(configuration: cfg)
        _ = try await cache2.value(forKey: "k1")
        let snap2 = await cache2.metrics.snapshot()
        XCTAssertGreaterThanOrEqual(snap2.diskHits, 1)
    }

    func testDeduplicateConcurrentDiskGets() async throws {
        var cfg = CacheConfiguration.default(name: "dedup_disk")
        cfg.disk.isEnabled = true
        cfg.disk.inlineThreshold = 8
        let cacheW = makeDataCache(configuration: cfg)
        try await cacheW.set(Data("hello".utf8), forKey: "dupe")

        let cache = makeDataCache(configuration: cfg)
        // 并发多次读取，期望磁盘只读一次（metrics.readsBytes == 5）
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    _ = try? await cache.value(forKey: "dupe")
                }
            }
        }
        let snap = await cache.metrics.snapshot()
        XCTAssertEqual(snap.readsBytes, 5)
        // 之后再次读取应当为内存命中
        _ = try await cache.value(forKey: "dupe")
        let snap2 = await cache.metrics.snapshot()
        XCTAssertGreaterThanOrEqual(snap2.memoryHits, 1)
    }

    func testCoalesceConcurrentSets() async throws {
        var cfg = CacheConfiguration.default(name: "coalesce_sets")
        cfg.disk.isEnabled = true
        cfg.disk.inlineThreshold = 8
        let cache = makeDataCache(configuration: cfg)

        // 并发多次写入同一 key，期望只写入最后一次
        let key = "k"
        await withTaskGroup(of: Void.self) { group in
            for i in 1...20 {
                group.addTask {
                    let data = Data(repeating: UInt8(i), count: i * 10)
                    try? await cache.set(data, forKey: key)
                }
            }
        }
        // 再追加一次明确的最终写入，验证只落一次磁盘
        let base = await cache.metrics.snapshot()
        let final = Data(repeating: 0xEE, count: 123)
        try await cache.set(final, forKey: key)
        try? await Task.sleep(nanoseconds: 200_000_000)
        let snap2 = await cache.metrics.snapshot()
        let delta = snap2.writesBytes - base.writesBytes
        XCTAssertGreaterThanOrEqual(delta, 123)
        XCTAssertLessThanOrEqual(delta, 246) // 最多两次写入（若恰逢有挂起写）
        let v = try await cache.value(forKey: key)
        XCTAssertEqual(v, final)
    }

    func testDiskTrimByCountLRU() async throws {
        var cfg = CacheConfiguration.default(name: "disk_trim_count")
        cfg.disk.isEnabled = true
        cfg.disk.countLimit = 2
        cfg.disk.inlineThreshold = 8
        let cache = makeDataCache(configuration: cfg)

        try await cache.set(Data([1]), forKey: "k1")
        try await cache.set(Data([2]), forKey: "k2")
        try await cache.set(Data([3]), forKey: "k3")

        // 通过新实例判断磁盘状态，期望 k1 被淘汰
        let cache2 = makeDataCache(configuration: cfg)
        let c1 = await cache2.contains("k1")
        let c2 = await cache2.contains("k2")
        let c3 = await cache2.contains("k3")
        XCTAssertFalse(c1)
        XCTAssertTrue(c2)
        XCTAssertTrue(c3)
    }

    func testDiskTrimBySizeLRU() async throws {
        var cfg = CacheConfiguration.default(name: "disk_trim_size")
        cfg.disk.isEnabled = true
        cfg.disk.byteLimit = 1500
        cfg.disk.inlineThreshold = 2000 // 强制文件或内联均可，这里不依赖文件存在与否
        let cache = makeDataCache(configuration: cfg)

        try await cache.set(Data(repeating: 0xAA, count: 1000), forKey: "a")
        try await cache.set(Data(repeating: 0xBB, count: 1000), forKey: "b")
        try await cache.set(Data(repeating: 0xCC, count: 1000), forKey: "c")

        // 通过新实例判断，期望 a、b 淘汰，仅 c 保留
        let cache2 = makeDataCache(configuration: cfg)
        let ca = await cache2.contains("a")
        let cb = await cache2.contains("b")
        let cc = await cache2.contains("c")
        XCTAssertFalse(ca)
        XCTAssertFalse(cb)
        XCTAssertTrue(cc)
    }

    func testMemoryTrimByCount() async throws {
        var cfg = CacheConfiguration.default(name: "mem_trim_count")
        cfg.memory.countLimit = 2
        let cache = Cache<Int>(configuration: cfg)

        try await cache.set(1, forKey: "m1")
        try await cache.set(2, forKey: "m2")
        try await cache.set(3, forKey: "m3")

        let m1 = await cache.contains("m1")
        let m2 = await cache.contains("m2")
        let m3 = await cache.contains("m3")
        XCTAssertFalse(m1)
        XCTAssertTrue(m2)
        XCTAssertTrue(m3)
    }

    func testStorageModeSqliteForcesInline() async throws {
        var cfg = CacheConfiguration.default(name: "disk_sqlite")
        cfg.disk.isEnabled = true
        cfg.disk.storageMode = .sqlite
        cfg.disk.inlineThreshold = 0
        let cache = makeDataCache(configuration: cfg)

        let key = "big"
        let data = Data(repeating: 0xAB, count: 100_000) // 100KB
        try await cache.set(data, forKey: key)

        // 读取验证
        let v1 = try await cache.value(forKey: key)
        XCTAssertEqual(v1, data)

        // 断言无文件落地
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let base = caches.appendingPathComponent("YYCacheSwift/\(cfg.name)/data", isDirectory: true)
        let encodedKey = cfg.keyEncoder(key)
        let filename = sha256Hex(encodedKey)
        let fileURL = base.appendingPathComponent(filename)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testStorageModeFileForcesFile() async throws {
        var cfg = CacheConfiguration.default(name: "disk_file")
        cfg.disk.isEnabled = true
        cfg.disk.storageMode = .file
        cfg.disk.inlineThreshold = 1024 * 1024
        let cache = makeDataCache(configuration: cfg)

        let key = "small"
        let data = Data([9,8,7])
        try await cache.set(data, forKey: key)

        // 读取验证
        let v2 = try await cache.value(forKey: key)
        XCTAssertEqual(v2, data)

        // 断言有文件落地
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let base = caches.appendingPathComponent("YYCacheSwift/\(cfg.name)/data", isDirectory: true)
        let encodedKey = cfg.keyEncoder(key)
        let filename = sha256Hex(encodedKey)
        let fileURL = base.appendingPathComponent(filename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    // MARK: - NSCoding / NSSecureCoding

    @objc(CachePerson)
    final class Person: NSObject, NSSecureCoding { // 测试用对象
        static var supportsSecureCoding: Bool = true
        let name: String
        let age: Int
        init(name: String, age: Int) { self.name = name; self.age = age }
        required convenience init?(coder: NSCoder) {
            guard let name = coder.decodeObject(of: NSString.self, forKey: "name") as String? else { return nil }
            let age = coder.decodeInteger(forKey: "age")
            self.init(name: name, age: age)
        }
        func encode(with coder: NSCoder) {
            coder.encode(name as NSString, forKey: "name")
            coder.encode(age, forKey: "age")
        }
        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? Person else { return false }
            return name == other.name && age == other.age
        }
    }

    func testNSSecureCodingDiskRoundTrip() async throws {
        var cfg = CacheConfiguration.default(name: "securecoding")
        cfg.disk.isEnabled = true
        cfg.disk.inlineThreshold = 8
        let cache = makeNSSecureCodingCache(configuration: cfg) as Cache<Person>

        let p = Person(name: "Alice", age: 30)
        try await cache.set(p, forKey: "p1")

        // 通过新实例触发磁盘读取
        let cache2 = makeNSSecureCodingCache(configuration: cfg) as Cache<Person>
        let read = try await cache2.value(forKey: "p1")
        XCTAssertEqual(read, p)
    }
}
