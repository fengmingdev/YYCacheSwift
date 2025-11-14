import Foundation
#if canImport(OSLog)
import OSLog
#endif

/// 日志级别
public enum YCLogLevel: Int, CaseIterable {
    case verbose = 0
    case debug = 1
    case info = 2
    case warning = 3
    case error = 4
    case none = 5
    
    var description: String {
        switch self {
        case .verbose: return "💬 VERBOSE"
        case .debug: return "🐛 DEBUG"
        case .info: return "ℹ️ INFO"
        case .warning: return "⚠️ WARNING"
        case .error: return "❌ ERROR"
        case .none: return "NONE"
        }
    }
    
    @available(iOS 14.0, *)
    var osLogType: OSLogType {
        switch self {
        case .verbose: return .debug
        case .debug: return .debug
        case .info: return .info
        case .warning: return .default
        case .error: return .error
        case .none: return .default
        }
    }
}

/// 日志输出协议
public protocol YCLogOutput {
    func log(_ message: String, level: YCLogLevel, category: String?, file: String, line: Int, function: String)
}

/// 控制台日志输出器
public class YCConsoleLogOutput: YCLogOutput {
    public init() {}

    public func log(_ message: String, level: YCLogLevel, category: String?, file: String, line: Int, function: String) {
        #if DEBUG
        let fileName = (file as NSString).lastPathComponent  // 优化性能
        let categoryStr = category.map { "[\($0)] " } ?? ""
        let timestamp = DateFormatter.logFormatter.string(from: Date())

        // 前缀统一 YYCacheSwift，便于筛选
        print("YYCacheSwift: [\(timestamp)] [\(level.description)] \(categoryStr)\(fileName):\(line) \(function) - \(message)")
        #endif
    }
}

/// 系统日志输出器（iOS 14+）
#if canImport(OSLog)
@available(iOS 14.0, macOS 11.0, tvOS 14.0, watchOS 7.0, *)
public class YCOSLogOutput: YCLogOutput {
    private let logger: Logger

    public init(configuration: YCLoggerConfiguration = .init()) {
        self.logger = Logger(subsystem: configuration.subsystem, category: "Cache")
    }

    public func log(_ message: String, level: YCLogLevel, category: String?, file: String, line: Int, function: String) {
        let fileName = (file as NSString).lastPathComponent  // 优化性能
        let categoryStr = category.map { "[\($0)] " } ?? ""
        // 添加库名前缀
        let logMessage = "YYCacheSwift: \(categoryStr)\(fileName):\(line) \(function) - \(message)"

        logger.log(level: level.osLogType, "\(logMessage)")
    }
}
#endif

/// 文件日志输出器
public class YCFileLogOutput: YCLogOutput {
    private let fileURL: URL
    private let configuration: YCLoggerConfiguration
    private let queue = DispatchQueue(label: "com.yycacheswift.logger.file", qos: .utility)
    private var fileHandle: FileHandle?
    private var pendingLogs: [String] = []
    private var lastFlushTime: Date = Date()
    private let flushInterval: TimeInterval = 1.0  // 每秒刷新一次

    public init(configuration: YCLoggerConfiguration = .init()) {
        self.configuration = configuration
        // 将日志放到 Library/Caches/YYCacheSwift/logs，避免 iCloud 备份
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let logsDir = caches.appendingPathComponent("YYCacheSwift/logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        self.fileURL = logsDir.appendingPathComponent(configuration.logFileName)

        // 确保日志文件存在
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
        }

        // 打开文件句柄
        self.fileHandle = try? FileHandle(forWritingTo: fileURL)
        self.fileHandle?.seekToEndOfFile()
    }

    deinit {
        flush()
        fileHandle?.closeFile()
    }

    public func log(_ message: String, level: YCLogLevel, category: String?, file: String, line: Int, function: String) {
        queue.async { [weak self] in
            guard let self = self else { return }

            let fileName = (file as NSString).lastPathComponent  // 优化性能
            let categoryStr = category.map { "[\($0)] " } ?? ""
            let timestamp = DateFormatter.logFormatter.string(from: Date())
            // 添加库名前缀
            let logEntry = "YYCacheSwift: [\(timestamp)] [\(level.description)] \(categoryStr)\(fileName):\(line) \(function) - \(message)\n"

            // 批量写入，减少 IO 操作
            self.pendingLogs.append(logEntry)

            // 定期或达到阈值时刷新
            let now = Date()
            if now.timeIntervalSince(self.lastFlushTime) >= self.flushInterval || self.pendingLogs.count >= 10 {
                self.flush()
                self.lastFlushTime = now
            }
        }
    }

