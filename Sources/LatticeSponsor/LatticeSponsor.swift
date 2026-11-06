// lattice-sponsor: pays transaction fees, on any chain the node hosts, for
// clients who pay in proof of work. A client with no balance grinds shares of
// this sponsor's merged block template, then sends a draft; the sponsor adds
// a debit of the fee from its own account on the draft's chain and co-signs.
// The client signs the same body and submits it anywhere: it carries a real
// fee.
//
// The template pays the sponsor on Nexus and every hosted chain, so each
// share earns the sponsor on all of them at once. The client earns on the one
// chain it names: each share is credited when it is accepted, at its own
// template's price there (its chance of clearing that chain's block, times
// that block's reward), and a fee is paid from that chain's credit. Credit
// backed by one block height stops at its reward: only one block per height
// can win.
//
// A client can withhold the shares that are blocks, as against any pool;
// nothing here detects it. The float is the operator's bound on that loss.
// A signed fee is held against the float until the client's nonce on its
// chain passes the transaction's, read as the chain moves, never on a clock:
// the transaction landed, or another took its nonce and it never can. One
// never submitted stays held; its client paid its fee in work, which earns
// the key as much on average. A chain's reward schedule
// is read once, so a chain re-hosted under the same path with a new genesis
// needs a restart.
//
// It runs beside a node and reaches it only over the loopback RPC, like the
// miner. Its key holds the fee float and nothing else: a co-signature lends
// the key's authority to the body, so the key must own nothing a draft could
// reach. Credit is held in memory; a restart forfeits unspent shares.
//
// With --sell-storage, work naming an upload's root as `store` pays for it at
// --storage-rate bytes per coin; once paid, every Volume is pinned on the
// node for good. Unpaid uploads are held in memory for an hour, paid ones until
// pinned, and a restart forfeits them; the roots pinned are kept in --storage-file.
//
// With --pay-to, a transfer to that account, --coin-depth blocks deep, buys
// the same storage at the same rates, claimed once by one of its signers on
// POST /pay; the transfers credited are kept beside --storage-file.
//
// With --serving-rate, work or a transfer naming a `peer` raises that peer's
// standing on the node: each accepted share, and each payment, is posted to
// the node's POST /serving-credit at once, and a failed post loses it.
//
// With --funds, a transfer to the sponsor's own account naming a `fund` (key
// prefixes) adds to that fund's deposit: float a site lends the sponsor. A
// sponsored transaction that names the fund and writes only keys under its
// prefixes is held against the deposit instead of the operator's own float,
// while the fund's holds fit in it, and the signer holds no other transaction
// under it. Nothing is drawn from a deposit: the client still buys the fee
// with work, which repays it. With --funded-only, only such transactions are
// sponsored. Deposits and holds are kept beside --storage-file, and deposits
// cannot be withdrawn yet.
//
// With --payout-at, work naming a `payTo` address earns that address coin
// outright (pay per share): each share's value is owed to the address on its
// chain, and after each template the sponsor pays the addresses owed at least
// --payout-at coins, up to --payout-recipients of them, in one transaction it
// signs alone at its next nonce. A payout is written down before it is sent,
// sent again with each template until one of its versions is --coin-depth
// blocks deep, and given back only once another transaction has held its
// nonce that deep (Payouts.swift). One is pending per chain, and what it can
// debit is kept out of the float sponsored writes draw on. Payout work backs
// at most half of each height's block, leaving the rest for fee work. The
// book is kept in lattice-sponsor-payouts.json beside --storage-file.
//
// Routes (JSON, 64-bit integers as decimal strings, targets and work as hex):
//   POST /work     {client?, chain?, pay?, store?|peer?|payTo?} → a nonce range of the template
//   POST /shares   {assignment, nonce}            → the client's credit on its chain
//   POST /sponsor  {client, transaction, pay?, fund?} → the co-signed transaction
//   POST /store    {root, volumes}                → the upload's status
//   GET  /store/:root                             → {root, bytes, needed, credit, stored}
//   POST /pay      {chain, txCID, signer, signature, store|peer|fund} → {bytes, deposit?}
//   GET  /fund?chain=<path>&prefix=<p>...         → {deposit, held}
//   GET  /earnings?chain=<path>&address=<a>       → {earned, payoutAt, paying} (with --payout-at)
//   GET  /terms                                   → {payTo, depth, storageRates, servingRates, fundTo?, payoutAt?}
//
// A `pay` is coins the sponsor also credits the client in the transaction,
// bought with the same shares as the fee, up to --most-pay (by default, the
// chain's block reward): a client with no coins pays a seller with them.

import ArgumentParser
import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Hummingbird
import Lattice
import cashew
import LatticeMinerCore
import LatticeMiningCoordinator
import LatticeSponsorCore
import UInt256
import LatticeNodeAPI

