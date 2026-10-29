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

Credit is held in memory, so a restart forfeits unspent shares, and serving
bytes not yet posted to the node. A chain's
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
| `POST /work` | `{client?, chain?, pay?, peer?}` | a nonce range of the template, and the shares that buy the fee and `pay` |
| `POST /shares` | `{assignment, nonce}` | the client's credit on its chain, and for serving work the peer's `bytes` not yet posted |
| `POST /sponsor` | `{client, transaction, pay?}` | the co-signed transaction |

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
(`noServingRate`), and without the flag a `peer` is refused (`noServing`).
Bytes the node does not take while it is down (or failing, 5xx) stay owed
and are posted at a later refresh; a peer the node refuses (4xx) is dropped.
A post whose answer is lost, though the node applied it, is posted again, so
the peer may be credited twice. Under a byte stays owed for an hour after the
peer's last share.

Serving work is not fee credit and pays no `pay`. The caps above apply to it
as to fee work, and so does block withholding: a reader can withhold the
shares that are blocks, and its credit then buys serving instead of fees.

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