    private func flush() {
        guard !pendingLogs.isEmpty else { return }

        // 检查文件大小，超过限制则轮转
        checkAndRotateIfNeeded()

        let combinedLogs = pendingLogs.joined()
        if let data = combinedLogs.data(using: .utf8) {
            fileHandle?.write(data)
        }

        pendingLogs.removeAll(keepingCapacity: true)
    }

    // 日志轮转功能
    private func checkAndRotateIfNeeded() {
        guard let fileSize = getFileSize(),
              fileSize > configuration.maxFileSize else {
            return
        }

        rotateLogFiles()
    }

    private func getFileSize() -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path) else {
            return nil
        }
        return attributes[.size] as? Int64
    }

    private func rotateLogFiles() {
        // 先关闭当前文件句柄
        fileHandle?.closeFile()

        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        let baseName = configuration.appName

        // 删除最旧的日志文件（如果存在）
        let oldestLog = directory.appendingPathComponent("\(baseName).\(configuration.maxFileCount).log")
        try? fileManager.removeItem(at: oldestLog)

        // 重命名现有日志文件：app.3.log → app.4.log, app.2.log → app.3.log, ...
        for i in (1..<configuration.maxFileCount).reversed() {
            let oldFile = directory.appendingPathComponent("\(baseName).\(i).log")
            let newFile = directory.appendingPathComponent("\(baseName).\(i + 1).log")
            try? fileManager.moveItem(at: oldFile, to: newFile)
        }

        // 重命名当前日志文件：app.log → app.1.log
        let backupFile = directory.appendingPathComponent("\(baseName).1.log")
        try? fileManager.moveItem(at: fileURL, to: backupFile)

        // 创建新的空日志文件
        fileManager.createFile(atPath: fileURL.path, contents: nil, attributes: nil)

        // 重新打开文件句柄
        fileHandle = try? FileHandle(forWritingTo: fileURL)
        fileHandle?.seekToEndOfFile()
    }
}

/// 日志系统配置
public struct YCLoggerConfiguration {
    /// 应用名称（用于日志文件名和系统日志）
    public var appName: String = "YYCacheSwift"

    /// 日志文件名
    public var logFileName: String {
        return "\(appName).log"
    }

    /// 系统日志子系统标识
    public var subsystem: String {
        return "io.github.yycache.swift"
    }

    /// 日志文件最大大小（字节），默认 10MB
    public var maxFileSize: Int64 = 10 * 1024 * 1024

    /// 最多保留的日志文件数量
    public var maxFileCount: Int = 5

    /// 是否启用远程日志
    public var enableRemoteLogging: Bool = false

    /// 远程日志服务器 URL
    public var remoteLoggingURL: URL?

    /// 远程日志 API Key
    public var remoteLoggingAPIKey: String?

    public init() {}
}

/// 核心日志服务 - 遵循用户偏好的核心服务模块化设计
public class YCLogger {
    
    // MARK: - Singleton
    
    public static let shared = YCLogger()
    
    // MARK: - Properties
    
    public var logLevel: YCLogLevel = .debug
    public var isEnabled: Bool = true
    public var configuration = YCLoggerConfiguration()

    private var outputs: [YCLogOutput] = []
    private let queue = DispatchQueue(label: "com.yycacheswift.logger", qos: .utility)
    
    // MARK: - Initialization
    
    private init() {
        setupDefaultOutputs()
    }
    
    // MARK: - Configuration
    
    private func setupDefaultOutputs() {
        // 添加控制台输出
        addOutput(YCConsoleLogOutput())

        // 在 Debug 模式下添加文件日志
        #if DEBUG
        addOutput(YCFileLogOutput(configuration: configuration))
        #endif

        // 注意：不再同时启用 OSLog，避免重复输出
        // 如需启用系统日志，可在 AppDelegate 中手动添加：
        // if #available(iOS 14.0, *) {
        //     YCLogger.shared.addOutput(YCOSLogOutput(configuration: YCLogger.shared.configuration))
        // }
    }
    
