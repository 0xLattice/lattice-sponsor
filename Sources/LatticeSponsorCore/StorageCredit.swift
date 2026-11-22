// Storage credit: work that buys a file a permanent pin on the node. An
// uploader lists every Volume of its file, root included, and pays for its
// bytes in work at a rate in bytes per coin of each chain the sponsor names.
// Once paid, the sponsor pins every Volume on its node, which checks each
// against its CID, and keeps it until the operator takes it down: then every
// Volume of it is unpinned and its CID blocked, so no upload pins it again.
// The roots stored, their bytes and Volumes are kept in one JSON file, which
// counts the budget across restarts, and the CIDs blocked in another beside
// it. An upload not yet paid is held in memory for at most `lifetime`, and a
// paid one until it is pinned; a restart forfeits either.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LatticeNodeAPI
import UInt256

/// One Volume of an upload: its entries (CID to base64 bytes, as the node's
/// `POST /pins` takes), or, for one the node reads with `GET /fetch`, its
/// bytes as the uploader declares them.
public struct StoreVolume: Codable, Sendable, Equatable {
    public let cid: String
    public let entries: [String: String]?
    public let bytes: Int?

    public init(cid: String, entries: [String: String]? = nil, bytes: Int? = nil) {
        self.cid = cid
        self.entries = entries
        self.bytes = bytes
    }
}

/// An upload's state, as `GET /store/:root` answers it: its bytes, the coins
/// still needed on each chain with a rate, the bytes paid, and whether it is
/// pinned.
public struct StoreStatus: Sendable, Equatable {
    public let root: String
    public let bytes: Int
    public let needed: [String: UInt64]
    public let credit: Int
    public let stored: Bool
}

/// The storage budget and what holds it, as `GET /terms` answers it: room
/// for a new upload is `budget - stored - held`.
public struct StorageUse: Codable, Sendable, Equatable {
    /// The most bytes pinned at once (`--storage-budget`).
    @DecimalString public var budget: UInt64
    /// The bytes pinned.
    @DecimalString public var stored: UInt64
    /// The bytes reserved by uploads not yet pinned.
    @DecimalString public var held: UInt64

    public init(budget: UInt64, stored: UInt64, held: UInt64) {
        self.budget = budget
        self.stored = stored
        self.held = held
    }
}

public struct StorageLedger: Sendable {
    /// The most bytes pinned at once.
    public let budget: Int
    /// Bytes per coin (the chain's smallest unit) on each chain.
    public let rates: [[String]: Int]
    /// The most bytes held in pending uploads at once.
    public let pendingCap: Int
    /// How long an upload not yet pinned is held.
    public let lifetime: Int64
    let file: URL
    /// The CIDs the operator took down, kept beside `file`.
    let blocklistFile: URL
    /// The most bytes in one Volume, raw, and as the body of its pin: the
    /// node takes a `POST /pins` body of at most 2 MiB. A raw Volume holds a
    /// 1 MiB chunk of file bytes and its block's DAG-CBOR framing, as
    /// lattice-storage lays a file out.
    public static let largestVolume = (1 << 20) + 1024
    static let largestPin = 2 << 20

    public struct Upload: Sendable {
        public let volumes: [StoreVolume]
        public let bytes: Int
        let created: Int64
        /// Bytes paid, scaled by 2^64 as fee credit is.
        var paid: UInt256 = .zero
        var pinning = false
    }

    private var pending: [String: Upload] = [:]
    /// Each pinned root's bytes, as kept in `file`.
    public private(set) var stored: [String: Int] = [:]
    /// Each pinned root's Volumes.
    private var volumes: [String: [String]] = [:]
    /// The CIDs taken down: no upload naming one as its root or a Volume is
    /// taken, paid or pinned.
    public private(set) var blocked: Set<String> = []

    private struct Record: Codable {
        let root: String
        let bytes: Int
        /// Absent in a file written before takedowns: the root alone.
        let volumes: [String]?
    }

    /// Read what `file` says is stored, and the CIDs blocked beside it
    /// (`lattice-sponsor-blocklist.json`), if they exist.
    public init(
        budget: Int, rates: [[String]: Int], file: URL,
        pendingCap: Int = 256 << 20, lifetime: Int64 = 3_600_000
    ) throws {
        self.budget = budget
        self.rates = rates
        self.file = file
        self.pendingCap = pendingCap
        self.lifetime = lifetime
        self.blocklistFile = file.deletingLastPathComponent().appendingPathComponent("lattice-sponsor-blocklist.json")
        if FileManager.default.fileExists(atPath: file.path) {
            for record in try JSONDecoder().decode([Record].self, from: Data(contentsOf: file)) {
                stored[record.root] = record.bytes
                volumes[record.root] = record.volumes ?? [record.root]
            }
        }
        if FileManager.default.fileExists(atPath: blocklistFile.path) {
            blocked = Set(try JSONDecoder().decode([String].self, from: Data(contentsOf: blocklistFile)))
        }
    }