@main
struct LatticeSponsorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lattice-sponsor",
        abstract: "Pay transaction fees for clients who pay in proof of work."
    )

    @Option(name: .long, help: "The node's loopback RPC base URL (e.g. http://127.0.0.1:8545).")
    var node: String

    @Option(name: .long, help: "The node's RPC cookie file.")
    var cookieFile: String

    @Option(name: .long, help: "Key file (from `lattice key generate`) holding the fee float on every chain, and nothing else.")
    var key: String

    @Option(name: .long, help: "Work per share, as 2^N or a decimal integer.")
    var shareWork: String = "2^24"

    @Option(name: .long, help: "The smallest fee to pay; the node's relay floor when higher.")
    var fee: UInt64 = 0

    @Option(name: .long, help: "The most coins to pay a client within one transaction, for its shares (default: the chain's block reward; 0: fees only).")
    var mostPay: UInt64?

    @Flag(name: .long, help: "Sell storage: work naming an upload's root pins its Volumes on the node for good.")
    var sellStorage = false

    @Option(name: .long, help: "With --sell-storage: the most bytes ever pinned.")
    var storageBudget: Int = 1 << 30

    @Option(name: .long, help: "With --sell-storage: a chain whose work pays for storage, and the bytes one unit of it buys, as chain-path=bytesPerCoin, e.g. Nexus=1024 (repeatable).")
    var storageRate: [String] = []

    @Option(name: .long, help: "With --sell-storage: the JSON file of the roots pinned.")
    var storageFile: String = "lattice-sponsor-storage.json"

    @Option(name: .long, help: "A chain whose work or coin raises a peer's serving standing on the node, and the bytes one unit of it buys, as chain-path=bytesPerCoin (repeatable). Unset: no serving credit.")
    var servingRate: [String] = []

    @Flag(name: .long, help: "Take funds: float a transfer to the sponsor's own account lends it for transactions under a fund's key prefixes.")
    var funds = false

    @Flag(name: .long, help: "With --funds: sponsor only transactions a named fund's deposit backs.")
    var fundedOnly = false

    @Option(name: .long, help: "With --sell-storage or --serving-rate: the account a transfer pays to buy storage or serving in coin, at their rates. Unset: no coin is taken.")
    var payTo: String?

    @Option(name: .long, help: "With --pay-to or --funds: blocks built on the block carrying a transfer before it is credited.")
    var coinDepth: UInt64 = 6

    @Option(name: .long, help: "Pay work naming a payTo address its earnings in coin, once they reach this many coins on a chain. Unset: no payouts.")
    var payoutAt: UInt64?

    @Option(name: .long, help: "With --payout-at: the most addresses paid in one transaction.")
    var payoutRecipients: Int = 64

    @Option(name: .long, help: "With --payout-at: <nonce>@<chain>. Owe again the coins of an unconfirmed payout (settled by its nonce, no version found) because you signed another transaction at that nonce with the sponsor's key. Repeatable; nothing else gives a payout back.")
    var payoutRelease: [String] = []

    @Option(name: .long, help: "Listen address.")
    var host: String = "127.0.0.1"

    @Option(name: .long, help: "Listen port.")
    var port: Int = 8650

    func run() async throws {
        guard let work = parseWork(shareWork), work > .zero, work <= maximumRepresentableWork else {
            throw ValidationError("--share-work takes 2^N (N < 256) or a positive decimal integer")
        }
        guard let base = URL(string: node) else { throw ValidationError("--node is not a URL") }
        let signer = try SponsorKey(file: key)
        let rpc = SponsorRPC(base: base, cookieFile: URL(fileURLWithPath: cookieFile))
        let cookie = URL(fileURLWithPath: cookieFile)
        func parseRates(_ values: [String], flag: String) throws -> [[String]: Int] {
            var rates: [[String]: Int] = [:]
            for value in values {
                let parts = value.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2, let bytesPerCoin = Int(parts[1]), bytesPerCoin > 0 else {
                    throw ValidationError("\(flag) takes chain-path=bytesPerCoin, bytesPerCoin at least 1")
                }
                let chainPath = parts[0].components(separatedBy: "/")
                guard rates[chainPath] == nil else { throw ValidationError("\(flag) names \(parts[0]) twice") }
                rates[chainPath] = bytesPerCoin
            }
            return rates
        }
        var storage: StorageLedger?
        if sellStorage {
            storage = try StorageLedger(
                budget: storageBudget, rates: try parseRates(storageRate, flag: "--storage-rate"),
                file: URL(fileURLWithPath: storageFile)
            )
        }
        let serving = ServingCredit(rates: try parseRates(servingRate, flag: "--serving-rate"))
        let node = SponsorNode(base: base, authorization: { rpcCookieAuthorization(file: cookie) })
        guard !fundedOnly || funds else { throw ValidationError("--funded-only requires --funds") }
        let directory = URL(fileURLWithPath: storageFile).deletingLastPathComponent()
        if let payTo {
            guard sellStorage || !serving.rates.isEmpty else {
                throw ValidationError("--pay-to requires --sell-storage or --serving-rate")
            }
            guard CryptoUtils.isValidAddress(payTo) else { throw ValidationError("--pay-to is not an address") }
        }
        let payments = payTo != nil || funds
            ? try PaymentLedger(file: directory.appendingPathComponent("lattice-sponsor-payments.json")) : nil
        let fundLedger = funds ? try FundLedger(file: directory.appendingPathComponent("lattice-sponsor-funds.json")) : nil
        var ledger = SponsorLedger(shareTarget: minimumWorkTarget(work))
        // A fee signed before a restart can still land, against a fund too.
        if let payoutAt {
            guard payoutAt > 0, payoutRecipients > 0 else {
                throw ValidationError("--payout-at and --payout-recipients take at least 1")
            }
        }
        // Payouts spend the float too: what sponsored writes hold of it must
        // survive a restart, or a payout could spend it.
        if funds || payoutAt != nil {
            try ledger.keepHolds(in: directory.appendingPathComponent("lattice-sponsor-holds.json"))
        }
        var book = payoutAt == nil ? nil : try PayoutBook(file: directory.appendingPathComponent("lattice-sponsor-payouts.json"))
        for release in payoutRelease {
            let parts = release.split(separator: "@", maxSplits: 1).map(String.init)
            guard book != nil, parts.count == 2, let nonce = UInt64(parts[0]) else {
                throw ValidationError("--payout-release takes <nonce>@<chain>, with --payout-at")
            }
            guard try book!.release(on: parts[1].components(separatedBy: "/"), nonce: nonce) else {
                throw ValidationError("no unconfirmed payout at nonce \(nonce) on \(parts[1])")
            }
            print("released the payout at nonce \(nonce) on \(parts[1]): its coins are owed again")
        }
        for payout in book?.unconfirmed ?? [] {
            print("unconfirmed payout at nonce \(payout.nonce) on \(payout.chain): settled by its nonce, no version found")
        }
        let sponsor = Sponsor(
            ledger: ledger,
            rpc: rpc,
            key: signer,
            minimumFee: fee,
            mostPay: mostPay,
            tokenKey: SymmetricKey(size: .bits256),
            storage: storage,
            serving: serving,
            pinNode: node,
            payTo: payTo,
            coinDepth: coinDepth,
            payments: payments,
            funds: fundLedger,
            fundedOnly: fundedOnly,
            payoutAt: payoutAt,
            payoutRecipients: payoutRecipients,
            book: book
        )
        let templates = HTTPMiningCoordinatorNodeClient(
            apiBaseURL: base, cookieFile: URL(fileURLWithPath: cookieFile)
        )
        // A template on each change the node reports, never on a clock.
        let address = signer.address
        let feed = Task {
            await followTemplates(
                events: { rpc.events() },
                fetch: {
                    // Hosted chains come and go without a restart.
                    let chains = [DEFAULT_ROOT_DIRECTORY] + (try await rpc.hostedChains())
                    return try await rpc.template(try MiningTemplateRequestBody.make(
                        recipients: chains.map { "\($0)=\(address)" }, minimumWork: []
                    ))
                },
                install: { await sponsor.install($0, fresh: $1) },
                blind: { await sponsor.blind() }
            )
        }
        defer { feed.cancel() }

        let router = Router()
        // Wallets call this from web pages. No cookie or credential rides on
        // these requests: a client's token is in its body.
        router.add(middleware: CORSMiddleware(allowOrigin: .all, allowMethods: [.get, .post, .options]))
        router.post("work") { request, context in
            let input = try await request.decode(as: WorkRequest.self, context: context)
            return try await refusing {
                try await sponsor.work(
                    client: input.client, chainPath: input.chainPath, pay: input.pay ?? 0,
                    store: input.store, peer: input.peer, payTo: input.payTo
                )
            }
        }
        router.post("shares") { request, context in
            let input = try await request.decode(as: ShareRequest.self, context: context)
            let (response, block, held) = await sponsor.share(assignment: input.assignment, nonce: input.nonce)
            if let block {
                do {
                    let submitted = try await templates.submit(workId: block, nonce: input.nonce)
                    print("block \(block) nonce \(input.nonce): \(submitted.disposition)")
                    if submitted.disposition == "unknownWork" || submitted.disposition == "stale" {
                        await sponsor.retire(workID: block)
                    }
                } catch {
                    print("block \(block) nonce \(input.nonce) not sent: \(error)")
                }
            }
            // Pinning reads and writes every Volume: neither the block nor
            // the share's answer waits for it.
            if let store = held?.store { Task { await sponsor.pinIfPaid(store) } }
            return try await refusing {
                let answer = try response.get()
                if let peer = held?.peer { try await node.creditServing(peer: peer, bytes: Int(answer.serving ?? 0)) }
                return answer
            }
        }
        router.post("sponsor") { request, context in
            let input = try await request.decode(as: SponsorRequest.self, context: context)
            return try await refusing {
                try await sponsor.sponsor(
                    client: input.client, draft: input.transaction.body, pay: input.pay ?? 0, fund: input.fund
                )
            }
        }
        if funds {
            router.get("fund") { request, _ in
                let query = request.uri.queryParameters
                return try await refusing {
                    try await sponsor.fund(
                        chainPath: (query.get("chain") ?? DEFAULT_ROOT_DIRECTORY).components(separatedBy: "/"),
                        prefixes: query.getAll("prefix")
                    )
                }
            }
        }
        if sellStorage {
            router.post("store") { request, _ in
                let body = try await request.body.collect(upTo: 64 << 20)
                guard let input = try? JSONDecoder().decode(StoreRequest.self, from: body) else {
                    throw HTTPError(.badRequest, message: "not a store request")
                }
                return try await refusing { try await sponsor.upload(root: input.root, volumes: input.volumes) }
            }
            router.get("store/:root") { _, context in
                let root = try context.parameters.require("root")
                await sponsor.pinIfPaid(root)
                guard let status = await sponsor.storeStatus(root) else {
                    throw HTTPError(.notFound, message: "\(SponsorRefusal.unknownUpload)")
                }
                return status
            }
        }
        router.get("terms") { _, _ in await sponsor.terms() }
        if payoutAt != nil {
            router.get("earnings") { request, _ in
                let query = request.uri.queryParameters
                return try await refusing {
                    try await sponsor.earnings(
                        of: query.get("address") ?? "",
                        on: (query.get("chain") ?? DEFAULT_ROOT_DIRECTORY).components(separatedBy: "/")
                    )
                }
            }
        }
        if payments != nil {
            router.post("pay") { request, context in
                let input = try await request.decode(as: CoinPayment.self, context: context)
                return try await refusing { try await sponsor.pay(input) }
            }
        }
        print("sponsor \(signer.address) listening on \(host):\(port)")
        let app = Application(
            responder: router.buildResponder(),
            configuration: .init(address: .hostname(host, port: port))
        )
        try await app.runService()
    }
}

