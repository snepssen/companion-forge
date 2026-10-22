import Foundation
import ModelStore

/// Where a pinned model is read from on macOS and Linux Release: only the
/// shared folder, and nothing is downloaded, moved, or deleted. iOS and every
/// Debug build use `Resources.models` instead, so this is not called there.
public enum ModelPlaces {
    /// The read-only store. A missing shared root throws, and the message
    /// names the path that was expected.
    public static func store() throws -> ModelStore {
        #if os(iOS) || DEBUG
        throw ModelStore.Failure("The shared model folder is for macOS and Linux Release.")
        #else
        ModelStore.release(at: try ModelStore.sharedRoot())
        #endif
    }

    /// The model directory, or a failure that names each expected file path.
    public static func directory(of model: some StoredModel) throws -> URL {
        try store().require(model)
    }

    public static func isDownloaded(_ model: some StoredModel) -> Bool {
        (try? store().isDownloaded(model)) ?? false
    }
}
