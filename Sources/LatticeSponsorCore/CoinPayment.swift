// Coin payment: a transfer to the sponsor's --pay-to buys storage at the
// sponsor's own rates, as work does. One of the transfer's signers claims it
// for one upload, and it is credited once it is
// --coin-depth blocks deep in the node's canonical chain, read through the
// node's explorer and transaction routes. Each transfer is credited once; the
// transfers credited are kept in one JSON file.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Lattice
import LatticeNodeAPI

/// `POST /pay`: a transfer on `chain`, claimed by one of its signers for an
/// upload's storage.
public struct CoinPayment: Codable, Sendable {
    public let chain: String
    public let txCID: String
    /// One of the transaction's signers, as its body lists them (an address).
    public let signer: String
    /// The signer's signature over `message`, in hex.
    public let signature: String
    /// The upload's root.
    public let store: String

    public init(chain: String, txCID: String, signer: String, signature: String, store: String) {
        self.chain = chain
        self.txCID = txCID
        self.signer = signer
        self.signature = signature
        self.store = store
    }

    public var chainPath: [String] { chain.components(separatedBy: "/") }

    /// What the signer signs, with the scheme Lattice signs transactions with
    /// (`CryptoUtils.sign`): it binds the transfer to one chain and one
    /// upload.
    public var message: String { "lattice-sponsor-pay:v1:\(chain):\(txCID):\(store)" }
}

/// The transfers already credited, kept in `file`, and those being checked.
public struct PaymentLedger: Sendable {
    let file: URL
    public private(set) var credited: Set<String> = []
    private var claimed: Set<String> = []

    /// Read what `file` says is credited, if it exists.
    public init(file: URL) throws {
        self.file = file
        if FileManager.default.fileExists(atPath: file.path) {
            credited = Set(try JSONDecoder().decode([String].self, from: Data(contentsOf: file)))
        }
    }

    /// Hold `txCID` while it is checked: refused if it is credited or held.
    public mutating func claim(_ txCID: String) throws {
        guard !credited.contains(txCID), claimed.insert(txCID).inserted else { throw SponsorRefusal.alreadyCredited }
    }

    /// Let `txCID` go, and with `credit`, record it as credited first.
    public mutating func release(_ txCID: String, credit: Bool) throws {
        claimed.remove(txCID)
        guard credit else { return }
        var next = credited
        next.insert(txCID)
        try JSONEncoder().encode(next.sorted()).write(to: file, options: .atomic)
        credited = next
    }
}

extension SponsorNode {
    /// The coins `payment` pays `payTo`, net, once it is in the node's
    /// canonical chain with at least `depth` blocks built on its block and
    /// claimed by one of its signers. Each refusal is named.
    public func verify(_ payment: CoinPayment, payTo: String, depth: UInt64) async throws -> UInt64 {
        let cid = payment.txCID
        guard !cid.isEmpty, cid.utf8.count <= 128, cid.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw SponsorRefusal.draft("txCID is not a CID")
        }
        let chainPath = payment.chainPath
        let described: ExplorerTransaction = try await read("api/transaction/\(cid)", on: chainPath)
        guard let height = described.blockHeight, let hash = described.blockHash else { throw SponsorRefusal.notIncluded }
        // Depth is counted from a tip the inclusion is rechecked against.
        let tip: ExplorerLatestBlock = try await read("api/block/latest", on: chainPath)
        struct Block: Decodable { let hash: String }
        let block: Block = try await read("api/block/\(height)", on: chainPath)
        guard block.hash == hash, tip.height >= height else { throw SponsorRefusal.notIncluded }
        guard tip.height - height >= depth else { throw SponsorRefusal.notDeepEnough }
        struct Raw: Decodable { let transaction: Transaction }
        let raw: Raw = try await read("transactions/\(cid)", on: chainPath)
        guard described.signers.contains(payment.signer),
              let key = raw.transaction.signatures.keys.first(where: { CryptoUtils.createAddress(from: $0) == payment.signer })
        else { throw SponsorRefusal.notSigner }
        guard CryptoUtils.verify(message: payment.message, signature: payment.signature, publicKeyHex: key) else {
            throw SponsorRefusal.invalidSignature
        }
        var amount: Int64 = 0
        for action in described.accountActions where action.owner == payTo {
            let (sum, overflow) = amount.addingReportingOverflow(action.delta)
            guard !overflow else { throw SponsorRefusal.noPayment }
            amount = sum
        }
        guard amount > 0 else { throw SponsorRefusal.noPayment }
        return UInt64(amount)
    }

    /// A read on `chainPath`; one the node does not have is not included.
    private func read<Value: Decodable>(_ path: String, on chainPath: [String]) async throws -> Value {
        var request = request(path)
        if chainPath != [DEFAULT_ROOT_DIRECTORY], var url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false) {
            url.queryItems = [URLQueryItem(name: "chainPath", value: chainPath.joined(separator: "/"))]
            request.url = url.url
        }
        do {
            return try JSONDecoder().decode(Value.self, from: try await call(request))
        } catch Failure.status(404) {
            throw SponsorRefusal.notIncluded
        }
    }
}