struct WorkRequest: Decodable {
    let client: String?
    /// The chain the shares are credited on and the fee is quoted on
    /// (default Nexus).
    let chain: String?
    /// Coins the sponsor is to pay the client as well; `sharesForFee` then
    /// buys both.
    @OptionalDecimalString var pay: UInt64?
    /// An upload's root: its shares pay for storing it (with --sell-storage;
    /// ignored without).
    let store: String?
    /// A peer's key, instead of `store`: its shares raise its serving
    /// standing on the node.
    let peer: String?
    /// An address, instead of a fee, `store` or `peer`: its shares earn it
    /// coin, paid out by the sponsor (with --payout-at).
    let payTo: String?

    var chainPath: [String] {
        (chain ?? DEFAULT_ROOT_DIRECTORY).components(separatedBy: "/")
    }
}

struct WorkResponse: ResponseEncodable {
    let client: String
    let assignment: String
    let prefixHex: String
    let shareTarget: String
    @DecimalString var startNonce: UInt64
    @DecimalString var count: UInt64
    /// The quoted chain's fee.
    @DecimalString var fee: UInt64
    /// What the sponsor pays the client as well, as asked.
    @DecimalString var pay: UInt64
    /// Shares that buy `fee` and `pay` at the current price, saturating
    /// (zero, with `fee` and `pay`, for storage or serving work).
    @DecimalString var sharesForFee: UInt64
    /// Not a deadline: work stays valid until the chain's tip moves (a
    /// share on retired work is refused, and the client asks again), since
    /// proof-of-work arrivals are memoryless. Wallets require the field and
    /// ask for new work when it runs out, so it carries a long constant.
    @DecimalString var expiresInMilliseconds: UInt64

    static let askAgainMilliseconds: UInt64 = 3_600_000
}

struct ShareRequest: Decodable {
    let assignment: String
    @DecimalString var nonce: UInt64
}