    /// The budget, the bytes pinned, and the bytes held for uploads.
    public func use(now: Int64) -> StorageUse {
        var held = 0
        for upload in pending.values where isLive(upload, now: now) { held += upload.bytes }
        return StorageUse(budget: UInt64(budget), stored: UInt64(stored.values.reduce(0, +)), held: UInt64(held))
    }

    /// The chain's bytes per coin.
    public func rate(on chainPath: [String]) throws -> Int {
        guard let rate = rates[chainPath], rate > 0 else { throw SponsorRefusal.noStorageRate }
        return rate
    }

    /// Hold an upload of `volumes` under `root` until it is paid. Its bytes
    /// are reserved from the budget while it is held, so a paid upload
    /// always fits.
    public mutating func upload(root: String, volumes: [StoreVolume], now: Int64) throws -> StoreStatus {
        sweep(now: now)
        guard !blocked.contains(root), !volumes.contains(where: { blocked.contains($0.cid) }) else {
            throw SponsorRefusal.blocked
        }
        guard pending[root] == nil, stored[root] == nil else { throw SponsorRefusal.draft("root already uploaded") }
        guard volumes.contains(where: { $0.cid == root }) else { throw SponsorRefusal.draft("the root is not listed") }
        var bytes = 0
        for volume in volumes {
            var size = 0
            if let entries = volume.entries {
                // A Volume the node already holds is pinned as held, its
                // entries ignored, so it must at least carry its own root.
                guard entries[volume.cid] != nil else { throw SponsorRefusal.draft("a Volume's entries lack its root") }
                for value in entries.values {
                    guard let data = Data(base64Encoded: value) else { throw SponsorRefusal.draft("entries are not base64") }
                    size += data.count
                }
            } else {
                guard let declared = volume.bytes, declared > 0 else {
                    throw SponsorRefusal.draft("a Volume without entries declares its bytes")
                }
                size = declared
            }
            guard size <= Self.largestVolume,
                  try JSONEncoder().encode(volume).count < Self.largestPin - 1024 else {
                throw SponsorRefusal.draft("a Volume is over 1 MiB and 1 KiB")
            }
            let (sum, overflow) = bytes.addingReportingOverflow(size)
            guard !overflow else { throw SponsorRefusal.overBudget }
            bytes = sum
        }
        let held = pending.values.reduce(0) { $0 + $1.bytes }
        guard bytes <= budget - stored.values.reduce(0, +) - held else { throw SponsorRefusal.overBudget }
        guard bytes <= pendingCap - held else { throw SponsorRefusal.busy }
        pending[root] = Upload(volumes: volumes, bytes: bytes, created: now)
        return status(of: root)!
    }

    /// Refuse work for `root` unless it is held and `chainPath` has a rate.
    public func check(root: String, on chainPath: [String], now: Int64) throws {
        guard !blocked.contains(root) else { throw SponsorRefusal.blocked }
        _ = try rate(on: chainPath)
        guard let upload = pending[root], now - upload.created < lifetime else { throw SponsorRefusal.unknownUpload }
    }

    /// Pay `root` a share's `value` on `chainPath` (units scaled by 2^64), at
    /// the chain's rate, saturating.
    public mutating func credit(root: String, value: UInt256, on chainPath: [String], now: Int64) throws {
        try check(root: root, on: chainPath, now: now)
        let (bytes, overflow) = value.multipliedReportingOverflow(by: UInt256(UInt64(try rate(on: chainPath))))
        let (sum, overflowed) = pending[root]!.paid.addingReportingOverflow(overflow ? .max : bytes)
        pending[root]!.paid = overflowed ? .max : sum
    }

    /// The upload under `root` once it is paid in full and not already being
    /// pinned, marked as being pinned.
    public mutating func takePaid(_ root: String) -> Upload? {
        guard let upload = pending[root], !upload.pinning,
              upload.paid >= UInt256(UInt64(upload.bytes)) * SponsorLedger.unit else { return nil }
        pending[root]!.pinning = true
        return upload
    }

    /// Record `root` as stored, once each of its Volumes is pinned, or with
    /// `pinned` false, hand it back to be pinned again. False when the upload
    /// was taken down while it was being pinned: its Volumes are then the
    /// caller's to unpin (`unreferenced`).
    @discardableResult
    public mutating func finish(_ root: String, pinned: Bool) throws -> Bool {
        guard pinned else {
            pending[root]?.pinning = false
            return true
        }
        guard let upload = pending.removeValue(forKey: root) else { return false }
        stored[root] = upload.bytes
        volumes[root] = upload.volumes.map(\.cid)
        try save()
        return true
    }

