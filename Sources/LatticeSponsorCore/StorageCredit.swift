// Storage credit: work that buys a group of Volumes pin space on the node.
// A group is named by its root CID and is exactly the Volumes its uploader
// lists, root included; the sponsor reads no file format. Each share of work
// naming a root is valued as for a fee on Nexus (its chance of the block,
// times its reward) and added to that root's credit, which decays with the
// operator's half-life. Held groups are ranked by credit per byte: one that
// does not fit the budget evicts the lowest-ranked groups, and one that would
// have to evict a group ranked above it is refused.
//
// The sponsor claims (and so may later unpin) only the Volumes it pinned
// itself: one the node already had pinned is the operator's, used by a group
// but never claimed. A claimed Volume is unpinned once no held group uses it.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Lattice
import UInt256

/// The groups this sponsor holds, their credit, and the Volumes it claimed:
/// all of it persisted, unlike fee credit.
public struct StorageLedger: Sendable {
    /// The most bytes held across every group, counting each claimed Volume
    /// once.
    public let budget: Int
    /// The most bytes in one group.
    public let largestGroup: Int
    /// Credit halves every `halfLife` milliseconds.
    public let halfLife: Int64
    /// How long credit for a root not held outlives its last share.
    public let creditLifetime: Int64

    public struct Credit: Codable, Sendable, Equatable {
        /// Nexus coins, as of `at`.
        public var value: Double
        public var at: Int64
    }

    public struct State: Codable, Sendable, Equatable {
        public var credits: [String: Credit] = [:]
        /// Each held group: its Volumes and their bytes.
        public var groups: [String: [String: Int]] = [:]
        /// The Volumes this sponsor pinned and has not yet unpinned.
        public var claimed: Set<String> = []

        public init() {}
    }

    public private(set) var state: State

    public init(
        budget: Int, largestGroup: Int, halfLife: Int64, creditLifetime: Int64 = 3_600_000,
        state: State = State()
    ) {
        precondition(budget > 0 && largestGroup > 0 && halfLife > 0)
        self.budget = budget
        self.largestGroup = largestGroup
        self.halfLife = halfLife
        self.creditLifetime = creditLifetime
        self.state = state
    }

    /// Add a share's `value` (units scaled by 2^64) to `root`'s credit.
    public mutating func pay(root: String, value: UInt256, now: Int64) {
        state.credits[root] = Credit(value: credit(of: root, now: now) + Self.coins(value), at: now)
    }

    /// `root`'s credit at `now`, in coins.
    public func credit(of root: String, now: Int64) -> Double {
        guard let credit = state.credits[root] else { return 0 }
        return credit.value * exp2(-Double(max(0, now - credit.at)) / Double(halfLife))
    }

    public func isHeld(_ root: String) -> Bool {
        state.groups[root] != nil
    }

    /// A held group's bytes.
    public func bytes(of root: String) -> Int {
        state.groups[root]?.values.reduce(0, +) ?? 0
    }

    /// A Volume's bytes, when a held group uses it.
    public func size(of volume: String) -> Int? {
        state.groups.values.lazy.compactMap { $0[volume] }.first
    }

    /// The groups holding `root` with `volumes` (each with its bytes) evicts,
    /// when the node pins `pinned` now. A pinned Volume this sponsor did not
    /// claim is the operator's: it costs the budget nothing.
    public func plan(root: String, volumes: [String: Int], pinned: Set<String>, now: Int64) throws -> [String] {
        let credit = credit(of: root, now: now)
        guard credit > 0 else { throw SponsorRefusal.unfunded }
        let bytes = volumes.values.reduce(0, +)
        guard bytes <= largestGroup else { throw SponsorRefusal.groupTooBig }
        let operators = pinned.subtracting(state.claimed)
        let cost = volumes.filter { !operators.contains($0.key) }.values.reduce(0, +)
        guard cost <= budget else { throw SponsorRefusal.neverFits }
        let rank = Self.rank(credit, bytes)
        return try evictions(adding: volumes, operators: operators, now: now) { lowest in
            guard lowest < rank else { throw SponsorRefusal.outranked }
        }
    }