struct ShareResponse: ResponseEncodable {
    /// The client's credit on the assignment's chain, in whole units; for
    /// payout work, the address's earnings there not yet paid.
    @DecimalString var credit: UInt64
    /// For serving work, the bytes of standing the share bought.
    @OptionalDecimalString var serving: UInt64?
}

struct StoreRequest: Decodable {
    let root: String
    /// Every Volume of the file, root included.
    let volumes: [StoreVolume]
}

struct StoreResponse: ResponseEncodable {
    let root: String
    @DecimalString var bytes: UInt64
    /// The coins still needed on each chain with a storage rate.
    let needed: [String: String]
    /// The bytes paid.
    @DecimalString var credit: UInt64
    let stored: Bool

    init(_ status: StoreStatus) {
        root = status.root
        bytes = UInt64(status.bytes)
        needed = status.needed.mapValues { String($0) }
        credit = UInt64(status.credit)
        stored = status.stored
    }
}

struct PayResponse: ResponseEncodable {
    /// The bytes of storage or serving standing the transfer bought (none
    /// for a fund).
    @DecimalString var bytes: UInt64
    /// For a fund, its deposit after the transfer.
    @OptionalDecimalString var deposit: UInt64? = nil
}

struct FundResponse: ResponseEncodable {
    /// The coins deposited, never drawn.
    @DecimalString var deposit: UInt64
    /// What the fund backs now: fees and pays signed under it whose signer's
    /// nonce has not passed them. Room for more is `deposit - held`.
    @DecimalString var held: UInt64
}

extension SponsorTerms: ResponseEncodable {}

struct EarningsResponse: ResponseEncodable {
    /// The address's earnings on the chain not yet paid out, in whole units.
    @DecimalString var earned: UInt64
    /// The earnings at which the sponsor pays them out.
    @DecimalString var payoutAt: UInt64
    /// Whether a payout to this address is in flight on the chain.
    let paying: Bool
}

struct SponsorRequest: Decodable {
    let client: String
    /// The draft: one signer (the client), no signatures needed.
    let transaction: ContentBoundTransaction
    /// Coins the sponsor credits the client within the transaction.
    @OptionalDecimalString var pay: UInt64?
    /// The prefixes of a fund whose deposit backs the transaction, with
    /// --funds.
    let fund: [String]?
}

struct SponsorResponse: ResponseEncodable {
    /// The sponsored body with the sponsor's signature; the client adds its
    /// own over the same body and submits.
    let transaction: ContentBoundTransaction
    @DecimalString var fee: UInt64
    @DecimalString var pay: UInt64
}

