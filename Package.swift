// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.
//
// Bumped to 6.3 on 2026-05-14 (Dockerfile já usava `swift:6.3-jammy` desde
// antes — agora tools-version está alinhado).
//
// Swift 6.3 (2026-03-27) traz: SwiftBuild preview opcional
// (`--build-system swiftbuild`), C interop via plugin (experimental), suporte
// prebuilt para swift-syntax em macros, `swift package show-traits` e ajustes
// no symbol-graph para command plugins. Sem breaking changes — manifests 6.2
// seguem compilando.
//
// Swift 6.3.1 (2026-04-17) fixa stack-allocation bugs em async functions
// ("freed pointer was not the last allocation" em `swift_asyncLet_finish`) —
// crítico para um BFF com uso pesado de `async let` em handlers.

import PackageDescription

let package = Package(
    name: "SOCIAL-CARE",
    platforms: [
        .macOS(.v26)
    ],
    dependencies: [
        // NOTA: `swift-testing` NÃO é mais dep externa desde Swift 6.0 — vem
        // embutida no toolchain. SPM 6.3 rejeita declarar como package com
        // erro "Disabled default traits on package 'swift-testing' that
        // declares no traits". Basta `import Testing` no test file.
        .package(url: "https://github.com/vapor/sql-kit.git", from: "3.0.0"),
        .package(url: "https://github.com/vapor/postgres-kit.git", from: "2.0.0"),
        // Vapor 4.118+ exige Swift 6.0 mínimo; 4.121.4 (2026-04-10) é compat
        // com Swift 6.3 sem mudança de API.
        .package(url: "https://github.com/vapor/vapor.git", from: "4.118.0"),
        .package(url: "https://github.com/vapor/jwt.git", from: "5.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "social-care-s",
            dependencies: [
                .product(name: "SQLKit", package: "sql-kit"),
                .product(name: "PostgresKit", package: "postgres-kit"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "JWT", package: "jwt"),
            ],
            path: "Sources/social-care-s"
        ),
        .testTarget(
            name: "social-care-sTests",
            // `Testing` module vem do toolchain em Swift 6.0+; não precisa
            // listar product/package. Test files usam `import Testing` direto.
            dependencies: [
                "social-care-s",
            ],
            path: "Tests/social-care-sTests"
        ),
    ]
)