    /// The held groups to drop, lowest-ranked first, until they and
    /// `volumes` fit the budget, each Volume counted once and an operator's
    /// not at all. `check` sees each one's rank before it is dropped.
    private func evictions(
        adding volumes: [String: Int], operators: Set<String>, now: Int64, check: (Double) throws -> Void
    ) rethrows -> [String] {
        var uses: [String: Int] = [:]
        var cost = 0
        for group in [volumes] + Array(state.groups.values) {
            for (volume, size) in group {
                uses[volume, default: 0] += 1
                if uses[volume] == 1, !operators.contains(volume) { cost += size }
            }
        }
        let ranks = state.groups.keys.map { (rank: rank(of: $0, now: now), root: $0) }.sorted { $0 < $1 }
        var evict: [String] = []
        for (rank, root) in ranks {
            guard cost > budget else { break }
            try check(rank)
            for (volume, size) in state.groups[root]! {
                uses[volume]! -= 1
                if uses[volume] == 0, !operators.contains(volume) { cost -= size }
            }
            evict.append(root)
        }
        return evict
    }

    /// Claim `volume` before pinning it: until a held group uses it, it is
    /// an orphan, unpinned at the next pass.
    public mutating func claim(_ volume: String) {
        state.claimed.insert(volume)
    }

    /// Hold `root` with `volumes`, every one of them pinned.
    public mutating func hold(root: String, volumes: [String: Int]) {
        state.groups[root] = volumes
    }

    /// Stop holding `roots`. Their credit stays, decaying, until it expires.
    public mutating func drop(_ roots: [String]) {
        for root in roots { state.groups.removeValue(forKey: root) }
    }

    /// Claimed Volumes no held group uses: the ones to unpin.
    public var orphans: [String] {
        let used = Set(state.groups.values.flatMap(\.keys))
        return state.claimed.subtracting(used).sorted()
    }

    /// `volume` was unpinned.
    public mutating func unclaim(_ volume: String) {
        state.claimed.remove(volume)
    }

    /// Match what the node pins: a group missing any of its Volumes is no
    /// longer held, a claimed Volume the node no longer pins is no longer
    /// claimed, and while the groups exceed the budget the lowest-ranked go.
    public mutating func reconcile(pinned: Set<String>, now: Int64) {
        state.claimed.formIntersection(pinned)
        state.groups = state.groups.filter { $0.value.keys.allSatisfy(pinned.contains) }
        drop(evictions(adding: [:], operators: pinned.subtracting(state.claimed), now: now) { _ in })
    }

    /// Drop credit for roots not held once it outlives `creditLifetime`.
    public mutating func prune(now: Int64) {
        state.credits = state.credits.filter { root, credit in
            isHeld(root) || now - credit.at < creditLifetime
        }
    }

    private func rank(of root: String, now: Int64) -> Double {
        Self.rank(credit(of: root, now: now), bytes(of: root))
    }

    private static func rank(_ credit: Double, _ bytes: Int) -> Double {
        credit / Double(max(bytes, 1))
    }

    /// Units scaled by 2^64, as coins.
    static func coins(_ value: UInt256) -> Double {
        value.words.reversed().reduce(0.0) { $0 * 0x1p64 + Double($1) } / 0x1p64
    }

    /// The state as written to disk.
    public static func load(from file: URL) throws -> State {
        guard FileManager.default.fileExists(atPath: file.path) else { return State() }
        return try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
    }

    /// Write the state to a temporary file and rename it over `file`.
    public func save(to file: URL) throws {
        try JSONEncoder().encode(state).write(to: file, options: .atomic)
    }
}

/// The node's operator pins, reached with the RPC cookie.
public struct StorageNode: Sendable {
    public typealias Send = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    let base: URL
    let authorization: @Sendable () -> String?
    let send: Send

    public init(
        base: URL,
        authorization: @escaping @Sendable () -> String?,
        send: @escaping Send = { try await URLSession.shared.data(for: $0) }
    ) {
        self.base = base
        self.authorization = authorization
        self.send = send
    }

    public enum Failure: Error, Equatable {
        case status(Int)
    }

    /// The node's shape for a Volume: its root and entries, CID to bytes
    /// (base64 in JSON), as `POST /pins` takes and `GET /fetch` answers.
    public struct Volume: Codable, Sendable, Equatable {
        public let cid: String
        public let entries: [String: Data]?

        public init(cid: String, entries: [String: Data]? = nil) {
            self.cid = cid
            self.entries = entries
        }
    }

    public func pins() async throws -> Set<String> {
        struct Pins: Decodable { let pins: [String] }
        return Set(try JSONDecoder().decode(Pins.self, from: try await call(request("pins"))).pins)
    }

    /// The largest body the node's operator routes read (Hummingbird's
    /// default).
    public static let largestBody = 2 << 20

