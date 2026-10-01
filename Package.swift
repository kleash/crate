// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Crate",
    platforms: [.macOS(.v13)],
    targets: [
        // macOS ships libarchive without headers; Sources/CArchive/archive_min.h declares what we use.
        .systemLibrary(name: "CArchive"),
        .target(name: "ArchiveCore", dependencies: ["CArchive"]),
        .executableTarget(name: "Crate", dependencies: ["ArchiveCore"]),
        // Quick Look preview extension; build.sh packages it as Crate.app/Contents/PlugIns/CrateQuickLook.appex.
        .executableTarget(
            name: "CrateQuickLook",
            dependencies: ["ArchiveCore"],
            swiftSettings: [.unsafeFlags(["-application-extension"])],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
        ),
        .testTarget(name: "ArchiveCoreTests", dependencies: ["ArchiveCore", "CArchive"]),
    ]
)
