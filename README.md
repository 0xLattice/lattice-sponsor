# lattice-sponsor

lattice-sponsor is a service that pays Lattice transaction fees for clients
who pay in proof of work. An operator runs it beside a
[Lattice node](https://lattice.build/docs/run/getting-started/); wallets and
web pages call it over HTTP.

It is for:

- **Operators** who want people with no coins to be able to transact on the
  chains their node hosts.
- **Client developers** whose users have no balance to pay a fee with.

## How it works

1. The sponsor hands a client a nonce range of its node's merged block
   template. The client grinds it and sends back shares: nonces whose hash
   clears an easier target than a block's.
2. Each accepted share is credited on the one chain the client names, at the
   template's price there: its chance of clearing that chain's block, times
   that block's reward.
3. The client sends a draft transaction. The sponsor adds a debit of the fee
   from its own account on the draft's chain and co-signs.
4. The client signs the same body and submits it to any node. It carries a
   real fee.

The template pays the sponsor on Nexus and every chain the node hosts, so
each share earns the sponsor on all of them at once. A share that clears a
block's target is that block, and the sponsor submits it. Credit backed by
one block height stops at that block's reward, since only one block per
height can win.

The same work can also buy a pin for a file, a peer's serving standing on
the node, or coin paid out to an address. An operator turns each on with a
flag ([Optional services](docs/operating.md#optional-services)).

## Quickstart

You need a running node ([Getting started](https://lattice.build/docs/run/getting-started/))
and its `lattice` command-line tool.

1. Get the binary. Each
   [release](https://github.com/0xLattice/lattice-sponsor/releases) carries
   `lattice-sponsor-<version>-linux-amd64.tar.gz` and `-macos-arm64.tar.gz`,
   each with a `.sha256`; the binary is `bin/lattice-sponsor` inside. Or
   build it: `swift build -c release`.

2. Create a key for the sponsor alone:

   ```sh
   lattice key generate --out sponsor.key
   ```

   The key holds the coin fees are paid from (the float) on every chain,
   **and nothing else** ([why](docs/risks.md#the-key)).

3. Start it against the node's operator port, with the node's cookie file:

   ```sh
   lattice-sponsor \
     --node http://127.0.0.1:8080 \
     --cookie-file ~/.lattice/chains/Nexus/.cookie \
     --key sponsor.key \
     --port 8650
   ```

   It prints `sponsor <address> listening on 127.0.0.1:8650`.

4. Send coin to that address on each chain it is to pay fees on. A fee it
   cannot cover is refused (`insufficientFloat`).

5. Check that it answers:

   ```sh
   curl -s http://127.0.0.1:8650/terms
   ```

## Documentation

| Page | For | Holds |
|---|---|---|
| [Operating lattice-sponsor](docs/operating.md) | Operators | Every flag, what it needs from the node, the files it keeps, supervision, monitoring, takedowns. |
| [lattice-sponsor HTTP API](docs/api.md) | Client developers | Each route, its fields and refusals, the proof-of-work and signature formats. |
| [lattice-sponsor operator risks](docs/risks.md) | Anyone deciding whether to run or trust one | What the operator's coin and node are exposed to, and the limits that bound it. |

The TypeScript client is `SponsorClient` in
[`@adalin/lattice-relay`](https://github.com/0xLattice/lattice-sdk/tree/main/packages/relay).

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