actor Sponsor {
    private var ledger: SponsorLedger
    private let rpc: SponsorRPC
    private let key: SponsorKey
    private let minimumFee: UInt64
    /// Nil: the block reward of the chain paid on.
    private let mostPay: UInt64?
    /// Signs the client tokens this sponsor issues, so a client cannot name
    /// (and so spend) a token it was not given.
    private let tokenKey: SymmetricKey
    /// Each chain's reward schedule, read once.
    private var specs: [[String]: ChainSpec] = [:]
    /// Each chain's fee and the sponsor's balance there, read with every
    /// template so a request reads nothing from the node.
    private var fees: [[String]: UInt64] = [:]
    private var balances: [[String]: UInt64] = [:]
    /// Uploads and the roots pinned, with --sell-storage.
    private var storage: StorageLedger?
    private let serving: ServingCredit
    private let pinNode: SponsorNode
    /// The account coin is paid to, with --pay-to, and the transfers credited.
    private let payTo: String?
    private let coinDepth: UInt64
    private var payments: PaymentLedger?
    /// The funds, with --funds.
    private var funds: FundLedger?
    private let fundedOnly: Bool
    /// With --payout-at: the coins at which an address's earnings are paid,
    /// the most addresses in one payout, and each chain's payout in flight,
    /// sent again until the sponsor's nonce passes it.
    private let payoutAt: UInt64?
    private let payoutRecipients: Int
    private var book: PayoutBook?
    /// A payout pass is running: one at a time, so a payout begins once.
    private var payingOut = false

    init(
        ledger: SponsorLedger, rpc: SponsorRPC, key: SponsorKey, minimumFee: UInt64, mostPay: UInt64?,
        tokenKey: SymmetricKey, storage: StorageLedger?, serving: ServingCredit,
        pinNode: SponsorNode, payTo: String?, coinDepth: UInt64, payments: PaymentLedger?,
        funds: FundLedger?, fundedOnly: Bool, payoutAt: UInt64? = nil, payoutRecipients: Int = 64,
        book: PayoutBook? = nil
    ) {
        self.book = book
        self.payoutAt = payoutAt
        self.payoutRecipients = payoutRecipients
        self.ledger = ledger
        self.rpc = rpc
        self.key = key
        self.minimumFee = minimumFee
        self.mostPay = mostPay
        self.tokenKey = tokenKey
        self.storage = storage
        self.serving = serving
        self.pinNode = pinNode
        self.payTo = payTo
        self.coinDepth = coinDepth
        self.payments = payments
        self.funds = funds
        self.fundedOnly = fundedOnly
    }

    /// Take `template` as the newest work, priced on every chain whose block
    /// it carries pays this sponsor. A chain whose spec or fee cannot be read
    /// is left unpriced. `fresh`: the first since connecting to the node.
    func install(_ template: MiningTemplateResponse, fresh: Bool) async {
        // Holds end as their signers' nonces pass them. Read before the
        // balances: a fee that lands between the two reads is then counted
        // twice until the next template, never not at all.
        var nextNonces: [SponsorLedger.Holder: UInt64] = [:]
        for holder in ledger.holders {
            nextNonces[holder] = try? await rpc.nextNonce(of: holder.signer, on: holder.chainPath)
        }
        var prices: [[String]: ChainPrice] = [:]
        for chain in template.chains ?? [] where chain.rewardRecipient == key.address {
            if specs[chain.chainPath] == nil {
                specs[chain.chainPath] = try? await rpc.spec(chain.chainPath)
            }
            guard let spec = specs[chain.chainPath],
                  let floor = try? await rpc.relayFloor(on: chain.chainPath),
                  let balance = try? await rpc.balance(of: key.address, on: chain.chainPath) else { continue }
            fees[chain.chainPath] = max(minimumFee, floor)
            balances[chain.chainPath] = balance
            prices[chain.chainPath] = ChainPrice(
                // The node takes no hash above the search target.
                target: min(chain.target, template.searchTarget),
                height: chain.height,
                reward: spec.rewardAtBlock(chain.height)
            )
        }
        if template.chains == nil { print("the node reports no template chains; upgrade it") }
        ledger.install(SponsorTemplate(
            workID: template.workID,
            prefixHex: ProofOfWork.proofOfWorkHashPrefixBytes(template.block)
                .map { String(format: "%02x", $0) }.joined(),
            prices: prices,
            submitTarget: template.searchTarget,
            parent: template.block.parent?.rawCID ?? ""
        ), fresh: fresh, now: now())
        do {
            try ledger.release(nextNonces: nextNonces)
        } catch {
            print("releasing holds failed: \(error)")
        }
        if book != nil {
            do { try book!.save() } catch { print("saving the payout book failed: \(error)") }
            Task { await self.payOut() }
        }
    }

    /// One pass over the chains with a payout pending or due: settle, give
    /// back or send again the pending one, else begin the next. Runs after
    /// each template, never on a clock, and one pass at a time.
    func payOut() async {
        guard let payoutAt, let book, !payingOut else { return }
        payingOut = true
        defer { payingOut = false }
        for chainPath in Set(book.pendingChains + book.dueChains(threshold: payoutAt)) {
            do {
                try await payOut(on: chainPath, threshold: payoutAt)
            } catch {
                print("payout on \(chainPath.joined(separator: "/")): \(error)")
            }
        }
    }

    private func payOut(on chainPath: [String], threshold: UInt64) async throws {
        let chain = chainPath.joined(separator: "/")
        // Unpriced (no template carries it): its fee and balance are unknown.
        guard let fee = fees[chainPath], fee > 0, let balance = balances[chainPath] else { return }
        let tip = try await pinNode.tipHeight(on: chainPath)
        let nonce = try await rpc.nextNonce(of: key.address, on: chainPath) ?? 0
        if let payout = book!.pending(on: chainPath) {
            var deepest: (cid: String, depth: UInt64)?
            for version in payout.versions {
                if let depth = try await pinNode.depth(of: version.cid, on: chainPath, tipHeight: tip),
                   depth >= deepest?.depth ?? 0 {
                    deepest = (version.cid, depth)
                }
            }
            switch try book!.observe(on: chainPath, nextNonce: nonce, tipHeight: tip, included: deepest, depth: coinDepth) {
            case .settled(let cid):
                print("payout \(cid) on \(chain) settled: \(payout.coins) to \(payout.recipients.count)")
            case .settledByNonce:
                print("WARNING: the sponsor's nonce on \(chain) passed payout nonce \(payout.nonce) \(coinDepth) blocks ago and the node shows none of its versions (\(payout.versions.map(\.cid).joined(separator: ", "))); taken as paid. If you signed another transaction at that nonce with the sponsor's key, restart with --payout-release \(payout.nonce)@\(chain) to owe its coins again.")
            case .pending:
                // Included and not yet deep, or its nonce taken: nothing to send.
                guard deepest == nil, nonce <= payout.nonce else { return }
                var latest = payout.versions.last!
                // The node's fee floor rose past it: a replacement at the same
                // nonce paying the same coins, which the pool takes for paying
                // at least a floor more. Only one version can land.
                if fee > latest.fee {
                    let raised = latest.fee + fee
                    let others = ledger.held(on: chainPath)
                    if balance >= others, balance - others >= payout.coins + raised {
                        latest = try sign(payout.recipients, fee: raised, nonce: payout.nonce, on: chainPath)
                        try book!.replace(on: chainPath, with: latest)
                    }
                }
                // A refusal (already pooled, say) proves nothing; the chain decides.
                do { try await pinNode.submit(latest.transaction) } catch {}
            }
            return
        }
        // Nothing pending: the next payout, from the float sponsored fees
        // don't hold.
        let others = ledger.held(on: chainPath)
        guard balance > others, balance - others > fee else { return }
        let recipients = book!.due(
            on: chainPath, threshold: threshold, maxRecipients: payoutRecipients, room: balance - others - fee
        )
        guard !recipients.isEmpty else { return }
        let version = try sign(recipients, fee: fee, nonce: nonce, on: chainPath)
        // Written down before it is sent: from here only the chain settles it.
        try book!.begin(on: chainPath, nonce: nonce, recipients: recipients, version: version)
        // Tests only: die between writing a payout down and sending it.
        if ProcessInfo.processInfo.environment["LATTICE_SPONSOR_TEST_EXIT_BEFORE_SEND"] == "1" {
            print("test: exiting with payout \(version.cid) written down and not sent")
            exit(3)
        }
        let coins = recipients.reduce(UInt64(0)) { $0 + $1.amount }
        do {
            try await pinNode.submit(version.transaction)
            print("paying \(coins) to \(recipients.count) on \(chain) at nonce \(nonce): \(version.cid)")
        } catch {
            print("payout \(version.cid) on \(chain) not taken yet (\(error)); sent again with the next template")
        }
    }

    /// One signed version of a payout.
    private func sign(
        _ recipients: [PayoutBook.Recipient], fee: UInt64, nonce: UInt64, on chainPath: [String]
    ) throws -> PayoutBook.Version {
        let body = payoutBody(recipients: recipients, sponsor: key.address, fee: fee, nonce: nonce, chainPath: chainPath)
        let header = try HeaderImpl(node: body)
        guard let signature = TransactionSigning.sign(bodyHeader: header, privateKeyHex: key.privateKey) else {
            throw HTTPError(.internalServerError, message: "signing failed")
        }
        let transaction = ContentBoundTransaction(signatures: [key.publicKey: signature], body: body)
        let cid = try VolumeImpl<Transaction>(node: try transaction.transaction()).rawCID
        return PayoutBook.Version(cid: cid, fee: fee, transaction: transaction)
    }

    func earnings(of address: String, on chainPath: [String]) throws -> EarningsResponse {
        guard let payoutAt, let book else { throw SponsorRefusal.noPayouts }
        guard CryptoUtils.isValidAddress(address) else { throw SponsorRefusal.draft("not an address") }
        let units = book.earnings(of: address, on: chainPath) / SponsorLedger.unit
        return EarningsResponse(
            earned: units > UInt256(UInt64.max) ? .max : UInt64(units.words[0]), payoutAt: payoutAt,
            paying: book.pending(on: chainPath)?.recipients.contains { $0.address == address } ?? false
        )
    }

    /// The node's work is unknown: no new work or price until a template.
    func blind() {
        ledger.blind()
    }

    /// The node refused a block on `workID` as work it no longer holds.
    func retire(workID: String) {
        ledger.retire(workID: workID)
    }

    func work(
        client: String?, chainPath: [String], pay: UInt64, store: String?, peer: String?, payTo: String? = nil
    ) throws -> WorkResponse {
        var fee: UInt64 = 0
        var shares = UInt256.zero
        if let payTo {
            guard payoutAt != nil else { throw SponsorRefusal.noPayouts }
            guard store == nil, peer == nil, pay == 0 else {
                throw SponsorRefusal.draft("payout work pays nothing else")
            }
            guard CryptoUtils.isValidAddress(payTo), payTo != key.address else {
                throw SponsorRefusal.draft("payTo is not an address")
            }
        }
        try ServingCredit.check(peer: peer, store: store)
        // Without --sell-storage, a store is ignored: the work is fee work.
        let store = storage == nil ? nil : store
        if peer != nil {
            guard pay == 0 else { throw SponsorRefusal.draft("serving work pays nothing else") }
            _ = try serving.rate(on: chainPath)
        } else if let store {
            guard pay == 0 else { throw SponsorRefusal.draft("storage work pays nothing else") }
            try storage!.check(root: store, on: chainPath, now: now())
        } else if payTo == nil {
            fee = try currentFee(chainPath)
        }
        let total = try charge(fee: fee, pay: pay, on: chainPath)
        let client = try client.map { token in
            guard isIssued(token) else { throw SponsorRefusal.draft("unknown client token") }
            return token
        } ?? issueToken()
        let assignment = try ledger.assign(client: client, on: chainPath, store: store, peer: peer, payTo: payTo)
        if store == nil, peer == nil, payTo == nil {
            shares = ledger.sharesFor(fee: total, on: chainPath) ?? .max
        }
        return WorkResponse(
            client: client,
            assignment: assignment.id,
            prefixHex: assignment.prefixHex,
            shareTarget: assignment.shareTarget.toHexString(),
            startNonce: assignment.startNonce,
            count: assignment.count,
            fee: fee,
            pay: pay,
            sharesForFee: shares > UInt256(UInt64.max) ? .max : UInt64(shares.words[0]),
            expiresInMilliseconds: WorkResponse.askAgainMilliseconds
        )
    }

    /// Credit a share, and name the template it is a block of, if any,
    /// whether or not it was credited, and its assignment.
    func share(assignment: String, nonce: UInt64) -> (Result<ShareResponse, any Error>, String?, ShareAssignment?) {
        guard let held = ledger.assignment(assignment), let prefix = Data(hex: held.prefixHex) else {
            return (.failure(SponsorRefusal.unknownAssignment), nil, nil)
        }
        let hash = ProofOfWork.hash(
            midstate: ProofOfWork.midstate(prefixBytes: ContiguousArray(prefix)), nonce: nonce
        )
        let credited = Result { () throws -> ShareResponse in
            // An upload no longer held is refused before the share is spent.
            if let store = held.store {
                guard let storage else { throw SponsorRefusal.unknownUpload }
                try storage.check(root: store, on: held.chainPath, now: now())
            }
            let value = try ledger.credit(assignment: assignment, nonce: nonce, hash: hash, now: now())
            if let payTo = held.payTo { book?.earn(value, to: payTo, on: held.chainPath) }
            if let store = held.store {
                try storage!.credit(root: store, value: value, on: held.chainPath, now: now())
            }
            let units = (held.payTo.map { book?.earnings(of: $0, on: held.chainPath) ?? .zero }
                ?? ledger.credit(of: held.client, on: held.chainPath)) / SponsorLedger.unit
            return ShareResponse(
                credit: units > UInt256(UInt64.max) ? .max : UInt64(units.words[0]),
                serving: try held.peer.map { _ in UInt64(try serving.bytes(for: value, on: held.chainPath)) }
            )
        }
        return (credited, ledger.block(assignment: assignment, nonce: nonce, hash: hash), held)
    }

    func upload(root: String, volumes: [StoreVolume]) throws -> StoreResponse {
        guard storage != nil else { throw SponsorRefusal.unknownUpload }
        return StoreResponse(try storage!.upload(root: root, volumes: volumes, now: now()))
    }

    func storeStatus(_ root: String) -> StoreResponse? {
        storage?.status(of: root).map(StoreResponse.init)
    }

    /// Pin `root`'s Volumes once it is paid in full, and record it as
    /// stored; on a failure it stays held, to be pinned at its next share or
    /// status read.
    func pinIfPaid(_ root: String) async {
        guard let upload = storage?.takePaid(root) else { return }
        var pinned = false
        do {
            try await pinNode.pin(upload)
            pinned = true
        } catch {
            print("pinning \(root) failed: \(error)")
        }
        do {
            try storage?.finish(root, pinned: pinned)
        } catch {
            print("recording \(root) as stored failed: \(error)")
        }
    }

    func sponsor(client: String, draft: TransactionBody, pay: UInt64, fund: [String]?) throws -> SponsorResponse {
        let chainPath = draft.chainPath
        let fee = try currentFee(chainPath)
        let total = try charge(fee: fee, pay: pay, on: chainPath)
        // Decided and committed with no await between, so the fund's room
        // checked is the room held.
        let backer: FundID? = if let funds {
            try funds.backer(
                for: draft, fund: fund, total: total, ledger: ledger, fundedOnly: fundedOnly
            )
        } else {
            nil
        }
        let body = try sponsoredBody(
            draft: draft, sponsor: key.address, fee: fee, pay: pay, chainPath: chainPath
        )
        // A signed fee shows in the balance only once mined; hold it until
        // the client's nonce passes it.
        // A pending payout's coins are spoken for.
        let balance = balances[chainPath] ?? 0, reserved = book?.reserved(on: chainPath) ?? 0
        try ledger.commit(
            client: client, fee: total, on: chainPath, signer: body.signers[0], nonce: body.nonce,
            balance: balance > reserved ? balance - reserved : 0, fund: backer
        )
        let header = try HeaderImpl(node: body)
        guard let signature = TransactionSigning.sign(bodyHeader: header, privateKeyHex: key.privateKey) else {
            throw HTTPError(.internalServerError, message: "signing failed")
        }
        return SponsorResponse(
            transaction: ContentBoundTransaction(signatures: [key.publicKey: signature], body: body),
            fee: fee,
            pay: pay
        )
    }

    /// Credit a transfer to `payTo` once, as storage for an upload held with
    /// --sell-storage, or as a peer's serving standing; or a transfer to the
    /// sponsor's own account, to a fund.
    func pay(_ payment: CoinPayment) async throws -> PayResponse {
        guard let payTo = payment.recipient(payTo: payTo, sponsor: key.address), payments != nil else {
            throw SponsorRefusal.noPayment
        }
        let chainPath = payment.chainPath
        // Refused before reading the node, and again after, since an upload
        // can expire meanwhile. Returns the chain's rate.
        func check(at now: Int64) throws -> Int {
            if let fund = payment.fund {
                guard funds != nil else { throw SponsorRefusal.noFunds }
                _ = try FundLedger.normalize(fund)
                return 0
            }
            if payment.peer != nil { return try serving.rate(on: chainPath) }
            guard let storage, let store = payment.store else { throw SponsorRefusal.unknownUpload }
            try storage.check(root: store, on: chainPath, now: now)
            return try storage.rate(on: chainPath)
        }
        _ = try check(at: now())
        try payments!.claim(payment.txCID)
        do {
            let coins = try await pinNode.verify(payment, payTo: payTo, depth: coinDepth)
            // One instant, so the credit below cannot fail once checked.
            let at = now()
            let rate = try check(at: at)
            try payments!.release(payment.txCID, credit: true)
            if let fund = payment.fund {
                let deposit = try funds!.credit(FundID(try FundLedger.normalize(fund), on: chainPath), coins: coins)
                return PayResponse(bytes: 0, deposit: deposit)
            }
            let value = UInt256(coins) * SponsorLedger.unit
            if let peer = payment.peer {
                // Credited above: a failed post loses the payment.
                let bytes = try serving.bytes(for: value, on: chainPath)
                try await pinNode.creditServing(peer: peer, bytes: bytes)
                return PayResponse(bytes: UInt64(bytes))
            }
            let store = payment.store!
            try storage!.credit(root: store, value: value, on: chainPath, now: at)
            Task { await pinIfPaid(store) }
            let (bytes, overflow) = coins.multipliedReportingOverflow(by: UInt64(rate))
            return PayResponse(bytes: overflow ? .max : bytes)
        } catch {
            try? payments!.release(payment.txCID, credit: false)
            throw error
        }
    }

    func terms() -> SponsorTerms {
        SponsorTerms(
            payTo: payTo, depth: coinDepth, storageRates: storage?.rates ?? [:], servingRates: serving.rates,
            fundTo: funds == nil ? nil : key.address, payoutAt: payoutAt
        )
    }

    func fund(chainPath: [String], prefixes: [String]) throws -> FundResponse {
        guard let funds else { throw SponsorRefusal.noFunds }
        let id = FundID(try FundLedger.normalize(prefixes), on: chainPath)
        let held = ledger.held(by: id)
        return FundResponse(
            deposit: funds.deposit(of: id), held: held > UInt256(UInt64.max) ? .max : UInt64(held.words[0])
        )
    }

    /// What the sponsor spends for a fee and a payment, within --most-pay.
    private func charge(fee: UInt64, pay: UInt64, on chainPath: [String]) throws -> UInt64 {
        let most = mostPay ?? ledger.latest?.prices[chainPath]?.reward ?? 0
        guard pay <= most else {
            throw SponsorRefusal.draft("this sponsor pays at most \(most) within a transaction")
        }
        let (total, overflow) = fee.addingReportingOverflow(pay)
        guard !overflow else { throw SponsorRefusal.draft("pay out of range") }
        return total
    }

    private func currentFee(_ chainPath: [String]) throws -> UInt64 {
        guard let latest = ledger.latest,
              latest.prices[chainPath] != nil, let fee = fees[chainPath] else {
            throw SponsorRefusal.unpriceable
        }
        guard fee > 0 else {
            throw HTTPError(.conflict, message: "the node admits zero-fee transactions; no sponsor needed")
        }
        return fee
    }


    /// A random identifier and its MAC under `tokenKey`, in hex: 16 bytes
    /// then 32.
    private func issueToken() -> String {
        let identifier = (0..<16).map { _ in UInt8.random(in: .min ... .max) }
        return Self.hex(identifier) + Self.hex(Array(mac(identifier)))
    }

    private func isIssued(_ token: String) -> Bool {
        guard let bytes = Data(hex: token), bytes.count == 16 + 32 else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            Array(bytes.suffix(32)), authenticating: Array(bytes.prefix(16)), using: tokenKey
        )
    }

    private func mac(_ identifier: [UInt8]) -> HashedAuthenticationCode<SHA256> {
        HMAC<SHA256>.authenticationCode(for: identifier, using: tokenKey)
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// Milliseconds since the epoch.
private func now() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000)
}