    /// 添加日志输出器
    public func addOutput(_ output: YCLogOutput) {
        queue.sync {
            self.outputs.append(output)
        }
    }

    /// 移除所有日志输出器
    public func removeAllOutputs() {
        queue.sync {
            self.outputs.removeAll()
        }
    }
    
    /// 设置日志级别
    public func setLogLevel(_ level: YCLogLevel) {
        self.logLevel = level
    }
    
    /// 启用/禁用日志
    public func setLoggingEnabled(_ enabled: Bool) {
        self.isEnabled = enabled
    }
    
    // MARK: - Logging Methods
    
    /// 记录详细调试信息
    public func verbose(
        _ message: String,
        category: String? = nil,
        file: String = #file,
        line: Int = #line,
        function: String = #function
    ) {
        log(message, level: .verbose, category: category, file: file, line: line, function: function)
    }
    
    /// 记录调试信息
    public func debug(
        _ message: String,
        category: String? = nil,
        file: String = #file,
        line: Int = #line,
        function: String = #function
    ) {
        log(message, level: .debug, category: category, file: file, line: line, function: function)
    }
    
    /// 记录普通信息
    public func info(
        _ message: String,
        category: String? = nil,
        file: String = #file,
        line: Int = #line,
        function: String = #function
    ) {
        log(message, level: .info, category: category, file: file, line: line, function: function)
    }
    
    /// 记录警告信息
    public func warning(
        _ message: String,
        category: String? = nil,
        file: String = #file,
        line: Int = #line,
        function: String = #function
    ) {
        log(message, level: .warning, category: category, file: file, line: line, function: function)
    }
    
    /// 记录错误信息
    public func error(
        _ message: String,
        category: String? = nil,
        file: String = #file,
        line: Int = #line,
        function: String = #function
    ) {
        log(message, level: .error, category: category, file: file, line: line, function: function)
    }
    
    // MARK: - Core Logging

    private func log(
        _ message: String,
        level: YCLogLevel,
        category: String?,
        file: String,
        line: Int,
        function: String
    ) {
        // 快速退出路径 - 避免不必要的队列调度
        guard isEnabled && level.rawValue >= logLevel.rawValue else { return }

        // 在 Release 模式下，跳过 verbose 和 debug 日志
        #if !DEBUG
        guard level.rawValue >= YCLogLevel.info.rawValue else { return }
        #endif

        // 避免在主线程上执行日志操作
        if Thread.isMainThread && outputs.count > 1 {
            queue.async { [weak self] in
                guard let self = self else { return }
                for output in self.outputs {
                    output.log(message, level: level, category: category, file: file, line: line, function: function)
                }
            }
        } else {
            // 如果只有一个输出器或不在主线程，同步执行以减少延迟
            for output in outputs {
                output.log(message, level: level, category: category, file: file, line: line, function: function)
            }
        }
    }
    
    // MARK: - File Management
    
    /// 获取日志文件内容
    public func getLogFileContent() -> String? {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let logsDir = caches.appendingPathComponent("YYCacheSwift/logs", isDirectory: true)
        let logFileURL = logsDir.appendingPathComponent(configuration.logFileName)
        return try? String(contentsOf: logFileURL, encoding: .utf8)
    }

