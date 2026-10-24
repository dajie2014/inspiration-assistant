// swift-tools-version: 5.9
// 本地音乐生成器 —— ACE-Step 1.5 的轻量外壳界面
// 只依赖系统 SwiftUI / AppKit / AVFoundation，Command Line Tools 即可编译。

import PackageDescription

let package = Package(
    name: "LocalMusic",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "LocalMusic",
            path: "Sources/LocalMusic"
        )
    ]
)