/// A refusal as the client's 4xx; anything else propagates.
func refusing<Value: Sendable>(_ body: () async throws -> Value) async throws -> Value {
    do {
        return try await body()
    } catch let refusal as SponsorRefusal {
        let status: HTTPResponse.Status = switch refusal {
        case .busy, .unpriceable, .insufficientFloat, .soldOut: .serviceUnavailable
        case .noPayouts: .notFound
        case .insufficientCredit, .notFunded: .init(code: 402, reasonPhrase: "Payment Required")
        case .notIncluded: .notFound
        case .notDeepEnough: .init(code: 425, reasonPhrase: "Too Early")
        case .alreadyCredited, .inFlight: .conflict
        case .servingNotCredited: .badGateway
        default: .badRequest
        }
        throw HTTPError(status, message: "\(refusal)")
    }
}

struct SponsorKey: Sendable {
    let address: String
    let publicKey: String
    let privateKey: String

    init(file path: String) throws {
        struct KeyFile: Decodable {
            let privateKey: String
            let publicKey: String
        }
        let url = URL(fileURLWithPath: path)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let permissions = attributes[.posixPermissions] as? NSNumber,
           permissions.intValue & 0o077 != 0 {
            throw ValidationError("key file \(url.path) is group/other-readable; chmod 600 it")
        }
        let file = try JSONDecoder().decode(KeyFile.self, from: Data(contentsOf: url))
        address = CryptoUtils.createAddress(from: file.publicKey)
        publicKey = file.publicKey
        privateKey = file.privateKey
    }
}