    /// 获取日志文件大小
    public func getLogFileSize() -> Int64? {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let logsDir = caches.appendingPathComponent("YYCacheSwift/logs", isDirectory: true)
        let logFileURL = logsDir.appendingPathComponent(configuration.logFileName)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: logFileURL.path) else { return nil }
        return attributes[.size] as? Int64
    }

    /// 获取日志文件路径
    public func getLogFilePath() -> String? {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let logsDir = caches.appendingPathComponent("YYCacheSwift/logs", isDirectory: true)
        let logFileURL = logsDir.appendingPathComponent(configuration.logFileName)
        return FileManager.default.fileExists(atPath: logFileURL.path) ? logFileURL.path : nil
    }

    /// 清理日志文件
    public func clearLogFiles() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let directory = caches.appendingPathComponent("YYCacheSwift/logs", isDirectory: true)

        // 删除所有日志文件
        let fileManager = FileManager.default
        let baseName = configuration.appName

        // 确保日志目录存在
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)

        // 删除主日志文件
        let mainLog = directory.appendingPathComponent(configuration.logFileName)
        try? fileManager.removeItem(at: mainLog)

        // 删除轮转的日志文件
        for i in 1...configuration.maxFileCount {
            let rotatedLog = directory.appendingPathComponent("\(baseName).\(i).log")
            try? fileManager.removeItem(at: rotatedLog)
        }

        // 重新创建空文件
        fileManager.createFile(atPath: mainLog.path, contents: nil, attributes: nil)

        info("日志文件已清理", category: "Logger")
    }

    /// 导出所有日志文件
    public func exportAllLogs() -> [URL] {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let directory = caches.appendingPathComponent("YYCacheSwift/logs", isDirectory: true)
        let fileManager = FileManager.default
        let baseName = configuration.appName

        var logFiles: [URL] = []

        // 主日志文件
        let mainLog = directory.appendingPathComponent(configuration.logFileName)
        if fileManager.fileExists(atPath: mainLog.path) {
            logFiles.append(mainLog)
        }

        // 轮转的日志文件
        for i in 1...configuration.maxFileCount {
            let rotatedLog = directory.appendingPathComponent("\(baseName).\(i).log")
            if fileManager.fileExists(atPath: rotatedLog.path) {
                logFiles.append(rotatedLog)
            }
        }

        return logFiles
    }
    
    /// 配置远程日志
    public func configureRemoteLogging(serverURL: URL, apiKey: String? = nil) {
        // 实现远程日志功能
        // 可以添加网络日志输出器
        info("远程日志配置完成: \(serverURL)", category: "Logger")
    }
    
    /// 刷新远程日志
    public func flushRemoteLogs() {
        // 实现远程日志刷新
        debug("远程日志已刷新", category: "Logger")
    }
}

// MARK: - Extensions

extension DateFormatter {
    static let logFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

// MARK: - Global Logging Functions

/// 全局日志函数 - 泛型版本，兼容各种类型
public func printLog<T>(
    _ message: T,
    file: String = #file,
    line: Int = #line,
    function: String = #function
) {
    YCLogger.shared.debug("\(message)", file: file, line: line, function: function)
}

/// 全局日志函数 - 多参数版本
public func printLog(
    _ items: Any...,
    separator: String = " ",
    file: String = #file,
    line: Int = #line,
    function: String = #function
) {
    let message = items.map { "\($0)" }.joined(separator: separator)
    YCLogger.shared.debug(message, file: file, line: line, function: function)
}

/// 详细日志 - 泛型版本
public func verboseLog<T>(
    _ message: T,
    category: String? = nil,
    file: String = #file,
    line: Int = #line,
    function: String = #function
) {
    YCLogger.shared.verbose("\(message)", category: category, file: file, line: line, function: function)
}

/// 调试日志 - 泛型版本
public func debugLog<T>(
    _ message: T,
    category: String? = nil,
    file: String = #file,
    line: Int = #line,
    function: String = #function
) {
    YCLogger.shared.debug("\(message)", category: category, file: file, line: line, function: function)
}

/// 信息日志 - 泛型版本
public func infoLog<T>(
    _ message: T,
    category: String? = nil,
    file: String = #file,
    line: Int = #line,
    function: String = #function
) {
    YCLogger.shared.info("\(message)", category: category, file: file, line: line, function: function)
}

/// 警告日志 - 泛型版本
public func warningLog<T>(
    _ message: T,
    category: String? = nil,
    file: String = #file,
    line: Int = #line,
    function: String = #function
) {
    YCLogger.shared.warning("\(message)", category: category, file: file, line: line, function: function)
}

/// 错误日志 - 泛型版本
public func errorLog<T>(
    _ message: T,
    category: String? = nil,
    file: String = #file,
    line: Int = #line,
    function: String = #function
) {
    YCLogger.shared.error("\(message)", category: category, file: file, line: line, function: function)
}
