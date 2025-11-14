import Foundation

actor MemoryCache<Value: Sendable> {
    struct Config: Sendable {
        var countLimit: Int
        var costLimit: Int
        var ageLimit: TimeInterval
        var autoTrimInterval: TimeInterval
        var releaseAsynchronously: Bool
        var releaseOnMainThread: Bool
    }

    private final class Node {
        let key: String
        var value: Value
        var cost: Int
        var expiresAt: TimeInterval? // epoch seconds
        var lastAccess: TimeInterval
        var prev: Node?
        var next: Node?

        init(key: String, value: Value, cost: Int, expiresAt: TimeInterval?, lastAccess: TimeInterval) {
            self.key = key
            self.value = value
            self.cost = cost
            self.expiresAt = expiresAt
            self.lastAccess = lastAccess
        }
    }

    private var dict: [String: Node] = [:]
    private var head: Node?
    private var tail: Node?
    private var totalCost: Int = 0
    private var config: Config
    private var trimTask: Task<Void, Never>?

    init(config: CacheConfiguration.Memory) {
        self.config = Config(
            countLimit: config.countLimit,
            costLimit: config.costLimit,
            ageLimit: config.ageLimit,
            autoTrimInterval: config.autoTrimInterval,
            releaseAsynchronously: config.releaseAsynchronously,
            releaseOnMainThread: config.releaseOnMainThread
        )

        if config.autoTrimInterval > 0 {
            // 在 actor 初始化阶段不能直接调用 actor 隔离的方法，这里异步启动
            Task { [weak self] in
                await self?.scheduleAutoTrim()
            }
        }
    }

    deinit {
        trimTask?.cancel()
    }

    func value(forKey key: String) -> Value? {
        guard let node = dict[key] else { return nil }
        if let exp = node.expiresAt, exp <= now() {
            remove(node)
            dict[key] = nil
            return nil
        }
        node.lastAccess = now()
        moveToHead(node)
        return node.value
    }

    func contains(_ key: String) -> Bool {
        if let node = dict[key] {
            if let exp = node.expiresAt, exp <= now() {
                remove(node)
                dict[key] = nil
                return false
            }
            return true
        }
        return false
    }

    func set(_ value: Value, forKey key: String, cost: Int = 0, ttl: TimeInterval? = nil) {
        let current = now()
        let expiresAt = ttl.flatMap { current + $0 }
        if let node = dict[key] {
            totalCost -= node.cost
            node.value = value
            node.cost = cost
            node.expiresAt = expiresAt
            node.lastAccess = current
            totalCost += cost
            moveToHead(node)
        } else {
            let node = Node(key: key, value: value, cost: cost, expiresAt: expiresAt, lastAccess: current)
            dict[key] = node
            insertAtHead(node)
            totalCost += cost
        }
        trimIfNeeded()
    }

    func removeValue(forKey key: String) {
        guard let node = dict[key] else { return }
        remove(node)
        dict[key] = nil
        totalCost -= node.cost
    }

    func removeAll(keepingCapacity: Bool) {
        dict.removeAll(keepingCapacity: keepingCapacity)
        head = nil
        tail = nil
        totalCost = 0
    }

    // MARK: - LRU helpers

    private func insertAtHead(_ node: Node) {
        node.prev = nil
        node.next = head
        head?.prev = node
        head = node
        if tail == nil { tail = node }
    }

    private func moveToHead(_ node: Node) {
        guard head !== node else { return }
        // detach
        if let p = node.prev { p.next = node.next }
        if let n = node.next { n.prev = node.prev }
        if tail === node { tail = node.prev }
        // move to head
        node.prev = nil
        node.next = head
        head?.prev = node
        head = node
        if tail == nil { tail = node }
    }

    private func remove(_ node: Node) {
        if let p = node.prev { p.next = node.next }
        if let n = node.next { n.prev = node.prev }
        if head === node { head = node.next }
        if tail === node { tail = node.prev }
        node.prev = nil
        node.next = nil
    }

    private func popTail() -> Node? {
        guard let t = tail else { return nil }
        remove(t)
        return t
    }

    // MARK: - Trimming

    private func trimIfNeeded() {
        trimToAge(config.ageLimit)
        trimToCount(config.countLimit)
        trimToCost(config.costLimit)
    }

    private func scheduleAutoTrim() {
        trimTask = Task { [weak self] in
            await self?.runAutoTrimLoop()
        }
    }

    private func runAutoTrimLoop() async {
        let interval = config.autoTrimInterval
        guard interval > 0 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            trimToAge(config.ageLimit)
            trimToCount(config.countLimit)
            trimToCost(config.costLimit)
        }
    }

    private func trimToAge(_ ageLimit: TimeInterval) {
        guard ageLimit.isFinite else { return }
        let cutoff = now() - ageLimit
        var node = tail
        while let n = node {
            // TTL expiration takes precedence
            if let exp = n.expiresAt, exp <= now() {
                totalCost -= n.cost
                dict[n.key] = nil
                remove(n)
                node = tail
                continue
            }
            if n.lastAccess <= cutoff {
                totalCost -= n.cost
                dict[n.key] = nil
                remove(n)
                node = tail
                continue
            }
            break
        }
    }

    private func trimToCount(_ countLimit: Int) {
        guard countLimit >= 0 else { return }
        while dict.count > countLimit, let node = popTail() {
            dict[node.key] = nil
            totalCost -= node.cost
        }
    }

    private func trimToCost(_ costLimit: Int) {
        guard costLimit >= 0 else { return }
        while totalCost > costLimit, let node = popTail() {
            dict[node.key] = nil
            totalCost -= node.cost
        }
    }

    // MARK: - Utils

    private func now() -> TimeInterval { CFAbsoluteTimeGetCurrent() }
}
