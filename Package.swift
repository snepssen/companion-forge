// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Companion",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        // For the iPad and iPhone apps' Xcode project, later.
        .library(name: "CompanionCore", targets: ["CompanionCore"]),
        .library(name: "CompanionEngine", targets: ["CompanionEngine"]),
        .library(name: "CompanionUI", targets: ["CompanionUI"]),
    ],
    dependencies: [
        // The same pins interpreter-forge's Interpreter builds with.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.32.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.5"),
        .package(url: "https://github.com/huggingface/swift-huggingface", exact: "1.0.0"),
        .package(url: "https://github.com/snepssen/voice-core", from: "1.0.3"),
        // NSException to NSError, for AVAudioEngine, which raises instead of throwing,
        // and Silero VAD. The weights stay in the app.
        .package(url: "https://github.com/snepssen/speech-core", from: "0.2.0"),
        // CryptoKit on Apple platforms; the same API from swift-crypto elsewhere,
        // so `swift run cccheck` is not tied to a Mac.
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.2"),
    ],
    targets: [
        // Everything decided without a model: when a turn has ended, what the
        // face looks like, where a reply breaks into sentences, what is an
        // echo. Held to its cases by `cccheck`.
        .target(name: "CompanionCore", dependencies: [
            .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
        ]),
        // Never links a model; `swift run cccheck` stays fast and runs anywhere.
        .executableTarget(name: "cccheck", dependencies: [
            "CompanionCore",
            .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
        ]),
        // The models and the live loop: Silero VAD and Parakeet (ONNX,
        // FluidAudio), the language model and the memory's embedder (MLX),
        // the voice (voice-core's Piper), one echo-cancelled audio engine.
        .target(name: "CompanionEngine", dependencies: [
            "CompanionCore",
            .product(name: "ObjCExceptions", package: "speech-core"),
            .product(name: "SileroVAD", package: "speech-core"),
            .product(name: "VoiceCore", package: "voice-core"),
            .product(name: "FluidAudio", package: "FluidAudio"),
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
            .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
            .product(name: "HuggingFace", package: "swift-huggingface"),
            .product(name: "Tokenizers", package: "swift-transformers"),
        ]),
        // The face and the window, shared by the Mac app and, later, the iPad and iPhone apps.
        .target(name: "CompanionUI", dependencies: ["CompanionCore", "CompanionEngine"]),
        .executableTarget(name: "Companion", dependencies: ["CompanionEngine", "CompanionUI"]),
        // Recorded speech through the live loop in real time, with the reply's
        // echo leaking back in; and the face rendered to images. For measuring
        // without a microphone or a window.
        .executableTarget(name: "ccrun", dependencies: [
            "CompanionCore", "CompanionEngine", "CompanionUI",
            .product(name: "SileroVAD", package: "speech-core"),
        ]),
    ]
)
