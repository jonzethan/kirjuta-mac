// swift-tools-version: 6.0
import PackageDescription

// whisper.cpp ehitatakse eraldi (scripts/build-whisper.sh) staatilisteks teekideks Metaliga.
let wb = Context.packageDirectory + "/vendor/whisper.cpp/build-mac"
// sherpa-onnx (kõnelejad) – scripts/fetch-sherpa.sh laeb staatilised teegid
let so = Context.packageDirectory + "/vendor/sherpa-onnx"

let package = Package(
    name: "Kirjuta",
    platforms: [.macOS("14.2")],
    targets: [
        .target(
            name: "CWhisper",
            path: "Sources/CWhisper",
            cSettings: [
                .headerSearchPath("../../vendor/whisper.cpp/include"),
                .headerSearchPath("../../vendor/whisper.cpp/ggml/include"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(wb)/src", "-L\(wb)/ggml/src", "-L\(wb)/ggml/src/ggml-metal", "-L\(wb)/ggml/src/ggml-blas",
                ]),
                .linkedLibrary("whisper"), .linkedLibrary("ggml"), .linkedLibrary("ggml-base"),
                .linkedLibrary("ggml-cpu"), .linkedLibrary("ggml-metal"), .linkedLibrary("ggml-blas"),
                .linkedLibrary("c++"),
                .linkedFramework("Metal"), .linkedFramework("MetalKit"), .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
            ]
        ),
        .target(
            name: "CSherpa",
            path: "Sources/CSherpa",
            cSettings: [.headerSearchPath("../../vendor/sherpa-onnx/include")],
            linkerSettings: [
                .unsafeFlags(["-L\(so)/lib"]),
                .linkedLibrary("sherpa-onnx-c-api"), .linkedLibrary("sherpa-onnx-core"),
                .linkedLibrary("kaldi-native-fbank-core"), .linkedLibrary("kissfft-float"),
                .linkedLibrary("kaldi-decoder-core"), .linkedLibrary("sherpa-onnx-kaldifst-core"),
                .linkedLibrary("sherpa-onnx-fstfar"), .linkedLibrary("sherpa-onnx-fst"),
                .linkedLibrary("ssentencepiece_core"), .linkedLibrary("utf8proc"),
                .linkedLibrary("onnxruntime"), .linkedLibrary("c++"),
                .linkedFramework("Foundation"), .linkedFramework("CoreML"),
            ]
        ),
        .target(
            name: "KirjutaCore",
            dependencies: ["CWhisper", "CSherpa"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Kirjuta",
            dependencies: ["KirjutaCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
