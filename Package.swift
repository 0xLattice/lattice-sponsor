// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LatticeSponsor",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "lattice-sponsor", targets: ["LatticeSponsor"]),
    ],
    dependencies: [
        // The node's wire models, miner core, and mining coordinator. Move the
        // pin on purpose, after the tests pass against it.
        .package(
            url: "https://github.com/0xLattice/lattice-node.git",
            revision: "47c57ae7643363ecf64fa417c4f178bb6775dab7"
        ),
        // The node's own pins, so both build the same consensus code.
        .package(
            url: "https://github.com/0xLattice/Lattice.git",
            exact: "54.2.1"
        ),
        .package(
            url: "https://github.com/0xLattice/cashew.git",
            exact: "5.0.3"
        ),
        .package(url: "https://github.com/0xLattice/UInt256.git", from: "1.1.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "LatticeSponsorCore",
            dependencies: [
                .product(name: "LatticeMinerCore", package: "lattice-node"),
                .product(name: "Lattice", package: "lattice"),
                .product(name: "UInt256", package: "UInt256"),
            ]),
        .executableTarget(
            name: "LatticeSponsor",
            dependencies: [
                "LatticeSponsorCore",
                .product(name: "LatticeNodeAPI", package: "lattice-node"),
                .product(name: "LatticeMinerCore", package: "lattice-node"),
                .product(name: "LatticeMiningCoordinator", package: "lattice-node"),
                .product(name: "Lattice", package: "lattice"),
                .product(name: "cashew", package: "cashew"),
                .product(name: "UInt256", package: "UInt256"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
        .testTarget(
            name: "LatticeSponsorCoreTests",
            dependencies: [
                "LatticeSponsorCore",
                .product(name: "LatticeMinerCore", package: "lattice-node"),
                .product(name: "Lattice", package: "lattice"),
                .product(name: "cashew", package: "cashew"),
                .product(name: "UInt256", package: "UInt256"),
            ]),
    ]
)
