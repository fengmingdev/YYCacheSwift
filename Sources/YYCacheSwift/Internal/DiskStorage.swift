import Foundation
import SQLite3

// SQLite helper for transient destructor
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

protocol DiskStorageProtocol {}

actor DiskStorage: DiskStorageProtocol {
    private let baseURL: URL
    private let dataURL: URL
    private let dbURL: URL
    private let fileManager: FileManager = .default
    private let keyToFilename: (String) -> String

    private var db: OpaquePointer?

    // Limits
    private let byteLimit: Int
    private let countLimit: Int
    private let ageLimit: TimeInterval
    private let inlineThreshold: Int
    private let autoTrimInterval: TimeInterval
    private let storageMode: CacheConfiguration.Disk.StorageMode
    private var trimTask: Task<Void, Never>?
    private let metrics: YCMetrics?
    private let loggingEnabled: Bool
    private let metricsEnabled: Bool

    init(configuration: CacheConfiguration, metrics: YCMetrics?, loggingEnabled: Bool, metricsEnabled: Bool) {
        let dir: URL
        if let custom = configuration.directoryURL {
            dir = custom
        } else {
            let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            dir = caches.appendingPathComponent("YYCacheSwift", isDirectory: true)
        }
        let base = dir.appendingPathComponent(configuration.name, isDirectory: true)
        self.baseURL = base
        self.dataURL = base.appendingPathComponent("data", isDirectory: true)
        self.dbURL = base.appendingPathComponent("manifest.sqlite3")
        self.keyToFilename = { key in sha256Hex(key) }

        self.byteLimit = configuration.disk.byteLimit
        self.countLimit = configuration.disk.countLimit
        self.ageLimit = configuration.disk.ageLimit
        self.inlineThreshold = configuration.disk.inlineThreshold
        self.autoTrimInterval = configuration.disk.autoTrimInterval
        self.storageMode = configuration.disk.storageMode
        self.metrics = metrics
        self.loggingEnabled = loggingEnabled
        self.metricsEnabled = metricsEnabled

        try? fileManager.createDirectory(at: self.dataURL, withIntermediateDirectories: true, attributes: nil)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var baseCopy = self.baseURL
        try? baseCopy.setResourceValues(resourceValues)

        // 数据库初始化与定时修剪在 actor 初始化后异步启动
        Task { [weak self] in
            await self?.initialize()
        }
    }

    deinit {
        trimTask?.cancel()
        if let db { sqlite3_close(db) }
    }

    // MARK: - Lifecycle

    private func initialize() {
        openDatabase()
        createSchemaIfNeeded()
        migrateSchemaIfNeeded()
        applyPragma()
        if autoTrimInterval > 0 { scheduleAutoTrim() }
    }

    private func ensureInitialized() {
        if db == nil {
            openDatabase()
            createSchemaIfNeeded()
            migrateSchemaIfNeeded()
            applyPragma()
            if autoTrimInterval > 0 && trimTask == nil { scheduleAutoTrim() }
        }
    }

    // MARK: - Public API

    func data(forKey key: String) -> Data? {
        ensureInitialized()
        guard let db else { return nil }
        let q = "SELECT inline_value, filename, expire_at FROM manifest WHERE key = ?1 LIMIT 1;"
        var stmt: OpaquePointer?
        defer { if stmt != nil { sqlite3_finalize(stmt) } }
        guard sqlite3_prepare_v2(db, q, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) == SQLITE_ROW {
            let expire = sqlite3_column_double(stmt, 2)
            let hasExpire = sqlite3_column_type(stmt, 2) != SQLITE_NULL
            let now = CFAbsoluteTimeGetCurrent()
            if hasExpire && expire <= now {
                sqlite3_finalize(stmt); stmt = nil
                // expired: cleanup and return nil
                removeData(forKey: key)
                return nil
            }
            if let blob = sqlite3_column_blob(stmt, 0) {
                let size = Int(sqlite3_column_bytes(stmt, 0))
                let data = Data(bytes: blob, count: size)
                sqlite3_finalize(stmt); stmt = nil
                updateAccessTime(forKey: key)
                if metricsEnabled { Task { await metrics?.recordRead(bytes: Int64(size)) } }
                return data
            } else if let cstr = sqlite3_column_text(stmt, 1) {
                let filename = String(cString: cstr)
                sqlite3_finalize(stmt); stmt = nil
                let url = dataURL.appendingPathComponent(filename)
                let data = try? Data(contentsOf: url, options: [.mappedIfSafe])
                updateAccessTime(forKey: key)
                if metricsEnabled, let data { Task { await metrics?.recordRead(bytes: Int64(data.count)) } }
                return data
            }
        }
        return nil
    }

    func setData(_ data: Data, forKey key: String, ttl: TimeInterval?) throws {
        ensureInitialized()
        guard let db else { throw CacheError.io }
        let now = CFAbsoluteTimeGetCurrent()
        let expireAt: Double? = ttl.map { now + $0 }
        let forceInline = storageMode == .sqlite
        let forceFile = storageMode == .file
        let shouldInline = forceInline || (!forceFile && data.count <= inlineThreshold)
        if shouldInline {
            // inline into sqlite
            let q = "REPLACE INTO manifest (key, filename, size, last_access_time, last_modified_time, extended, inline_value, expire_at) VALUES (?1, NULL, ?2, ?3, ?3, NULL, ?4, ?5);"
            var stmt: OpaquePointer?
            defer { if stmt != nil { sqlite3_finalize(stmt) } }
            guard sqlite3_prepare_v2(db, q, -1, &stmt, nil) == SQLITE_OK else { throw CacheError.sqlite }
            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, sqlite3_int64(data.count))
            sqlite3_bind_double(stmt, 3, now)
            data.withUnsafeBytes { ptr in
                if let base = ptr.baseAddress, ptr.count > 0 {
                    sqlite3_bind_blob(stmt, 4, base, Int32(ptr.count), SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 4)
                }
            }
            if let expireAt { sqlite3_bind_double(stmt, 5, expireAt) } else { sqlite3_bind_null(stmt, 5) }
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw CacheError.sqlite }
        } else {
            // write to file + update manifest
            let filename = keyToFilename(key)
            let url = dataURL.appendingPathComponent(filename)
            let tmp = dataURL.appendingPathComponent(UUID().uuidString)
            try data.write(to: tmp, options: .atomic)
            if fileManager.fileExists(atPath: url.path) { try? fileManager.removeItem(at: url) }
            try fileManager.moveItem(at: tmp, to: url)

            let q = "REPLACE INTO manifest (key, filename, size, last_access_time, last_modified_time, extended, inline_value, expire_at) VALUES (?1, ?2, ?3, ?4, ?4, NULL, NULL, ?5);"
            var stmt: OpaquePointer?
            defer { if stmt != nil { sqlite3_finalize(stmt) } }
            guard sqlite3_prepare_v2(db, q, -1, &stmt, nil) == SQLITE_OK else { throw CacheError.sqlite }
            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, filename, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 3, sqlite3_int64(data.count))
            sqlite3_bind_double(stmt, 4, now)
            if let expireAt { sqlite3_bind_double(stmt, 5, expireAt) } else { sqlite3_bind_null(stmt, 5) }
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw CacheError.sqlite }
        }
        if metricsEnabled { Task { await metrics?.recordWrite(bytes: Int64(data.count)) } }
        try trimIfNeeded()
    }

    func removeData(forKey key: String) {
        ensureInitialized()
        guard let db else { return }
        // find filename first
        if let filename = filenameForKey(key) {
            let url = dataURL.appendingPathComponent(filename)
            try? fileManager.removeItem(at: url)
        }
        let q = "DELETE FROM manifest WHERE key = ?1;"
        var stmt: OpaquePointer?
        defer { if stmt != nil { sqlite3_finalize(stmt) } }
        if sqlite3_prepare_v2(db, q, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
            _ = sqlite3_step(stmt)
        }
    }

    func removeAll() {
        ensureInitialized()
        guard let db else { return }
        _ = exec("DELETE FROM manifest;")
        try? fileManager.removeItem(at: dataURL)
        try? fileManager.createDirectory(at: dataURL, withIntermediateDirectories: true, attributes: nil)
        _ = exec("VACUUM;")
    }

    // MARK: - Trimming

    private func trimIfNeeded() throws {
        try trimExpired()
        try trimToAge(ageLimit)
        try trimToCount(countLimit)
        try trimToSize(byteLimit)
    }

    private func scheduleAutoTrim() {
        trimTask = Task { [weak self] in
            await self?.runTrimLoop()
        }
        if loggingEnabled { infoLog("Disk auto-trim scheduled interval=\(autoTrimInterval)s", category: "Disk") }
    }

    private func runTrimLoop() async {
        let interval = autoTrimInterval
        guard interval > 0 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            try? trimToAge(ageLimit)
            try? trimToCount(countLimit)
            try? trimToSize(byteLimit)
        }
    }

    private func trimToAge(_ age: TimeInterval) throws {
        guard age.isFinite, let db else { return }
        let cutoff = CFAbsoluteTimeGetCurrent() - age
        let select = "SELECT key, filename, size FROM manifest WHERE last_access_time <= ?1 ORDER BY last_access_time ASC LIMIT 256;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, select, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, cutoff)
        var keys: [String] = []
        var files: [String] = []
        var bytes: Int64 = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let k = sqlite3_column_text(stmt, 0) { keys.append(String(cString: k)) }
            if let f = sqlite3_column_text(stmt, 1) { files.append(String(cString: f)) }
            bytes &+= sqlite3_column_int64(stmt, 2)
        }
        deleteFiles(files)
        if !keys.isEmpty { deleteKeys(keys) }
        if !keys.isEmpty { Task { await metrics?.recordTrim(count: keys.count, bytes: bytes) } }
    }

    private func trimExpired() throws {
        guard let db else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let select = "SELECT key, filename FROM manifest WHERE expire_at IS NOT NULL AND expire_at <= ?1 LIMIT 512;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, select, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, now)
        var keys: [String] = []
        var files: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let k = sqlite3_column_text(stmt, 0) { keys.append(String(cString: k)) }
            if let f = sqlite3_column_text(stmt, 1), sqlite3_column_type(stmt, 1) != SQLITE_NULL {
                files.append(String(cString: f))
            }
        }
        deleteFiles(files)
        if !keys.isEmpty { deleteKeys(keys) }
        if !keys.isEmpty { Task { await metrics?.recordTrim(count: keys.count, bytes: 0) } }
    }

    private func trimToCount(_ limit: Int) throws {
        guard limit >= 0, let db else { return }
        let count = intForQuery("SELECT COUNT(*) FROM manifest;")
        guard count > limit else { return }
        let toRemove = count - limit
        let select = "SELECT key, filename, size FROM manifest ORDER BY last_access_time ASC LIMIT ?1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, select, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(toRemove))
        var keys: [String] = []
        var files: [String] = []
        var bytes: Int64 = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let k = sqlite3_column_text(stmt, 0) { keys.append(String(cString: k)) }
            if let f = sqlite3_column_text(stmt, 1) { files.append(String(cString: f)) }
            bytes &+= sqlite3_column_int64(stmt, 2)
        }
        deleteFiles(files)
        if !keys.isEmpty { deleteKeys(keys) }
        if !keys.isEmpty { Task { await metrics?.recordTrim(count: keys.count, bytes: bytes) } }
    }

    private func trimToSize(_ limit: Int) throws {
        guard limit >= 0, let db else { return }
        let total = int64ForQuery("SELECT IFNULL(SUM(size),0) FROM manifest;")
        guard total > limit else { return }
        var need = total - Int64(limit)
        let select = "SELECT key, filename, size FROM manifest ORDER BY last_access_time ASC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, select, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        var keys: [String] = []
        var files: [String] = []
        var totalBytes: Int64 = 0
        while need > 0, sqlite3_step(stmt) == SQLITE_ROW {
            if let k = sqlite3_column_text(stmt, 0) { keys.append(String(cString: k)) }
            if let f = sqlite3_column_text(stmt, 1) { files.append(String(cString: f)) }
            let sz = sqlite3_int64(sqlite3_column_int64(stmt, 2))
            totalBytes &+= sz
            need -= sz
        }
        deleteFiles(files)
        if !keys.isEmpty { deleteKeys(keys) }
        if !keys.isEmpty { Task { await metrics?.recordTrim(count: keys.count, bytes: totalBytes) } }
    }

    // MARK: - Helpers

    private func filenameForKey(_ key: String) -> String? {
        guard let db else { return nil }
        let q = "SELECT filename FROM manifest WHERE key = ?1 LIMIT 1;"
        var stmt: OpaquePointer?
        defer { if stmt != nil { sqlite3_finalize(stmt) } }
        guard sqlite3_prepare_v2(db, q, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) {
            return String(cString: c)
        }
        return nil
    }

    private func deleteKeys(_ keys: [String]) {
        guard let db, !keys.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ",")
        let q = "DELETE FROM manifest WHERE key IN (\(placeholders));"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, q, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        for (i, k) in keys.enumerated() {
            sqlite3_bind_text(stmt, Int32(i+1), k, -1, SQLITE_TRANSIENT)
        }
        _ = sqlite3_step(stmt)
    }

    private func deleteFiles(_ files: [String]) {
        guard !files.isEmpty else { return }
        for f in files { try? fileManager.removeItem(at: dataURL.appendingPathComponent(f)) }
    }

    private func updateAccessTime(forKey key: String) {
        guard let db else { return }
        let q = "UPDATE manifest SET last_access_time = ?1 WHERE key = ?2;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, q, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, CFAbsoluteTimeGetCurrent())
        sqlite3_bind_text(stmt, 2, key, -1, SQLITE_TRANSIENT)
        _ = sqlite3_step(stmt)
    }

    // MARK: - SQLite basics

    private func openDatabase() {
        var handle: OpaquePointer?
        if sqlite3_open(dbURL.path, &handle) == SQLITE_OK {
            db = handle
            if loggingEnabled { debugLog("SQLite opened: \(dbURL.path)", category: "Disk") }
        } else {
            db = nil
            if loggingEnabled { errorLog("SQLite open failed at: \(dbURL.path)") }
        }
    }

    private func applyPragma() {
        _ = exec("PRAGMA journal_mode=WAL;")
        _ = exec("PRAGMA synchronous=NORMAL;")
        _ = exec("PRAGMA wal_autocheckpoint=1000;")
        if loggingEnabled { debugLog("SQLite PRAGMA applied", category: "Disk") }
    }

    private func createSchemaIfNeeded() {
        let sql = """
        CREATE TABLE IF NOT EXISTS manifest (
            key TEXT PRIMARY KEY,
            filename TEXT,
            size INTEGER,
            last_access_time REAL,
            last_modified_time REAL,
            extended BLOB,
            inline_value BLOB,
            expire_at REAL
        );
        CREATE INDEX IF NOT EXISTS idx_manifest_atime ON manifest(last_access_time);
        """
        _ = exec(sql)
    }

    private func migrateSchemaIfNeeded() {
        guard let db else { return }
        // Ensure 'expire_at' column exists
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA table_info(manifest);", -1, &stmt, nil) == SQLITE_OK {
            var hasExpire = false
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cname = sqlite3_column_text(stmt, 1) {
                    let name = String(cString: cname)
                    if name == "expire_at" { hasExpire = true; break }
                }
            }
            sqlite3_finalize(stmt); stmt = nil
            if !hasExpire {
                _ = exec("ALTER TABLE manifest ADD COLUMN expire_at REAL;")
            }
        }
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let db else { return false }
        var err: UnsafeMutablePointer<Int8>? = nil
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            if let e = err { sqlite3_free(e) }
            errorLog("SQLite exec failed: \(sql)", category: "Disk")
            return false
        }
        return true
    }

    private func intForQuery(_ sql: String) -> Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        defer { if stmt != nil { sqlite3_finalize(stmt) } }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        var result = 0
        if sqlite3_step(stmt) == SQLITE_ROW {
            result = Int(sqlite3_column_int64(stmt, 0))
        }
        return result
    }

    private func int64ForQuery(_ sql: String) -> Int64 {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        defer { if stmt != nil { sqlite3_finalize(stmt) } }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        var result: Int64 = 0
        if sqlite3_step(stmt) == SQLITE_ROW {
            result = sqlite3_column_int64(stmt, 0)
        }
        return result
    }
}
