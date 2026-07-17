// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ventmac",
    platforms: [.macOS(.v13)],
    targets: [
        .systemLibrary(
            name: "CSpeex",
            path: "Sources/CSpeex",
            pkgConfig: "speex",
            providers: [.brew(["speex"])]
        ),
        .systemLibrary(
            name: "CSpeexDSP",
            path: "Sources/CSpeexDSP",
            pkgConfig: "speexdsp",
            providers: [.brew(["speexdsp"])]
        ),
        .target(
            name: "CVentrilo3",
            dependencies: ["CSpeex", "CSpeexDSP"],
            cSettings: [
                .define("NO_AUTOMAKE"),
                .define("HAVE_SPEEX", to: "1"),
                .define("HAVE_SPEEX_DSP", to: "1"),
                .headerSearchPath("."),
                .unsafeFlags([
                    "-Wno-implicit-function-declaration",
                    "-Wno-int-conversion",
                    "-Wno-incompatible-function-pointer-types",
                    "-Wno-deprecated-non-prototype",
                    "-Wno-deprecated-declarations",
                    "-Wno-pointer-sign",
                    "-Wno-format",
                    "-Wno-unused-variable",
                    "-Wno-unused-but-set-variable",
                ])
            ]
        ),
        .target(
            name: "VentCore",
            dependencies: ["CVentrilo3"]
        ),
        .executableTarget(
            name: "ventctl",
            dependencies: ["VentCore"]
        ),
        .executableTarget(
            name: "VentMac",
            dependencies: ["VentCore"]
        ),
    ]
)
