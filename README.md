# lattice-sponsor

Pays Lattice transaction fees for clients who pay in proof of work.

A client with no balance grinds shares of the sponsor's merged block template,
then sends a draft transaction. The sponsor adds a debit of the fee from its
own account on the draft's chain and co-signs. The client signs the same body
and submits it to any node: it carries a real fee.

The template pays the sponsor on Nexus and every chain the node hosts, so each
share earns the sponsor on all of them at once. The client earns on the one
chain it names. Each share is credited when it is accepted, at its template's
price on that chain: its chance of clearing that chain's block, times that
block's reward. A fee is paid from that chain's credit. Credit backed by one
block height stops at that block's reward, since only one block per height can
win.

## Running it

It runs beside a node and reaches it only over the node's loopback RPC, as a
miner does.

```sh
lattice-sponsor \
  --node http://127.0.0.1:8080 \
  --cookie-file ~/.lattice/chains/Nexus/.cookie \
  --key sponsor.key \
  --port 8650
```

- `--key` is a `lattice key generate` key file. It holds the fee float on every
  chain, **and nothing else**: a co-signature lends the key's authority to the
  body, so the key must own nothing a draft could reach.
- `--share-work` (default `2^24`) is the work per share.
- `--fee` is the smallest fee it pays; the node's relay floor applies when that
  is higher.
- `--most-pay` is the most coins it pays a client within one transaction, for
  that client's shares. With it, a client with no coins can pay someone else:
  buying a name, say. It defaults to the chain's block reward at the
  template's height; at 0 it pays fees only.

