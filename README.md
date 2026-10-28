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

Credit is held in memory, so a restart forfeits unspent shares. A chain's
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
| `POST /work` | `{client?, chain?, pay?}` | a nonce range of the template, and the shares that buy the fee and `pay` |
| `POST /shares` | `{assignment, nonce}` | the client's credit on its chain |
| `POST /sponsor` | `{client, transaction, pay?}` | the co-signed transaction |

With a `pay`, the sponsor credits the client `pay` within the transaction, and
debits itself the fee plus `pay`. The client's own debits net against that
credit, so a purchase of exactly `pay` draws nothing from the client's
balance.

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
