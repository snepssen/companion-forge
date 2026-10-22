import Foundation

/// Models already on this machine, linked into the app's store by
/// `scripts/fetch-models.sh`. The running app never searches a neighbouring
/// checkout: it reads `Application Support/Companion/Models`, and a symlink
/// there is the model.
public enum SharedModels {
    /// The size of the file at `url`. A symlink contributes the size of the
    /// file it names, which is how a linked model matches the catalogue.
    public static func byteCount(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    /// Whether `url` itself is a symlink, including one whose target is gone.
    public static func isLink(_ url: URL) -> Bool {
        var info = stat()
        let linked = url.path.withCString { lstat($0, &info) == 0 }
        // mode_t and the S_IF* macros differ in width between Darwin and Glibc.
        return linked && (Int(info.st_mode) & Int(S_IFMT)) == Int(S_IFLNK)
    }
}