/// The node reads the sponsor needs, over the loopback RPC.
struct SponsorRPC: Sendable {
    let base: URL
    let cookieFile: URL

    /// The child chains the node hosts, as absolute paths.
    func hostedChains() async throws -> [String] {
        struct Hosted: Decodable { let chains: [String] }
        let hosted: Hosted = try await get("hosted-chains", on: [DEFAULT_ROOT_DIRECTORY])
        return hosted.chains
    }

    /// A merged template, or nil while the node has none to give.
    func template(_ body: Data) async throws -> MiningTemplateResponse? {
        var request = authorized(base.appendingPathComponent("mining/templates"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 409 || status == 503 {
            print("the node gave no template (\(status)): \(String(decoding: data, as: UTF8.self))")
            return nil
        }
        guard status == 200 else { throw RPCFailure.status(status) }
        return try JSONDecoder().decode(MiningTemplateResponse.self, from: data)
    }

    /// `GET /mining/events`: the node's digest on connect and whenever a
    /// hosted chain's tip or pool, or the hosted set, changes, until the
    /// connection ends.
    func events() -> AsyncThrowingStream<Void, any Error> {
        var request = authorized(base.appendingPathComponent("mining/events"))
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // The node writes a keepalive comment every 15 s: a connection
        // silent for longer is dead, whatever the chain does.
        request.timeoutInterval = 60
        // Only the newest change matters: a backlog would hold a new tip
        // behind changes already superseded.
        return changes { continuation in
            let delegate = EventStreamDelegate(
                event: { continuation.yield() },
                finished: { continuation.finish(throwing: $0) }
            )
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            session.dataTask(with: request).resume()
            continuation.onTermination = { _ in session.invalidateAndCancel() }
        }
    }

    func spec(_ chainPath: [String]) async throws -> ChainSpec {
        let spec: ExplorerChainSpec = try await get("api/chain/spec", on: chainPath)
        // Only the reward schedule is read from it (`rewardAtBlock`); the
        // explorer view omits the state-growth bound and policies.
        return ChainSpec(
            maxNumberOfTransactionsPerBlock: spec.maxNumberOfTransactionsPerBlock,
            maxStateGrowth: 0,
            maxBlockSize: spec.maxBlockSize,
            premine: spec.premine,
            targetBlockTime: spec.targetBlockTime,
            initialReward: spec.initialReward,
            halvingInterval: spec.halvingInterval,
            halfLife: spec.halfLife
        )
    }

    func relayFloor(on chainPath: [String]) async throws -> UInt64 {
        let fees: ExplorerFees = try await get("api/fees", on: chainPath)
        return fees.minRelayFee
    }

    /// The nonce `address`'s next transaction on `chainPath` must carry, as
    /// of its tip; nil when the node reads no account (never transacted, or
    /// no tip yet), which releases nothing.
    func nextNonce(of address: String, on chainPath: [String]) async throws -> UInt64? {
        do {
            let account: ExplorerAccount = try await get("api/state/account/\(address)", on: chainPath)
            return account.nonce
        } catch RPCFailure.notFound {
            return nil
        }
    }

    func balance(of address: String, on chainPath: [String]) async throws -> UInt64 {
        do {
            let account: ExplorerAccount = try await get("api/state/account/\(address)", on: chainPath)
            return account.balance
        } catch RPCFailure.notFound {
            return 0
        }
    }

    enum RPCFailure: Error {
        case notFound
        case status(Int)
    }

    private func authorized(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let authorization = rpcCookieAuthorization(file: cookieFile) {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func get<Value: Decodable>(_ path: String, on chainPath: [String]) async throws -> Value {
        var url = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if chainPath != [DEFAULT_ROOT_DIRECTORY] {
            url?.queryItems = [URLQueryItem(name: "chainPath", value: chainPath.joined(separator: "/"))]
        }
        guard let resolved = url?.url else { throw RPCFailure.status(0) }
        let request = authorized(resolved)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { throw RPCFailure.notFound }
        guard status == 200 else { throw RPCFailure.status(status) }
        return try JSONDecoder().decode(Value.self, from: data)
    }
}

/// A `text/event-stream` response's events, as URLSession delivers its
/// bytes (corelibs Foundation streams through a data delegate on Linux too).
private final class EventStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let event: @Sendable () -> Void
    private let finished: @Sendable ((any Error)?) -> Void
    private let lock = NSLock()
    private var counter = ServerSentEventCounter()

    init(event: @escaping @Sendable () -> Void, finished: @escaping @Sendable ((any Error)?) -> Void) {
        self.event = event
        self.finished = finished
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            // 404: the node has no `GET /mining/events`; it must be upgraded.
            finished(SponsorRPC.RPCFailure.status(status))
            return completionHandler(.cancel)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let events = counter.feed(data)
        lock.unlock()
        if events > 0 { event() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        finished(error)
        session.finishTasksAndInvalidate()
    }
}

/// `2^N` or a positive decimal integer.
func parseWork(_ text: String) -> UInt256? {
    if text.hasPrefix("2^") {
        guard let exponent = Int(text.dropFirst(2)), (0..<256).contains(exponent) else { return nil }
        return UInt256(1) << exponent
    }
    return UInt64(text).map { UInt256($0) }
}
