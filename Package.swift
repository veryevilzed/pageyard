// swift-tools-version:5.9
import Foundation
import PackageDescription

// MuPDF is linked statically from vendor/mupdf, built by Scripts/build_mupdf.sh
// (universal, macOS 13+, PDF core only).
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let mupdf = "\(root)/vendor/mupdf"

let package = Package(
    name: "PageYard",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "CMuPDF",
            path: "Sources/CMuPDF",
            cSettings: [.unsafeFlags(["-I\(mupdf)/include"])],
            linkerSettings: [
                .unsafeFlags(["-L\(mupdf)/lib"]),
                .linkedLibrary("mupdf"),
                .linkedLibrary("mupdf-third"),
            ]
        ),
        .executableTarget(
            name: "PageYard",
            dependencies: ["CMuPDF"],
            path: "Sources/PageYard"
        ),
    ]
)
