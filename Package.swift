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
        // The node's client contract (LatticeNodeAPI). Move the pin on
        // purpose, after the tests pass against it.
        .package(
            url: "https://github.com/0xLattice/lattice-node.git",
            revision: "d30f603467d5eeaf471ef303c4a65495e01aadd5"
        ),
        // The node's own pins, so both build the same consensus code; the
        // proof of work (LatticePoW) is Lattice's.
        .package(
            url: "https://github.com/0xLattice/Lattice.git",
            revision: "9664612f317b7e406283a91cf3bf11150f094baa"
        ),
        .package(
            url: "https://github.com/0xLattice/cashew.git",
            exact: "5.0.7"
        ),
        .package(url: "https://github.com/0xLattice/UInt256.git", from: "2.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "LatticeSponsorCore",
            dependencies: [
                .product(name: "LatticeNodeAPI", package: "lattice-node"),
                .product(name: "Lattice", package: "lattice"),
                .product(name: "UInt256", package: "UInt256"),
            ]),
        .executableTarget(
            name: "LatticeSponsor",
            dependencies: [
                "LatticeSponsorCore",
                .product(name: "LatticeNodeAPI", package: "lattice-node"),
                .product(name: "Lattice", package: "lattice"),
                .product(name: "cashew", package: "cashew"),
                .product(name: "UInt256", package: "UInt256"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
        .testTarget(
            name: "LatticeSponsorTests",
            dependencies: [
                "LatticeSponsor",
                "LatticeSponsorCore",
                .product(name: "Lattice", package: "lattice"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]),
        .testTarget(
            name: "LatticeSponsorCoreTests",
            dependencies: [
                "LatticeSponsorCore",
                .product(name: "LatticeNodeAPI", package: "lattice-node"),
                .product(name: "Lattice", package: "lattice"),
                .product(name: "cashew", package: "cashew"),
                .product(name: "UInt256", package: "UInt256"),
            ]),
    ]
)
