// swift-tools-version: 6.0
import PackageDescription

// whisper.cpp ehitatakse eraldi (scripts/build-whisper.sh) staatilisteks teekideks Metaliga.
let wb = Context.packageDirectory + "/vendor/whisper.cpp/build-mac"

let package = Package(
    name: "Kirjuta",
    platforms: [.macOS(.v14)],
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
            name: "KirjutaCore",
            dependencies: ["CWhisper"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Kirjuta",
            dependencies: ["KirjutaCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
