import Foundation

actor PendingOps<Value> {
    private var gets: [String: Task<Value?, Error>] = [:]

    func getOrStart(forKey key: String, operation: @escaping () async throws -> Value?) async throws -> Value? {
        if let task = gets[key] {
            return try await task.value
        }
        let task = Task<Value?, Error> {
            defer { Task { await self.removeGet(forKey: key) } }
            return try await operation()
        }
        gets[key] = task
        return try await task.value
    }

    private func removeGet(forKey key: String) {
        gets.removeValue(forKey: key)
    }
}

