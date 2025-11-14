import Foundation

struct WritePayload: Sendable {
    let data: Data
    let ttl: TimeInterval?
}

actor CoalescingWriter {
    private var states: [String: State] = [:]

    private final class State {
        var latest: WritePayload?
        var running: Task<Void, Never>?
        init() {}
    }

    func submit(key: String, payload: WritePayload, perform: @escaping (String, WritePayload) async -> Void) async {
        let state = states[key] ?? {
            let s = State()
            states[key] = s
            return s
        }()
        state.latest = payload
        guard state.running == nil else { return }

        state.running = Task { [weak state] in
            while let s = state {
                // 抓取当前最新并开启静默窗口聚合
                var current = s.latest
                s.latest = nil
                guard current != nil else { break }
                // 等待静默窗口，无新提交再继续
                while true {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    if let next = s.latest {
                        current = next
                        s.latest = nil
                        continue
                    } else {
                        break
                    }
                }
                if let current { await perform(key, current) }
                // 循环以处理写入期间新到的提交
            }
            state?.running = nil
        }
        _ = await state.running?.result
        if state.running == nil { states[key] = nil }
    }
}
