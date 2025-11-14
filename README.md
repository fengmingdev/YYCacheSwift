YYCacheSwift
============

现代化的 Swift 分层缓存（iOS 13+）：内存 LRU + 磁盘（SQLite 混合存储），原生 async/await，类型安全 Transformer，可选 NSCoding/NSSecureCoding，带指标与日志。

特性
- 内存缓存：O(1) LRU，支持 count/cost/age 限制与自动修剪
- 磁盘缓存：SQLite manifest + 小对象内联，大对象落文件；按 age/count/size 修剪；逐项 TTL
- 并发：读去重（同 key 合并一次磁盘读）、写合并（同 key 防抖聚合）
- API：原生 async/await；Data/Codable/NSCoding/NSSecureCoding 均可用
- 观测：轻量指标（命中、I/O、修剪、时延）与可选日志
- 平台：iOS 13+/macOS 10.15+/tvOS 13+/watchOS 6+

安装（SPM）
在 Package.swift 中添加：

dependencies: [
  .package(url: "https://github.com/fengmingdev/YYCacheSwift.git", branch: "main")
]

快速上手
// Data 缓存
let cache = makeDataCache(configuration: .default(name: "images"))
try await cache.set(data, forKey: key, ttl: 3600)
let hit = try await cache.value(forKey: key)

// Codable 缓存
struct User: Codable { let id: String; let name: String }
let userCache = makeCodableCache(configuration: .default(name: "users"))
try await userCache.set(User(id: "1", name: "A"), forKey: "1")

// NSSecureCoding 缓存
final class Person: NSObject, NSSecureCoding { ... }
let personCache: Cache<Person> = makeNSSecureCodingCache(configuration: .default(name: "persons"))

配置
- 内存（CacheConfiguration.Memory）：countLimit / costLimit / ageLimit / autoTrimInterval
- 磁盘（CacheConfiguration.Disk）：isEnabled / byteLimit / countLimit / ageLimit / autoTrimInterval / inlineThreshold / storageMode(.mixed/.sqlite/.file)
- 其他：keyEncoder（默认直传，生产建议 SHA256）、loggingEnabled（默认 Debug 开启）、metricsEnabled

键编码示例（推荐 SHA256）：
import CryptoKit
var cfg = CacheConfiguration.default(name: "images")
cfg.keyEncoder = { key in
  let digest = SHA256.hash(data: Data(key.utf8))
  return digest.map { String(format: "%02x", $0) }.joined()
}

逐项 TTL 与修剪优先级
set(_:ttl:) 会同时影响内存与磁盘；磁盘端以 expire_at 列存储，每次读取会清除过期项，并在定时修剪中优先清理。
- 内存：TTL → ageLimit → count/cost
- 磁盘：TTL → ageLimit → count → size

观测与日志
let snap = await cache.metrics.snapshot()
// memoryHits/diskHits/readsBytes/writesBytes/trimsCount/trimsBytes/get/set 累计时延
// Debug 下默认输出调试日志至控制台与 Caches/YYCacheSwift/logs

并发
- 读去重：同 key 并发 value(forKey:) 只触发一次磁盘读
- 写合并：同 key 并发 set 防抖聚合，尽量只落最后一次；极端情况下最多两次

存储细节
- 目录：<Caches>/YYCacheSwift/<name>/
- manifest.sqlite3：key/filename/size/atime/mtime/extended/inline_value/expire_at
- 小对象（<= inlineThreshold）内联至 inline_value；大对象写入 data/ 下文件

注意事项
- NSCodingTransform 使用非安全解档，仅用于兼容旧对象；优先 NSSecureCodingTransform
- Logger 基于 YCLogger，可在 configuration.loggingEnabled 控制
- 指标为近似观测，聚合在 YCMetrics，抓取快照后自行计算均值/百分位
- CacheConfiguration.Memory 的 releaseAsynchronously/releaseOnMainThread 为兼容占位，当前实现不影响对象释放时机

许可
本项目遵循与原 YYCache 相同的开源精神，欢迎 PR 与 Issue！