    /// Take `cid` down: block it for good, with the root of every upload
    /// naming it as its root or a Volume, and drop those not yet pinned.
    /// Answers the Volumes to unpin on the node: `cid` itself, and every
    /// Volume of each pinned upload naming it that no other pinned upload
    /// keeps. The pinned uploads stay counted until `release`, so a takedown
    /// whose unpinning fails is simply asked again.
    public mutating func block(_ cid: String) throws -> [String] {
        let dropped = pending.filter { $0.key == cid || $0.value.volumes.contains { $0.cid == cid } }.keys
        let roots = Set(volumes.filter { $0.key == cid || $0.value.contains(cid) }.keys)
        let blocking = roots.union(dropped).union([cid])
        if !blocking.isSubset(of: blocked) {
            blocked.formUnion(blocking)
            try JSONEncoder().encode(blocked.sorted()).write(to: blocklistFile, options: .atomic)
        }
        for root in dropped { pending[root] = nil }
        let kept = Set(volumes.filter { !roots.contains($0.key) }.values.joined())
        let released = Set(roots.flatMap { volumes[$0]! }).subtracting(kept).union([cid])
        return released.sorted()
    }

    /// Forget the pinned uploads naming the blocked `cid`, once their
    /// Volumes are unpinned: their bytes return to the budget.
    public mutating func release(_ cid: String) throws {
        let roots = volumes.filter { $0.key == cid || $0.value.contains(cid) }.keys
        guard !roots.isEmpty else { return }
        for root in roots {
            stored[root] = nil
            volumes[root] = nil
        }
        try save()
    }

    /// Of `cids`, those no pinned upload keeps.
    public func unreferenced(_ cids: [String]) -> [String] {
        let kept = Set(volumes.values.joined())
        return cids.filter { !kept.contains($0) }
    }

    private func save() throws {
        let records = stored.map { Record(root: $0.key, bytes: $0.value, volumes: volumes[$0.key]) }
            .sorted { $0.root < $1.root }
        try JSONEncoder().encode(records).write(to: file, options: .atomic)
    }

    public func status(of root: String) -> StoreStatus? {
        if let bytes = stored[root] {
            return StoreStatus(root: root, bytes: bytes, needed: [:], credit: bytes, stored: true)
        }
        guard let upload = pending[root] else { return nil }
        let cost = UInt256(UInt64(upload.bytes)) * SponsorLedger.unit
        let owed = upload.paid >= cost ? UInt256.zero : cost - upload.paid
        var needed: [String: UInt64] = [:]
        for (chainPath, rate) in rates where rate > 0 {
            let (coins, remainder) = owed.quotientAndRemainder(dividingBy: UInt256(UInt64(rate)) * SponsorLedger.unit)
            needed[chainPath.joined(separator: "/")] = UInt64((remainder == .zero ? coins : coins + UInt256(1)).words[0])
        }
        let paid = upload.paid / SponsorLedger.unit
        let credit = paid > UInt256(UInt64(Int.max)) ? Int.max : Int(paid.words[0])
        return StoreStatus(root: root, bytes: upload.bytes, needed: needed, credit: credit, stored: false)
    }

    /// Drop uploads held past `lifetime`, except one paid in full: some of
    /// its Volumes may be pinned already, so it keeps its bytes reserved.
    private mutating func sweep(now: Int64) {
        pending = pending.filter { isLive($0.value, now: now) }
    }

    private func isLive(_ upload: Upload, now: Int64) -> Bool {
        upload.paid >= UInt256(UInt64(upload.bytes)) * SponsorLedger.unit || now - upload.created < lifetime
    }
}

extension SponsorNode {
    /// Pin each of `upload`'s Volumes on the node, which checks every entry
    /// against its CID. A Volume without entries is read with `GET /fetch`,
    /// and is refused if it is larger than its declared bytes.
    public func pin(_ upload: StorageLedger.Upload) async throws {
        struct Pin: Codable {
            let cid: String
            let entries: [String: String]?
        }
        for volume in upload.volumes {
            var entries = volume.entries
            if entries == nil {
                var fetch = request("fetch/\(volume.cid)")
                fetch.timeoutInterval = 60
                let fetched = try JSONDecoder().decode(Pin.self, from: try await call(fetch)).entries ?? [:]
                let size = fetched.values.reduce(0) { $0 + (Data(base64Encoded: $1)?.count ?? 0) }
                guard size <= volume.bytes ?? 0 else { throw SponsorRefusal.overBudget }
                entries = fetched
            }
            var pin = request("pins")
            pin.httpMethod = "POST"
            pin.timeoutInterval = 60
            pin.setValue("application/json", forHTTPHeaderField: "Content-Type")
            pin.httpBody = try JSONEncoder().encode(Pin(cid: volume.cid, entries: entries))
            _ = try await call(pin)
        }
    }

    /// Unpin each of `cids` on the node with `DELETE /pins/:cid`; one the
    /// node does not hold (404) is already released.
    public func unpin(_ cids: [String]) async throws {
        for cid in cids {
            var delete = request("pins/\(cid)")
            delete.httpMethod = "DELETE"
            do {
                _ = try await call(delete)
            } catch Failure.status(404) {}
        }
    }
}
