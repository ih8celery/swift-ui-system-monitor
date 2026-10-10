import Combine
import Foundation

/// A value the host samples on a plugin's behalf: the latest reading, plus a publisher for the
/// readings after it. Readings are delivered on the main thread. Reading `value` never starts
/// the sampler; listing the feed in `sharedFeeds` does.
public final class Feed<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Value
    private let subject = PassthroughSubject<Value, Never>()

    /// A feed that holds `initial` until the first reading arrives.
    public init(initial: Value) {
        current = initial
    }

    /// The latest reading. Safe to read from any thread, including a plugin's collect queue.
    public var value: Value {
        lock.withLock { current }
    }

    /// Every reading after now, on the main thread.
    public var publisher: AnyPublisher<Value, Never> {
        subject.receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }

    /// A feed and the one way to write it, for a plugin's tests: the closure records a reading
    /// and tells subscribers, exactly as the host does, from any thread. A plugin can never get a
    /// writer for the host's feeds this way, because the writer belongs to the feed this call
    /// makes.
    public static func forTesting(initial: Value) -> (feed: Feed<Value>, send: @Sendable (Value) -> Void) {
        let feed = Feed(initial: initial)
        return (feed, { feed.send($0) })
    }

    /// The host's side: record a reading and tell subscribers. Any thread. Package-only: a
    /// plugin may read `value` and observe `publisher`, but only the host writes.
    package func send(_ value: Value) {
        lock.withLock {
            current = value
            // Safe to send from inside the lock: `publisher` always delivers through
            // `receive(on: .main)`, so no subscriber ever runs while the lock is held.
            subject.send(value)
        }
    }
}
