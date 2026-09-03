import Foundation

/// Bridges an async call into the synchronous CLI entry points, which run from
/// `ClawdBarApp.init` before any event loop exists.
///
/// The obvious shape — a `Task { }` that assigns to a captured local
/// `var outcome` and a `semaphore.wait()` that reads it afterwards — is
/// rejected by Swift 6.3 ("sending value of non-Sendable type
/// `() async -> ()` risks causing data races"), which is what turned macOS CI
/// red on a newer toolchain than the dev machine's. Here the task closure
/// captures only Sendable values, and the hand-off goes through a locked box.
func runBlocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) -> Result<T, Error> {
    let box = ResultBox<T>()
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        do {
            box.store(.success(try await body()))
        } catch {
            box.store(.failure(error))
        }
        semaphore.signal()
    }
    semaphore.wait()
    return box.take() ?? .failure(CLIRunError.noResult)
}

enum CLIRunError: Error, CustomStringConvertible {
    case noResult
    var description: String { "The async call signalled completion without a result." }
}

private final class ResultBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?

    func store(_ value: Result<T, Error>) {
        lock.lock()
        result = value
        lock.unlock()
    }

    func take() -> Result<T, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}
