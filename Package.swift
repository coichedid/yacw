// swift-tools-version:5.9
// YACW — Yet Another Claude Watcher. Copyright (c) 2026 Clovis Chedid. MIT License (see LICENSE).
import PackageDescription

let package = Package(
    name: "yacw",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "YACWCore", targets: ["YACWCore"]),
        .executable(name: "yacw-cli", targets: ["yacw-cli"]),
        .executable(name: "YACWApp", targets: ["YACWApp"]),
    ],
    targets: [
        .target(name: "YACWCore", resources: [.process("Resources")]),
        .target(name: "YACWSelfTest", dependencies: ["YACWCore"]),
        .executableTarget(name: "yacw-cli", dependencies: ["YACWCore", "YACWSelfTest"]),
        .executableTarget(name: "YACWApp", dependencies: ["YACWCore"]),
        .testTarget(name: "YACWCoreTests", dependencies: ["YACWSelfTest"]),
    ]
)
