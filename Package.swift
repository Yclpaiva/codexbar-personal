// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CodexBarPersonal",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CodexBarPersonal", targets: ["CodexBarPersonal"])],
    targets: [
        .target(name: "PersonalCore", resources: [.process("Resources")], linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "CodexBarPersonal", dependencies: ["PersonalCore"]),
        .executableTarget(name: "PersonalCoreChecks", dependencies: ["PersonalCore"], path: "Tests/PersonalCoreTests"),
    ])