    /// Pin `cid`: by CID alone when the node holds it (nil), else with the
    /// entries `bytes` gives, each of which the node checks against its CID
    /// and stores (returned). A refusal of the CID or of what was given (400
    /// `invalidCID` or `invalidVolume`, 409 `conflictingVolume`) is
    /// `badVolume`.
    public func pin(
        _ cid: String, bytes: @Sendable () async throws -> [String: Data]
    ) async throws -> [String: Data]? {
        do {
            try await post(Volume(cid: cid))
            return nil
        } catch Failure.status(404) {
            let entries = try await bytes()
            let body = try JSONEncoder().encode(Volume(cid: cid, entries: entries))
            guard body.count <= Self.largestBody else { throw SponsorRefusal.volumeTooBig }
            do {
                try await post(body)
            } catch Failure.status(let status) where status == 400 || status == 409 {
                throw SponsorRefusal.badVolume
            }
            return entries
        } catch Failure.status(400) {
            throw SponsorRefusal.badVolume
        }
    }

    private func post(_ volume: Volume) async throws {
        try await post(try JSONEncoder().encode(volume))
    }

    private func post(_ body: Data) async throws {
        var request = request("pins")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        _ = try await call(request)
    }

    public func unpin(_ cid: String) async throws {
        var request = request("pins/\(cid)")
        request.httpMethod = "DELETE"
        _ = try await call(request)
    }

    /// The Volume read from the node's store or its peers, each entry
    /// checked against its CID by the node.
    public func fetch(_ cid: String) async throws -> [String: Data] {
        do {
            let volume = try JSONDecoder().decode(Volume.self, from: try await call(request("fetch/\(cid)")))
            guard volume.cid == cid, let entries = volume.entries else { throw SponsorRefusal.volumeUnavailable }
            return entries
        } catch Failure.status(let status) where status == 400 || status == 404 {
            throw SponsorRefusal.volumeUnavailable
        }
    }

