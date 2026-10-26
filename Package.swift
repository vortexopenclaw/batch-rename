// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "BatchRename", platforms: [.macOS(.v14)], products: [.executable(name: "BatchRename", targets: ["BatchRename"])], targets: [.target(name: "RenameCore"), .executableTarget(name: "BatchRename", dependencies: ["RenameCore"]), .testTarget(name: "RenameCoreTests", dependencies: ["RenameCore"])], swiftLanguageModes: [.v5])
