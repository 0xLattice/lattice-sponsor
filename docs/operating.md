# Operating lattice-sponsor

How to run a sponsor in production: its flags, what it needs from the node,
the files it keeps, how to supervise and monitor it, and how to take a file
down. To get one running first, see the
[quickstart](../README.md#quickstart). What running one exposes you to is in
[Operator risks](risks.md).

## Install

Each [release](https://github.com/0xLattice/lattice-sponsor/releases)
carries `lattice-sponsor-<version>-linux-amd64.tar.gz` and
`-macos-arm64.tar.gz`, each with a `.sha256`; the binary is
`bin/lattice-sponsor` inside.

On Linux the binary needs these system libraries, the same ones the node's
own container image installs:

```sh
apt-get install -y --no-install-recommends ca-certificates libatomic1 libcurl4 libsqlite3-0 libxml2
```

The image `ghcr.io/0xlattice/lattice-sponsor` holds the binary at
`/usr/local/bin/lattice-sponsor`, as its entrypoint. Copy it into a node
image (`COPY --from=ghcr.io/0xlattice/lattice-sponsor:<tag> ...`) or run it
beside one.

## Flags

All configuration is flags. There is no configuration file.

### Required

| Flag | Meaning |
|---|---|
| `--node <url>` | The base URL of the node's operator API, such as `http://127.0.0.1:8080`. |
| `--cookie-file <path>` | The node's cookie file. Read again for every request, since the node writes a new one at every start. |
| `--key <path>` | A key file from `lattice key generate`. It holds the float on every chain and nothing else ([Operator risks](risks.md#the-key)). A file that its group or others can read is refused: `chmod 600` it. |

### Listener

| Flag | Default | Meaning |
|---|---|---|
| `--host <address>` | `127.0.0.1` | The listen address. |
| `--port <port>` | `8650` | The listen port. |

It serves plain HTTP, and every answer carries
`Access-Control-Allow-Origin: *` so that web pages can call it.
`POST /takedown` is on the same listener as the client routes, guarded by
the node's cookie.

### Fees

| Flag | Default | Meaning |
|---|---|---|
| `--share-work <work>` | `2^24` | The work per share, as `2^N` (N under 256) or a positive decimal integer. |
| `--fee <coins>` | `0` | The smallest fee it pays. The node's relay floor applies when that is higher. |
| `--most-pay <coins>` | the chain's block reward at the template's height | The most coins it pays a client within one transaction, for that client's shares ([`pay`](api.md#post-sponsor)). At `0` it pays fees only. |

### Optional services

Each of these is off until its flag is set. What clients do with them is in
the [HTTP API](api.md).

| Flag | Default | Meaning |
|---|---|---|
| `--sell-storage` | off | Work buys a pin for a file on the node, kept until you take it down ([Takedowns](#take-a-file-down)). |
| `--storage-rate <chain>=<bytesPerCoin>` | none | With `--sell-storage`: a chain whose work pays for storage, and the bytes one coin of it buys, such as `Nexus=1024`. At least 1. Repeatable, once per chain. |
| `--storage-budget <bytes>` | `1073741824` (1 GiB) | With `--sell-storage`: the most bytes pinned at once, uploads not yet pinned included. A takedown frees its bytes. |
| `--storage-file <path>` | `lattice-sponsor-storage.json` | With `--sell-storage`: the JSON file of the roots pinned. Its directory holds every other [state file](#state). |
| `--serving-rate <chain>=<bytesPerCoin>` | none | Work or coin on that chain raises a peer's serving standing on the node, at this many bytes per coin. Repeatable, once per chain. |
| `--pay-to <address>` | none | Coin sent to this address buys storage or serving at the same rates. Needs `--sell-storage` or `--serving-rate`; alone, it only publishes the address as `payTo` in `GET /terms`. |
| `--funds` | off | Sites may lend the sponsor float for transactions under their key prefixes ([Funds](api.md#funds)). |
| `--funded-only` | off | With `--funds` (required): sponsor only transactions a named fund's deposit backs, so you put up no float of your own. |
| `--coin-depth <blocks>` | `6` | Blocks built on the block carrying a transfer before it is credited, and before a payout settles. |
| `--payout-at <coins>` | none | Work naming a `payTo` address is paid out in coin once it has earned this many coins on a chain ([Payouts](#payouts)). At least 1. |
| `--payout-recipients <n>` | `64` | With `--payout-at`: the most addresses paid in one transaction. At least 1. |
| `--payout-release <nonce>@<chain>` | none | With `--payout-at`: owe again the coins of an unconfirmed payout ([Payouts](#payouts)). Repeatable. |

A serving standing is the node's byte balance for a peer, which decides its
share of serving slots when the node is busy
([HTTP API](https://lattice.build/docs/build/http-api/#serving-standing)).

### Environment

The sponsor reads no environment variables for configuration.
`LATTICE_SPONSOR_TEST_EXIT_BEFORE_SEND=1` is for its tests only: it makes the
process exit with status 3 after writing a payout down and before sending
it. Never set it.

## What it needs from the node

The sponsor reaches the node only over the node's operator API, as a miner
does. It sends the cookie file's content as `Authorization: Basic`, and
selects a child chain with `?chainPath=<path>`
([HTTP API: Authentication](https://lattice.build/docs/build/http-api/#authentication)).

| Needed for | Node routes |
|---|---|
| Always | `GET /mining/events`, `POST /mining/templates`, `POST /mining/work`, `GET /hosted-chains`, `GET /api/chain/spec`, `GET /api/fees`, `GET /api/state/account/{address}` |
| `--sell-storage` | `POST /pins`, `GET /fetch/{cid}`, `DELETE /pins/{cid}` |
| `--serving-rate` | `POST /serving-credit` |
| `--pay-to`, `--funds`, `--payout-at` | `GET /api/transaction/{cid}`, `GET /api/block/latest`, `GET /api/block/{height}`, `GET /transactions/{cid}` |
| `--payout-at` | `POST /transactions` |

- **Events.** The node must serve `GET /mining/events`. Against a node
  without it, the sponsor logs the failure and keeps retrying.
- **History.** To credit a coin transfer, the node must keep every state and
  block body (`--state all --block-bodies all`, or `state` and `blockBodies`
  in `lattice.json`; see
  [Running in production](https://lattice.build/docs/run/operations/)).
- **Hosted chains.** The sponsor asks for a template that pays its key on
  Nexus and every chain the node hosts. Chains come and go without a
  restart of the sponsor. A chain's reward schedule is read once, so a chain
  hosted again under the same path with a new genesis needs a restart.
- **Zero fees.** When the node's relay floor and `--fee` are both zero on a
  chain, the sponsor refuses to sponsor there (409): no sponsor is needed.

### How it follows the node

The sponsor asks for a template whenever the node reports a change (a hosted
chain's tip or pool, or the hosted set), never on a clock. Proof-of-work
arrivals are memoryless, so work stays valid until a template on a new tip
replaces it.

When the event stream ends or fails, or the node has no template to give:

1. The sponsor stops handing out work and prices (`unpriceable`). Work
   already handed out keeps its credit, and its blocks still go to the node.
2. It connects again after 250 ms, doubling to 5 s, and back to 250 ms once
   a template arrives.
3. The first template on a new connection drops all earlier work, since the
   node may have restarted and lost what it handed out. Clients see
   `unknownAssignment` and ask for work again.

## State

### On disk

Every file is JSON, in the directory of `--storage-file` (by default the
working directory), read at start if it exists and replaced atomically on
each change.

| File | Written with | Holds |
|---|---|---|
| `lattice-sponsor-storage.json` (`--storage-file`) | `--sell-storage` | The roots pinned, with their bytes and Volumes. It counts the budget across restarts. |
| `lattice-sponsor-blocklist.json` | `--sell-storage` | The CIDs taken down, mode 0600. |
| `lattice-sponsor-payments.json` | `--pay-to` or `--funds` | The transfers already credited, so each is credited once. |
| `lattice-sponsor-funds.json` | `--funds` | Each fund's deposit. |
| `lattice-sponsor-holds.json` | `--funds` or `--payout-at` | Every fee signed and still held against the float. |
| `lattice-sponsor-payouts.json` | `--payout-at` | Earnings owed, the payout pending on each chain, and unconfirmed payouts. Earnings are written with each template; a payout before it is first sent. |

`--storage-file` holds only roots, bytes and Volumes, and the blocklist only
CIDs. No file holds an uploader's address or identity.

### In memory

A restart forfeits:

- clients' unspent fee credit, their work, and their client tokens;
- uploads not yet pinned, paid or not, with their credit;
- without `--funds` or `--payout-at`, the fees held against the float.

Fee credit also lapses one hour after the client's last share. An upload not
yet paid is held for one hour, and a paid one until it is pinned.

## Supervise it

The sponsor runs in the foreground and logs to standard output. It has no
unit file of its own. A supervisor has to respect these:

- **Working directory.** `--storage-file` defaults to a relative path, and
  the other state files sit beside it. Fix the working directory, or give an
  absolute `--storage-file`.
- **Files it must read.** The node's cookie file, and the key file, which
  must be mode 0600.
- **Start order.** It can start before the node. It retries until the node
  answers, and reads the cookie again each time, so a node restart needs no
  sponsor restart.
- **Restarts are not free.** Each one forfeits what is
  [in memory](#in-memory).
- **`--payout-release` is a one-time flag.** A start naming a payout that is
  not unconfirmed fails, so remove the flag once it has run.
- **Containers.** The node's operator API binds loopback only, so the
  sponsor has to share the node's network namespace: copy the binary into
  the node's image, or run its container on the node's network. The default
  `--host` is loopback too.

A systemd unit along these lines runs it beside the node's own unit
([Deployment](https://lattice.build/docs/run/deployment/)). It assumes that
unit's user and root:

```ini
[Unit]
Description=lattice-sponsor
After=lattice-node.service

[Service]
User=lattice
WorkingDirectory=/var/lib/lattice-sponsor
ExecStart=/usr/local/bin/lattice-sponsor \
  --node http://127.0.0.1:8080 \
  --cookie-file /var/lib/lattice/chains/Nexus/.cookie \
  --key /var/lib/lattice-sponsor/sponsor.key
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

The sponsor ends at start, with the reason, when a flag does not check: a
`--share-work`, rate or `--payout-release` it cannot read, a chain named
twice in a rate, `--pay-to` that is not an address, `--funded-only` without
`--funds`, or a key file others can read.

## Monitor it

The sponsor has no health or metrics route. Watch these instead:

| What | How |
|---|---|
| It is up | `GET /terms` answers without reading the node. |
| It follows the node | The log. `template feed: <error>`, `the node's events ended` and `the node gave no template (<status>)` each mean it hands out no work until the next template. |
| The float | The key's balance on each chain: the node's `GET /api/state/account/<address>`, with `address` from `GET /terms`. Clients see `insufficientFloat` when it no longer covers the fees held. |
| Blocks won | `block <work> nonce <n>: <disposition>` for each share that was a block, or `... not sent: <error>`. |
| Storage room | `storage` in `GET /terms`: `{budget, stored, held}` in bytes. Room is `budget - stored - held`. |
| Pins | `pinned <root>: <bytes> bytes in <n> Volumes`, or `pinning <root> failed: <error>`. A failed pin is tried again at the upload's next share or status read. |
| Funds | `GET /fund?chain=<path>&prefix=<p>` answers a fund's `{deposit, held}`. |
| Payouts | `paying <coins> to <n> on <chain> at nonce <n>: <cid>`, then `payout <cid> on <chain> settled`. A line starting `WARNING:` or `unconfirmed payout` needs you ([Payouts](#payouts)). |
| State files | `releasing holds failed`, `saving the payout book failed` and `recording <root> as stored failed` mean a file could not be written. |

`the node reports no template chains; upgrade it` means the node is too old
to price work.

The log names each upload pinned (root, bytes, Volumes) and each takedown
(the CID and the Volumes unpinned). It names no uploader. Logs of who
connected are your own proxy's.

## Float and holds

The float is the key's balance on a chain. A fee the sponsor signs shows in
that balance only once the transaction is mined, so each signed fee (and
`pay`) is held against the float until then.

- A hold lasts until the client's nonce on the chain passes the
  transaction's: it landed, or another transaction took its nonce and it
  never can. A transaction never submitted stays held.
- The sponsor reads the nonces whenever the node reports a change, never on
  a clock.
- A new fee is refused (`insufficientFloat`) when the balance, less a pending
  payout, does not cover every hold on the chain.
- With `--funds`, a hold may count against a site's deposit as well
  ([Funds](api.md#funds)). The key's whole balance must still cover every
  hold.

## Take a file down

The sponsor does not look at what it pins: anyone who pays can upload
anything, and your node then serves it ([Operator risks](risks.md#storage)).
`POST /takedown` removes a file and keeps it from coming back.

```sh
curl -s --user "$(cat <root>/chains/Nexus/.cookie)" \
  -H 'Content-Type: application/json' \
  -d '{"cid": "<cid>"}' http://127.0.0.1:8650/takedown
```

`cid` is an upload's root, or one of its Volumes. The credential is the
node's cookie, sent as for the node's own operator routes:
`Authorization: Basic <base64 of the --cookie-file's content>`.

| Answer | Meaning |
|---|---|
| 200 `{cid, unpinned}` | Blocked. `unpinned` lists the Volumes unpinned on the node. |
| 401 | The cookie is missing or wrong. |
| 404 | The sponsor runs without `--sell-storage`. |
| 400 | `cid` is not a CID. |
| 502 `notUnpinned` | The CID is blocked, but the node refused an unpin. Ask again. |

A takedown does three things:

1. **Blocks** the CID for good, with the root and every Volume of each
   upload naming it, pinned or not, in `lattice-sponsor-blocklist.json`.
   - An upload naming a blocked CID as its root or a Volume is refused
     (`blocked`, 451) on `POST /store`. So is work or coin for it on
     `POST /work`, `POST /shares` and `POST /pay`. A new manifest listing the
     same chunks cannot pin them again.
   - A Volume the file shares with an innocuous one is blocked too: a later
     upload of that other file is refused, though one already pinned keeps
     it.
2. **Unpins**, with the node's `DELETE /pins/:cid`, every Volume of the
   pinned uploads naming the CID, and of those it tried to pin before and
   failed, that no other upload keeps (pinned or being pinned). The node
   then releases them as it does any unpinned Volume.
   - A Volume the node does not hold (404) is already released.
   - It unpins only Volumes of its own uploads, never a pin it did not make.
   - An upload naming the CID and not yet pinned is dropped. One being
     pinned is unpinned once it is.
3. **Returns** their bytes to `--storage-budget`.

**Paid time is not refunded.** Work or coin spent on an upload taken down,
pinned or not, is forfeited: the sponsor holds no refund float, and refunding
would pay whoever uploaded what had to be removed.

To unblock a CID, remove it from the blocklist file and restart.

## Payouts

With `--payout-at <coins>`, the sponsor is also a pay-per-share pool: work
naming a `payTo` address is owed to that address
([HTTP API](api.md#payouts)).

After each template, the sponsor pays the addresses owed at least
`--payout-at` coins on a chain:

- up to `--payout-recipients` of them, largest first;
- whole coins (the fraction stays owed);
- in one transaction it signs alone, at its next nonce on that chain;
- only while the payout fits the float that sponsored fees do not hold.
  One that does not fit waits until it does.

One payout is pending per chain, and what it can debit is kept out of the
float that sponsored fees draw on. Payout work backs at most half of each
height's block, so fee work, which a person is waiting on, always has the
other half.

### How a payout settles

A payout moves coin that must be paid once, so it is judged by the chain,
never by what a send answered:

- It is written to `lattice-sponsor-payouts.json`, with its coins taken off
  what is owed, before it is first sent. A failed send or a crash loses
  nothing: it is sent again with each template.
- The sponsor signs nothing else as first signer, and nothing else at a
  payout's nonce but a replacement paying the same coins to the same
  addresses (when the node's fee floor rises past its fee). Whichever version
  lands, each address is paid once.
- It settles once a version is `--coin-depth` blocks deep in the canonical
  chain, or once the sponsor's nonce has been past it that long even if the
  node shows no version: the nonce moving proves one landed. That payout is
  kept as unconfirmed and logged with a warning.
- Its coins are never owed again on the sponsor's own judgement.

### Release an unconfirmed payout

Do not sign transactions with the sponsor's key elsewhere: one that takes a
pending payout's nonce leaves that payout unconfirmed and unpaid.

If you did sign another transaction at that nonce, restart once with
`--payout-release <nonce>@<chain>` to owe its coins again. The warning in
the log names the nonce and chain, and each start lists the unconfirmed
payouts. Nothing else gives a payout back.