    private func request(_ path: String) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let authorization = authorization() {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func call(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await send(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Failure.status(status) }
        return data
    }
}

/// Storage sold for work: the ledger, the node's pins it is matched to, and
/// the file it is kept in.
public actor StorageSeller {
    public private(set) var ledger: StorageLedger
    let node: StorageNode
    let file: URL
    let now: @Sendable () -> Int64
    /// Whether the ledger has been matched to the node's pins since boot.
    private var reconciled = false
    /// A store or an unpin in progress. One at a time: each reads which
    /// Volumes are claimed, then changes the node's pins. Stores wait their
    /// turn in `waiting`.
    private var pinning = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    /// Roots with a store running or waiting: one each.
    private var storing: Set<String> = []
    private var dirty = false

    /// What an uploader reads of its group.
    public struct Status: Sendable, Equatable {
        public let root: String
        public let bytes: Int
        /// In Nexus coins, now.
        public let credit: Double
        public let held: Bool
    }

    public init(ledger: StorageLedger, node: StorageNode, file: URL, now: @escaping @Sendable () -> Int64) {
        self.ledger = ledger
        self.node = node
        self.file = file
        self.now = now
    }

    /// Add a share's `value` (units scaled by 2^64) to `root`'s credit; it
    /// reaches the disk at the next `maintain`.
    public func pay(root: String, value: UInt256) {
        ledger.pay(root: root, value: value, now: now())
        dirty = true
    }

    public func status(_ root: String) -> Status {
        Status(root: root, bytes: ledger.bytes(of: root), credit: ledger.credit(of: root, now: now()),
               held: ledger.isHeld(root))
    }

    /// Hold the group `root` names: pinned only once its credit is above
    /// zero, so work naming the root comes first. A Volume the node holds is
    /// pinned by CID; one it does not, with the entries given or else read
    /// with the node's `GET /fetch`, checked against their CIDs by the
    /// node's `POST /pins`. Every Volume's bytes are the node's: those it
    /// checked and stored, or for one it held, read back with `GET /fetch`;
    /// never the uploader's word.
    public func store(root: String, volumes: [StorageNode.Volume]) async throws -> Status {
        guard volumes.allSatisfy({ CIDIdentity.isCanonical($0.cid) }) else {
            throw SponsorRefusal.draft("a Volume's CID is not canonical")
        }
        guard volumes.contains(where: { $0.cid == root }), Set(volumes.map(\.cid)).count == volumes.count else {
            throw SponsorRefusal.draft("volumes lists each Volume once, the root among them")
        }
        guard reconciled else { throw SponsorRefusal.busy }
        // Only a funded root waits its turn; checked again once it comes.
        if ledger.isHeld(root) { return status(root) }
        guard ledger.credit(of: root, now: now()) > 0 else { throw SponsorRefusal.unfunded }
        guard storing.insert(root).inserted else { throw SponsorRefusal.busy }
        defer { storing.remove(root) }
        await lock()
        defer { unlock() }
        if ledger.isHeld(root) { return status(root) }
        guard ledger.credit(of: root, now: now()) > 0 else { throw SponsorRefusal.unfunded }
        do {
            let pinned = try await pins()
            var sizes: [String: Int] = [:]
            // A Volume the node pins that this sponsor did not claim is the
            // operator's: used, never claimed. One the operator pins after
            // this read and before the pin below is claimed: the node's pins
            // name no owner. Claims are on disk before any pin lands.
            let toPin = volumes.filter { !pinned.contains($0.cid) || ledger.state.claimed.contains($0.cid) }
            for volume in toPin { ledger.claim(volume.cid) }
            dirty = true
            save()
            for volume in volumes {
                if pinned.contains(volume.cid), let known = ledger.size(of: volume.cid) {
                    sizes[volume.cid] = known
                    continue
                }
                var entries: [String: Data]?
                if toPin.contains(where: { $0.cid == volume.cid }) {
                    entries = try await fromNode {
                        try await node.pin(volume.cid) {
                            if let entries = volume.entries { return entries }
                            return try await node.fetch(volume.cid)
                        }
                    }
                }
                if entries == nil {
                    // The node holds it: a read it cannot serve now is its
                    // load, not the Volume's absence.
                    do {
                        entries = try await fromNode { try await node.fetch(volume.cid) }
                    } catch SponsorRefusal.volumeUnavailable {
                        throw SponsorRefusal.busy
                    }
                }
                sizes[volume.cid] = entries!.values.reduce(0) { $0 + $1.count }
                guard sizes.values.reduce(0, +) <= ledger.largestGroup else { throw SponsorRefusal.groupTooBig }
            }
            let evict = try ledger.plan(root: root, volumes: sizes, pinned: pinned, now: now())
            ledger.hold(root: root, volumes: sizes)
            ledger.drop(evict)
            dirty = true
        } catch {
            // What this store claimed and no held group uses is unpinned.
            await unpinOrphans()
            save()
            throw error
        }
        await unpinOrphans()
        save()
        return status(root)
    }

    /// Match the ledger to the node's pins once, then drop expired credit,
    /// unpin what no held group uses, and keep the ledger on disk. Runs
    /// every few seconds.
    public func maintain() async {
        guard !pinning else { return }
        await lock()
        defer { unlock() }
        if !reconciled {
            do {
                let pinned = try await pins()
                ledger.reconcile(pinned: pinned, now: now())
                reconciled = true
                dirty = true
            } catch {
                print("storage reconcile failed: \(error)")
                save()
                return
            }
        }
        let credits = ledger.state.credits.count
        ledger.prune(now: now())
        if ledger.state.credits.count != credits { dirty = true }
        await unpinOrphans()
        save()
    }

    /// The node's pins. An empty answer while this sponsor holds claims is
    /// taken as the node's failure (it answers an unreadable store as no
    /// pins): taken at its word, the sponsor would claim the operator's pins,
    /// or forget its own.
    private func pins() async throws -> Set<String> {
        let pinned = try await fromNode { try await node.pins() }
        guard !pinned.isEmpty || ledger.state.claimed.isEmpty else {
            print("the node answers no pins while this sponsor claims some")
            throw SponsorRefusal.busy
        }
        return pinned
    }

    private func lock() async {
        if pinning {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            pinning = true
        }
    }

    /// Hand the turn to the next store waiting, if any.
    private func unlock() {
        if waiting.isEmpty {
            pinning = false
        } else {
            waiting.removeFirst().resume()
        }
    }

    /// Unpin each claimed Volume no held group uses; one the node does not
    /// unpin stays claimed, for the next pass, and holds up no other.
    private func unpinOrphans() async {
        for volume in ledger.orphans {
            do {
                try await node.unpin(volume)
                ledger.unclaim(volume)
                dirty = true
            } catch {
                print("unpin \(volume) failed: \(error)")
            }
        }
    }

    private func save() {
        guard dirty else { return }
        do {
            try ledger.save(to: file)
            dirty = false
        } catch {
            print("storage state save failed: \(error)")
        }
    }

    /// A node answer other than a refusal of what was given is the node's:
    /// retry shortly.
    private func fromNode<Value: Sendable>(_ body: @Sendable () async throws -> Value) async throws -> Value {
        do {
            return try await body()
        } catch let refusal as SponsorRefusal {
            throw refusal
        } catch {
            print("storage: the node failed: \(error)")
            throw SponsorRefusal.busy
        }
    }
}
