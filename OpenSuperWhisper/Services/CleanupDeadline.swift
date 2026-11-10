import Foundation

enum CleanupDeadline {
    static func run<Value: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask(operation: operation)
            group.addTask {
                let nanoseconds = UInt64(max(0.01, seconds) * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }

            guard let first = try await group.next() else {
                throw URLError(.unknown)
            }
            return first
        }
    }
}

struct CleanupHTTPResponse: @unchecked Sendable {
    let data: Data
    let response: URLResponse
}
