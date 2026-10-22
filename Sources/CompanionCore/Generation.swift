import Foundation

/// Generations through one model, one at a time.
///
/// MLX evaluates a token on the GPU and returns before that work has
/// finished. Starting another generation on the same model then reads buffers
/// the first is still writing: a crash in the quantized matmul
/// (EXC_BAD_ACCESS). Cancelling returns only once the one in flight has
/// stopped, and the next does not start until then.
public actor GenerationQueue {
    private var current: Task<Void, Never>?

    public init() {}

    /// Cancel the generation in flight and wait until it has returned.
    public func cancel() async {
        current?.cancel()
        await current?.value
    }

    /// Cancel whatever is in flight, wait until it has returned, then run
    /// `body`. Returns once `body` is the generation in flight, not once it
    /// has finished: a later call waits for it.
    public func begin(_ body: @Sendable @escaping () async -> Void) async {
        let previous = current
        previous?.cancel()
        let task = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await body()
        }
        current = task
        await previous?.value
    }

    /// Wait until the generation in flight has returned.
    public func finished() async {
        await current?.value
    }
}