- `--sell-serving` lets work buy serving balance on the node instead of fee
  credit (see [Serving credit](#serving-credit)).
- `--sell-storage` lets work buy pin space on the node (see
  [Storage](#storage)), within `--storage-budget` bytes (default 1 GiB), at
  most `--storage-largest-group` bytes a group (16 MiB), with credit halving
  every `--storage-half-life` seconds (a week) and `POST /store` bodies of at
  most `--storage-largest-upload` bytes (32 MiB). Its state is kept in
  `--storage-state` (`sponsor-storage.json`).

Credit is held in memory, so a restart forfeits unspent shares, and serving
bytes not yet posted to the node; storage credit is kept on disk. A chain's
reward schedule is read once, so a chain re-hosted under the same path with a
new genesis needs a restart.

The image `ghcr.io/0xlattice/lattice-sponsor` holds the binary at
`/usr/local/bin/lattice-sponsor`, for a node image to copy in
(`COPY --from=ghcr.io/0xlattice/lattice-sponsor:<tag> ...`) or to run beside
one.

## Routes

JSON; 64-bit integers are decimal strings, and targets and work are hex.

| Route | Body | Returns |
|---|---|---|
| `POST /work` | `{client?, chain?, pay?, peer?, store?}` | a nonce range of the template, and the shares that buy the fee and `pay` |
| `POST /shares` | `{assignment, nonce}` | the client's credit on its chain, and for serving work the peer's `bytes` not yet posted |
| `POST /sponsor` | `{client, transaction, pay?}` | the co-signed transaction |
| `POST /store` | `{root, volumes: [{cid, entries?}]}` | `{root, bytes, credit, held}` once the group is held |
| `GET /store/:root` | | `{root, bytes, credit, held}` |

With a `pay`, the sponsor credits the client `pay` within the transaction, and
debits itself the fee plus `pay`. The client's own debits net against that
credit, so a purchase of exactly `pay` draws nothing from the client's
balance.

## Serving credit

A node holding a chain's data serves it free while it is not busy. Under load,
its operator may serve first the readers who paid, in coin or in work; work
paid here buys that priority, never access itself.

With `--sell-serving`, a reader advertises its Ivy peer ID as `peer` on
`POST /work`. Its shares on that assignment are valued as for a fee, in the
chain's smallest unit, then multiplied by the node's `bytesPerCoin` for the
chain (from its `GET /serving-terms`), rounded down. At each refresh the
sponsor posts each peer's whole bytes to the node's `POST /serving-balance`,
with the RPC cookie. A chain the node sets no rate for is refused
(`noServingRate`); without the flag a `peer` is ignored and the work is fee
work. Bytes the node does not take (it is down, failing or refusing the
sponsor) stay owed and are posted later; a peer the node refuses (400, 422)
is dropped.
A post whose answer is lost, though the node applied it, is posted again, so
the peer may be credited twice. Under a byte stays owed for an hour after the
peer's last share.

Serving work is not fee credit and pays no `pay`. The caps above apply to it
as to fee work, and so does block withholding: a reader can withhold the
shares that are blocks, and its credit then buys serving instead of fees.

## Storage

A storage sponsor sells pin space on its node for work that mines real
blocks. Anyone can run one, and an uploader can use several for redundancy.
Nothing on chain expires; a host only stops keeping a file. Uploaders trust
hosts for availability only: bytes are checked by CID. A browser app can
upload bytes without running a node.

A group is named by its root CID and is exactly the Volumes its uploader
lists, root included; the sponsor reads no file format. Work comes first:
`POST /work` with `store: <root>` (on Nexus) credits each accepted share's
value, as for a fee, to that root. Then `POST /store` gives each Volume with
its `entries` (CID to base64 bytes, as the node's `POST /pins` takes) or by
`cid` only. A Volume the node holds is pinned by CID; one it does not is
pinned with the bytes given, or else read with the node's `GET /fetch`, and
the node's `POST /pins` checks every entry against its CID. A Volume it
refuses is `badVolume`, and nothing of the group stays pinned. A group's
bytes are the node's, read back with `GET /fetch`. A root with no credit is
`unfunded`. Stores run one at a time, in turn.

Credit halves every half-life, and paying again for a held group raises it.
Held groups are ranked by credit per byte: one that does not fit the budget
unpins the lowest-ranked groups, and one that would have to unpin a group
ranked above it is `outranked`. A group over the largest group is
`groupTooBig`, and one over the whole budget is `neverFits`. Credit for a
root not held lapses an hour after its last share.

The sponsor unpins only Volumes it pinned itself, once no group it holds uses
them. A Volume the node already pinned is the operator's: a group may use it,
it costs the budget nothing, and it is never unpinned. Groups, credit and the
Volumes claimed are kept in one JSON file, written whole and renamed, with up
to a few seconds of credit unwritten; at start the file is matched to the
node's pins, and a group missing a Volume is dropped. Storage credit buys no
fee or serving. The node's operator routes take bodies of 2 MiB, so a Volume
the node does not hold must fit one (`volumeTooBig`). The node's pins name no
owner: one the operator adds after the sponsor pinned the same Volume is the
sponsor's to unpin.

## What it risks

A client can withhold the shares that are blocks, as against any pool, and
nothing here detects it. Its credit then buys fees, and with `--most-pay`,
coins paid to the client itself: up to the fee plus `--most-pay` (by default a
block reward) per transaction, from the key's balance, which also holds the
blocks the sponsor wins. The float is the operator's bound on that loss; set
`--most-pay 0` to keep it to fees.

A signed fee and pay are held against the float for a few of the chain's
blocks, but a client may submit its body later than that. The sponsor never
pays more than one fee and pay per signature, so the cost is another client's
sponsored transaction failing on an empty float.

## Development

It builds on lattice-node's `LatticeNodeAPI`, `LatticeMinerCore` and
`LatticeMiningCoordinator` libraries, pinned to one commit in `Package.swift`.
`Package.resolved` keeps the node's own pins for everything they share.

```sh
swift build
swift test
```

CI also runs lattice-node's sponsor end-to-end tests against the pinned node,
with this build as `E2E_SPONSOR_BIN`.

## License

MIT
