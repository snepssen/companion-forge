import Foundation

/// A language model the companion can talk with, pinned to a revision.
///
/// Generalists, small enough for a phone, measured in translate-core
/// (scripts/compare-models.py, the complete-thought judge): Gemma 4 E4B is the
/// best of them and wants a Mac or a 12 GB iPhone; Qwen3 4B and Gemma 4 E2B
/// fit an 8 GB phone beside speech recognition and the voice.
public struct ChatModel: Identifiable, Hashable, Sendable {
    public struct File: Hashable, Sendable {
        let name: String
        let size: Int64
    }

    public let id: String  // folder name, and what is remembered as the choice
    public let name: String
    public let tagline: String
    public let repo: String
    public let revision: String
    /// Peak memory while generating, measured on a Mac.
    public let memoryGB: Double
    let files: [File]

    public var download: Int64 { files.reduce(0) { $0 + $1.size } }

    /// Whether this device has the memory for it alongside recognition and the voice.
    public var fits: Bool {
        #if os(macOS)
        true
        #else
        Double(ProcessInfo.processInfo.physicalMemory) / 1e9 >= memoryGB * 2.3
        #endif
    }
}

public enum ModelCatalog {
    // translate-core's pins, sizes and measurements, so a model downloaded
    // for either app is the same files.
    public static let all: [ChatModel] = [
        ChatModel(
            id: "gemma-4-e4b-it-4bit", name: "Gemma 4 E4B", tagline: "Best conversation · Mac or 12 GB iPhone",
            repo: "mlx-community/gemma-4-e4b-it-4bit", revision: "475b9088d29754a3379866cf5aeb6b41acd313c2",
            memoryGB: 4.7,
            files: [.init(name: "chat_template.jinja", size: 17336), .init(name: "config.json", size: 6628),
                    .init(name: "generation_config.json", size: 208), .init(name: "model.safetensors.index.json", size: 240_961),
                    .init(name: "processor_config.json", size: 1316), .init(name: "tokenizer.json", size: 32_169_626),
                    .init(name: "tokenizer_config.json", size: 2740), .init(name: "model.safetensors", size: 5_146_800_534)]),
        ChatModel(
            id: "qwen3-4b-instruct-2507-4bit", name: "Qwen3 4B", tagline: "Fits an 8 GB phone",
            repo: "mlx-community/Qwen3-4B-Instruct-2507-4bit", revision: "50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b",
            memoryGB: 2.8,
            files: [.init(name: "added_tokens.json", size: 707), .init(name: "chat_template.jinja", size: 4040),
                    .init(name: "config.json", size: 938), .init(name: "generation_config.json", size: 238),
                    .init(name: "merges.txt", size: 1_671_853), .init(name: "model.safetensors.index.json", size: 63964),
                    .init(name: "special_tokens_map.json", size: 613), .init(name: "tokenizer.json", size: 11_422_654),
                    .init(name: "tokenizer_config.json", size: 5440), .init(name: "vocab.json", size: 2_776_833),
                    .init(name: "model.safetensors", size: 2_263_022_417)]),
        ChatModel(
            id: "gemma-4-e2b-it-4bit", name: "Gemma 4 E2B", tagline: "Fastest, roughest",
            repo: "mlx-community/gemma-4-e2b-it-4bit", revision: "238767527555cb75a05732a84dff5d6ba0dd6809",
            memoryGB: 3.0,
            files: [.init(name: "chat_template.jinja", size: 17336), .init(name: "config.json", size: 6395),
                    .init(name: "generation_config.json", size: 208), .init(name: "model.safetensors.index.json", size: 218_323),
                    .init(name: "processor_config.json", size: 1316), .init(name: "tokenizer.json", size: 32_169_626),
                    .init(name: "tokenizer_config.json", size: 2740), .init(name: "model.safetensors", size: 3_550_670_554)]),
    ]

    public static var offered: [ChatModel] { all.filter(\.fits) }
    public static var recommended: ChatModel { offered.first ?? all[all.count - 1] }
    public static func model(_ id: String?) -> ChatModel? { all.first { $0.id == id } }
}

/// Models on this device: fetched file by file from their pinned revision into
/// Application Support, sizes checked so a cut-off download is fetched again
/// rather than loaded, and kept out of backups. For development, this
/// checkout's models/ and translate-core's beside it count too.
public enum ModelStore {
    static var directory: URL { Resources.support.appending(path: "Models") }

    static func folders(for model: ChatModel) -> [URL] {
        [directory, Resources.checkout.appending(path: "models"), Resources.translateCore.appending(path: "models")]
            .map { $0.appending(path: model.id) }
    }

    public static func location(of model: ChatModel) -> URL? {
        folders(for: model).first { folder in model.files.allSatisfy { fileSize(folder.appending(path: $0.name)) == $0.size } }
    }

    public static func isDownloaded(_ model: ChatModel) -> Bool { location(of: model) != nil }

    /// Fetch whatever of `model` isn't here yet; `progress` runs from 0 to 1.
    @discardableResult
    public static func download(_ model: ChatModel, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        if let found = location(of: model) { return found }
        let folder = directory.appending(path: model.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = folder
        try excluded.setResourceValues(values)
        var done: Int64 = 0
        for file in model.files {
            let target = folder.appending(path: file.name)
            if fileSize(target) == file.size {
                done += file.size
                continue
            }
            let url = URL(string: "https://huggingface.co/\(model.repo)/resolve/\(model.revision)/\(file.name)")!
            let base = done
            let downloaded = try await Download.fetch(url) { written in
                progress(Double(base + written) / Double(model.download))
            }
            defer { try? FileManager.default.removeItem(at: downloaded) }
            guard fileSize(downloaded) == file.size else {
                throw Problem("\(file.name) arrived as \(fileSize(downloaded) ?? 0) bytes, not \(file.size). Try again on a steady connection.")
            }
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: downloaded, to: target)
            done += file.size
        }
        progress(1)
        return folder
    }

    static func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }
}

/// One file, with the bytes written so far reported as they arrive.
final class Download: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Int64) -> Void
    private var continuation: CheckedContinuation<URL, Error>?

    private init(progress: @escaping @Sendable (Int64) -> Void) { self.progress = progress }

    static func fetch(_ url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let download = Download(progress: progress)
        let session = URLSession(configuration: .default, delegate: download, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            download.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite _: Int64) {
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            continuation?.resume(throwing: Problem("The model server did not return a successful HTTP response."))
            continuation = nil
            return
        }
        // The temporary file is deleted when this returns; keep it.
        let kept = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            continuation?.resume(returning: kept)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}

struct Problem: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
