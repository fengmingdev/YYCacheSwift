import Foundation

/// 类型擦除的通用 transformer，基于 DataTransforming 协议。
public struct AnyTransformer<T> {
    private let _encode: (T) throws -> Data
    private let _decode: (Data) throws -> T

    public init<Trans: DataTransforming>(_ transformer: Trans) where Trans.Value == T {
        self._encode = transformer.encode
        self._decode = transformer.decode
    }

    public func encode(_ value: T) throws -> Data { try _encode(value) }
    public func decode(_ data: Data) throws -> T { try _decode(data) }
}

// MARK: - NSCoding / NSSecureCoding Transformers

/// NSCoding transformer（非安全编码，优先考虑使用 NSSecureCodingTransform）。
public struct NSCodingTransform<T: NSObject & NSCoding>: DataTransforming {
    public typealias Value = T
    public init() {}
    public func encode(_ value: T) throws -> Data {
        // 非安全编码
        // NSKeyedArchiver.archivedData 已弃用，但仍可用于兼容非 NSSecureCoding 的对象
        return try NSKeyedArchiver.archivedData(withRootObject: value, requiringSecureCoding: false)
    }
    public func decode(_ data: Data) throws -> T {
        let obj = try NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data)
        guard let typed = obj as? T else { throw CacheError.decoding }
        return typed
    }
}

    /// NSSecureCoding transformer（推荐）。
public struct NSSecureCodingTransform<T: NSObject & NSSecureCoding>: DataTransforming {
    public typealias Value = T
    private let requiresSecureCoding: Bool
    public init(requiresSecureCoding: Bool = true) { self.requiresSecureCoding = requiresSecureCoding }
    public func encode(_ value: T) throws -> Data {
        if requiresSecureCoding {
            return try NSKeyedArchiver.archivedData(withRootObject: value, requiringSecureCoding: true)
        } else {
            return try NSKeyedArchiver.archivedData(withRootObject: value, requiringSecureCoding: false)
        }
    }
    public func decode(_ data: Data) throws -> T {
        if requiresSecureCoding {
            guard let obj = try NSKeyedUnarchiver.unarchivedObject(ofClass: T.self, from: data) else { throw CacheError.decoding }
            return obj
        } else {
            let obj = try NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data)
            guard let typed = obj as? T else { throw CacheError.decoding }
            return typed
        }
    }
}
