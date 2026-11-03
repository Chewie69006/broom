// Harness only, for ThreadSanitizer builds (-DBROOM_TSAN_MUTEX).
// Swift's Synchronization.Mutex locks with raw futexes on Linux, which TSan can't see, so it reports
// false races. This pthread-based stand-in has the same API and shadows the imported type.
#if BROOM_TSAN_MUTEX
import Glibc

nonisolated final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let handle: UnsafeMutablePointer<pthread_mutex_t>

    init(_ initialValue: Value) {
        value = initialValue
        handle = .allocate(capacity: 1)
        pthread_mutex_init(handle, nil)
    }

    deinit {
        pthread_mutex_destroy(handle)
        handle.deallocate()
    }

    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        pthread_mutex_lock(handle)
        defer { pthread_mutex_unlock(handle) }
        return try body(&value)
    }
}
#endif
