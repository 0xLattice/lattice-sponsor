# lattice-sponsor HTTP API

The routes a client calls on a sponsor: what each takes, what it answers,
how it refuses, and the exact proof-of-work and signature formats. The
TypeScript client is `SponsorClient` in
[`@adalin/lattice-relay`](https://github.com/0xLattice/lattice-sdk/tree/main/packages/relay).

## Conventions

- Requests and answers are JSON.
- A 64-bit integer is a canonical decimal string (`"0"`, `"1500"`), never a
  JSON number. The tables below mark these fields *integer*. Rates in
  `GET /terms` and a Volume's `bytes` are JSON numbers, marked *number*.
- Targets are hex.
- A chain is named by its path, such as `Nexus` or `Nexus/Alpha`. Where
  `chain` is optional it defaults to `Nexus`.
- A coin is the chain's smallest unit.
- Every answer, a refusal included, carries `Access-Control-Allow-Origin: *`,
  so a web page can read it. No cookie or credential rides on a client's
  request: its token is in the body.

## Routes

| Route | Purpose | Served |
|---|---|---|
| [`POST /work`](#post-work) | A nonce range to grind. | always |
| [`POST /shares`](#post-shares) | Hand in one share. | always |
| [`POST /sponsor`](#post-sponsor) | Have a draft transaction co-signed. | always |
| [`GET /terms`](#get-terms) | What this sponsor sells and at what rates. | always |
| [`POST /store`](#post-store) | Hand over a file to be pinned. | with `--sell-storage` |
| [`GET /store/:root`](#get-storeroot) | An upload's status. | with `--sell-storage` |
| [`POST /pay`](#post-pay) | Claim a coin transfer. | with `--pay-to` or `--funds` |
| [`GET /fund`](#get-fund) | A fund's deposit and what it holds. | with `--funds` |
| [`GET /earnings`](#get-earnings) | What an address is owed. | with `--payout-at` |

A route the sponsor does not serve answers 404. `POST /takedown` is the
operator's ([Operating](operating.md#take-a-file-down)).

## Pay a fee in work

1. `POST /work` with the chain. Keep the `client` token it answers.
2. Grind the range ([Proof of work](#proof-of-work)) and `POST /shares` for
   each share, until `credit` covers `fee` plus `pay`. `sharesForFee`
   estimates how many that takes.
3. When a share is refused as `unknownAssignment` or `expired`, the work is
   spent: `POST /work` again with the same `client` token (its credit is
   kept) and grind the new range.
4. `POST /sponsor` with the token and the draft.
5. Check the body it answers, sign that same body, add your signature to the
   sponsor's, and submit the transaction to any node.

### Proof of work

A share is a nonce in `[startNonce, startNonce + count)` whose hash is at
most `shareTarget`:

```text
hash = SHA-256( prefix ‖ nonce )
```

- `prefix` is the bytes of `prefixHex`: the template's consensus
  proof-of-work preimage prefix.
- `nonce` is 8 bytes, big-endian.
- `hash` and `shareTarget` are compared as 256-bit big-endian integers.

### What a share is worth

A share at share target S, on a chain whose block in the template has target
T and reward R, is worth `R × work(S) / work(T)` coins, rounded down in units
of 2^-64 coin. `work(t)` is the work a target stands for.

- The value is fixed when the share is credited, at the price of the
  template it was ground on, on the one chain its work names.
- All the credit one block height backs, across every client, stops at that
  block's reward (`soldOut`).
- Fee credit lapses one hour after the client's last share, and at a restart
  of the sponsor.

### `POST /work`

Asks for a fresh nonce range of the newest template.

| Request field | Type | Meaning |
|---|---|---|
| `client` | string, optional | The token from an earlier answer, to keep earning on the same credit. Omit it to be issued one. |
| `chain` | string, optional | The chain the shares are credited on and the fee is quoted on. |
| `pay` | integer, optional | Coins the sponsor is to pay the client within the transaction, as well as the fee. |
| `store` | string, optional | An upload's root: the shares pay for [storing it](#store-a-file) instead. Ignored by a sponsor that sells no storage. |
| `peer` | string, optional | A peer's key, 64 lower-case hex: the shares raise its [serving standing](#buy-serving-standing) instead. |
| `payTo` | string, optional | An address: the shares earn it [coin](#payouts) instead. |

`store`, `peer` and `payTo` exclude one another, and none goes with a
`pay`.

| Answer field | Type | Meaning |
|---|---|---|
| `client` | string | The client token. |
| `assignment` | string | Names this range on `POST /shares`. |
| `prefixHex` | hex | The proof-of-work preimage prefix. |
| `shareTarget` | hex | The target a share's hash must not exceed. |
| `startNonce`, `count` | integer | The range. |
| `fee` | integer | The chain's fee now. Zero for storage, serving and payout work. |
| `pay` | integer | As asked. |
| `sharesForFee` | integer | Shares that buy `fee` and `pay` at the current price, saturating. Zero for storage, serving and payout work. |
| `expiresInMilliseconds` | integer | Always `3600000`. Not a deadline: work stays valid until the chain's tip moves. Ask for new work when it runs out. |

A client token is valid only on the sponsor process that issued it. After a
restart of the sponsor, a token is refused as
`draft("unknown client token")`: ask without one.

Refusals: `unpriceable`, `busy`, `soldOut`, `draft(...)`, `noPayouts`,
`noStorageRate`, `noServingRate`, `unknownUpload`, `blocked`. Fee work on a
chain whose fee is zero answers 409: no sponsor is needed there.

### `POST /shares`

Hands in one share.

| Request field | Type | Meaning |
|---|---|---|
| `assignment` | string | From `POST /work`. |
| `nonce` | integer | The share's nonce. |

| Answer field | Type | Meaning |
|---|---|---|
| `credit` | integer | The client's fee credit on the assignment's chain, in whole coins. For payout work, the address's earnings there not yet paid. |
| `serving` | integer, serving work only | The bytes of standing this share bought. |

Refusals: `unknownAssignment`, `expired`, `outsideRange`,
`missesShareTarget`, `duplicateShare`, `soldOut`, `unknownUpload`,
`blocked`, `noStorageRate`, `servingNotCredited`.

### `POST /sponsor`

Co-signs a draft, paid from the client's credit on the draft's chain.

| Request field | Type | Meaning |
|---|---|---|
| `client` | string | The client token. |
| `transaction` | object | `{signatures, body}`: the draft. No signatures are needed; send `{}`. |
| `pay` | integer, optional | Coins the sponsor credits the client within the transaction. |
| `fund` | array of strings, optional | The prefixes of a [fund](#funds) to back the transaction. |

The draft must:

- have exactly one signer, the client, who is not the sponsor;
- not name the sponsor as an account owner, a demander or a withdrawer, or
  inside an action's key or values;
- balance on its own, without the sponsor.

The sponsored body is the draft with these changes and no others:

1. With a `pay` above zero, an account action crediting the client `pay` is
   appended.
2. An account action debiting the sponsor `fee + pay` is appended after it.
3. `signers` becomes `[client, sponsor]`.

The client's own debits net against the `pay` credit, so a purchase of
exactly `pay` draws nothing from the client's balance. The client stays
first signer, so the transaction uses the client's nonce.

| Answer field | Type | Meaning |
|---|---|---|
| `transaction` | object | `{signatures, body}`: the sponsored body, and the sponsor's signature alone, keyed by its public key. |
| `fee` | integer | The fee the sponsor debits itself. |
| `pay` | integer | As asked. |

The fee is the larger of the sponsor's `--fee` and its node's relay floor on
the chain. The sponsor spends `fee + pay` of the client's credit.

Refusals: `unpriceable`, `insufficientCredit`, `insufficientFloat`,
`draft(...)`, and with a fund `notFunded` and `inFlight`. A chain whose fee
is zero answers 409: no sponsor is needed there.

### `GET /terms`

| Answer field | Type | Meaning |
|---|---|---|
| `address` | string | The sponsor key's own address, always. |
| `payTo` | string, with `--pay-to` | The address a coin payment for storage or serving pays. |
| `depth` | integer | Blocks built on a transfer's block before it is credited. |
| `storageRates` | object of *number* | Bytes per coin of storage, by chain path. |
| `servingRates` | object of *number* | Bytes per coin of serving standing, by chain path. |
| `fundTo` | string, with `--funds` | The address a fund's transfer pays: the sponsor's own. |
| `payoutAt` | integer, with `--payout-at` | The coins at which earnings are paid out. |
| `storage` | object, with `--sell-storage` | `{budget, stored, held}` in bytes, each an integer. Room for an upload is `budget - stored - held`. |

## Store a file

A storage sponsor keeps files, for proof of work that mines real blocks,
until its operator takes one down. Anyone can run one, and an uploader can
use several. The uploader trusts the host for availability only: bytes are
checked by CID.

1. `POST /store` with the file's root and every Volume in it.
2. `POST /work` with `store: <root>` on a chain in `storageRates`, and
   `POST /shares` as usual, until the upload's `credit` covers its `bytes`.
3. The sponsor then pins every Volume on its node, which checks each against
   its CID. `GET /store/:root` answers `stored: true` once it has.

Storage credit pays no fee or `pay`. An upload not yet paid is held for one
hour, and a paid one until it is pinned; a restart of the sponsor forfeits
either, with its credit.

A pinned file stays until the operator takes it down. Nothing paid for it is
refunded then, so an uploader who needs the file kept stores it with other
sponsors too.

### `POST /store`

| Request field | Type | Meaning |
|---|---|---|
| `root` | string | The file's root CID. |
| `volumes` | array | Every Volume of the file, the root's included. |
| `volumes[].cid` | string | The Volume's root. |
| `volumes[].entries` | object, optional | CID to base64 bytes, as the node's `POST /pins` takes. It must include the Volume's own root. |
| `volumes[].bytes` | *number*, without `entries` | The Volume's declared size. The sponsor reads it later with the node's `GET /fetch`, and refuses it if it is larger. |

Limits: a Volume is at most 1 MiB and 1 KiB (a 1 MiB chunk of a file and its
block's framing), and the request body at most 64 MiB.

The answer is the upload's status, as [`GET /store/:root`](#get-storeroot)
gives it.

Refusals: `blocked`, `overBudget`, `busy`, `draft(...)` (such as
`draft("root already uploaded")`). A body that is not a store request
answers 400.

`overBudget` means the upload does not fit in what is left of the sponsor's
storage budget. The budget counts every byte pinned and every upload not yet
pinned, so a paid upload always fits.

### `GET /store/:root`

| Answer field | Type | Meaning |
|---|---|---|
| `root` | string | The upload's root. |
| `bytes` | integer | Its size. |
| `needed` | object of integer | The coins still owed, on each chain with a storage rate, by chain path. |
| `credit` | integer | The bytes paid. |
| `stored` | boolean | Whether it is pinned. |

An unknown root answers 404 `unknownUpload`: it expired, or was never made.

## Buy serving standing

The node serves anyone free while it has free serving slots. When it is
busy, peers share its slots by standing: a byte balance per peer, used up by
the bytes it is served. Credit only raises a peer's share when the node is
busy.

Ask `POST /work` with `peer: <the peer's 64 lower-case hex Ed25519 key>` on
a chain in `servingRates`.

- Each accepted share's value times the rate, rounded down, is credited on
  the node at once, and `POST /shares` answers it as `serving`. A share
  worth less than a byte credits nothing.
- If the node does not take it, the share is refused `servingNotCredited`:
  the share is spent and its serving credit lost.
- Serving credit pays no fee, `pay` or storage, and fee or storage credit
  buys no serving.

## Pay in coin

Where `GET /terms` has a `payTo`, coin buys storage or serving at the rates
it lists, the same as work.

1. Send coins to `payTo` on a chain with a rate.
2. Wait until the transaction is `depth` blocks below the tip of the node's
   canonical chain.
3. Claim it with `POST /pay`, naming the upload's root as `store` or the
   peer as `peer`.

What the transaction pays `payTo` on that chain, net, times the rate, is
credited. Each transaction is credited once.

### `POST /pay`

| Request field | Type | Meaning |
|---|---|---|
| `chain` | string | The chain the transfer is on. |
| `txCID` | string | The transaction's CID. |
| `signer` | string | The address of one of the transaction's signers. |
| `signature` | hex | That signer's signature over the [claim message](#claim-signature). |
| `store` | string | An upload's root, or |
| `peer` | string | a peer's key, or |
| `fund` | array of strings | a [fund](#funds)'s prefixes. Exactly one of the three. |

| Answer field | Type | Meaning |
|---|---|---|
| `bytes` | integer | The bytes of storage or standing bought. `"0"` for a fund. |
| `deposit` | integer, fund only | The fund's deposit after the transfer. |

Refusals: `notIncluded`, `notDeepEnough`, `notSigner`, `invalidSignature`,
`noPayment`, `alreadyCredited`, `unknownUpload`, `blocked`, `noStorageRate`,
`noServingRate`, `noFunds`, `servingNotCredited`, `draft(...)`.

A serving claim that fails as `servingNotCredited` is still credited and the
payment used up, as with any node failure after the claim.

### Claim signature

The signature is the signer's `CryptoUtils.sign` signature, the scheme
Lattice signs transactions with, over one of these strings:

| Claim | Message |
|---|---|
| Storage | `lattice-sponsor-pay:v1:<chain>:<txCID>:<store>` |
| Serving | `lattice-sponsor-pay-serving:v1:<chain>:<txCID>:<peer>` |
| Fund | `lattice-sponsor-pay-fund:v1:<chain>:<txCID>:<prefixes>` |

`<prefixes>` is the fund's prefixes, [normalized](#funds) and joined by
`\n`.

## Funds

A fund is float a site lends the sponsor, so that one operator's coin does
not bound how many sites it sponsors. A sponsor takes funds when
`GET /terms` has a `fundTo`.

A fund is not a fee or a payment to the operator, and nothing is drawn from
it. Readers still pay for each fee with work, exactly as without a fund.
That work earns the sponsor's key the template's rewards, which repay the
fees, so on average a deposit stays the site's. There is no withdrawal yet.

### Name a fund

A fund is named by its key prefixes, and kept per chain:

- 1 to 8 non-empty strings of at most 128 bytes, without a newline, compared
  as bytes.
- The sponsor normalizes them: sorted by their UTF-8 bytes, repeats dropped.
  So `["b/", "a/"]` and `["a/", "b/", "a/"]` are one fund.

### Deposit

1. Send coins to `fundTo`, the sponsor's own address. A transfer to any
   other address funds nothing.
2. Claim it with [`POST /pay`](#post-pay), naming `fund: [prefix, ...]`.

What the transaction pays the sponsor, net, is added to the fund's deposit,
once per transaction. The answer is `{bytes: "0", deposit}`.

### Spend from a fund

A reader names the fund on `POST /sponsor` as `fund: [prefix, ...]`. The
fund backs the transaction when all of these hold:

- the transaction writes at least one key;
- every key it writes starts with one of the fund's prefixes;
- the fee and `pay` fit in the deposit beside what the fund already holds;
- its signer holds no transaction under the fund at another nonce.

A transaction the fund does not back is held against the operator's own
float, as without funds. A sponsor that is funded-only refuses it instead:
`inFlight` when the signer already holds one under the fund, else
`notFunded`.

A fund's hold lasts as any hold does
([Float and holds](operating.md#float-and-holds)): until the signer's nonce
on the chain passes the transaction's.

- A transaction the host dropped stays held, since it can still be
  resubmitted.
- One signer holds one at a time under a fund, so a reader who never submits
  keeps at most one fee of it.
- A redraft at the held nonce replaces the hold, keeping the larger amount,
  since only one of the two can land.

### `GET /fund`

`GET /fund?chain=<path>&prefix=<p>&prefix=<q>`

| Answer field | Type | Meaning |
|---|---|---|
| `deposit` | integer | The coins deposited, never drawn. |
| `held` | integer | What the fund backs now. Room for more is `deposit - held`. |

## Payouts

Where `GET /terms` has a `payoutAt`, the sponsor is also a pay-per-share
pool.

1. Ask `POST /work` with `payTo: <address>`, and no `pay`, `store` or
   `peer`.
2. Each share handed back is owed to that address on the chain named, at
   the template's price there.

No key or token is needed to earn: work only ever pays the address it
names. The sponsor pays an address once it is owed `payoutAt` coins on a
chain, in whole coins ([Operating](operating.md#payouts)).

Payout work backs at most half of each height's block; past that it is
refused `soldOut` until the chain moves on.

### `GET /earnings`

`GET /earnings?chain=<path>&address=<a>`

| Answer field | Type | Meaning |
|---|---|---|
| `earned` | integer | The address's earnings on the chain not yet paid out, in whole coins. |
| `payoutAt` | integer | The earnings at which the sponsor pays them out. |
| `paying` | boolean | Whether a payout to this address is in flight on the chain. |

## Refusals

A refusal is JSON, `{"error":{"message":"<name>"}}`. Clients match on the
name; the status groups them.

Three refusals carry `Retry-After: 5` (seconds), exposed to pages with
`Access-Control-Expose-Headers`: `busy`, `soldOut` and `notDeepEnough`.
Each clears as the chain moves, so the value is a hint: no clock predicts
when it does.

| Name | Status | Meaning | What to do |
|---|---|---|---|
| `unknownAssignment` | 400 | The sponsor no longer holds the assignment. Work on every earlier template is dropped when a block lands on the tip, and when the sponsor reconnects to its node or restarts, so every worker sees this about once per block. | `POST /work` again with the same `client`. |
| `expired` | 400 | The assignment's template is still held, but the chain the shares are credited on has moved past the block it carries. | `POST /work` again with the same `client`. |
| `outsideRange` | 400 | The nonce is not in the assignment's range. | |
| `missesShareTarget` | 400 | The hash is above `shareTarget`. | |
| `duplicateShare` | 400 | The share was already handed in. | |
| `draft("<reason>")` | 400 | The request or draft is not one the sponsor takes. The name carries the reason, such as `draft("wrong chain")`. | Fix the request. |
| `noStorageRate`, `noServingRate` | 400 | The sponsor sets no such rate on the chain. | Use a chain in `GET /terms`. |
| `overBudget` | 400 | The upload does not fit in the storage budget. | |
| `unknownUpload` | 400 (404 on `GET /store/:root`) | No upload is held under that root: it expired, or was never made. | `POST /store` again. |
| `notSigner` | 400 | The claimed signer did not sign the transaction. | |
| `invalidSignature` | 400 | The signature is not the signer's over the claim. | |
| `noPayment` | 400 | The transaction pays the sponsor's address nothing, net, or the sponsor takes no coin. | |
| `noFunds` | 400 | The sponsor takes no funds. | |
| `insufficientCredit` | 402 | The client's credit on the chain does not cover the fee and `pay` yet. | Hand in more shares. |
| `notFunded` | 402 | Funded-only, and no fund named backs the transaction. | |
| `notIncluded` | 404 | The transaction is not in the node's canonical chain. | |
| `noPayouts` | 404 | The sponsor pays out no earnings. | |
| `alreadyCredited` | 409 | The transaction is already credited, or being checked. | |
| `inFlight` | 409 | Funded-only, and the signer already holds a transaction under the fund at another nonce. | Submit that one, or redraft at its nonce. |
| `notDeepEnough` | 425 | Too few blocks are built on the transaction's block yet. | Retry later. |
| `blocked` | 451 | The operator took the CID down. It never clears. | |
| `servingNotCredited` | 502 | The node did not take the serving credit. The share or payment is spent. | |
| `busy` | 503 | No work can be handed out right now. | Retry after `Retry-After`. |
| `soldOut` | 503 | Credit backed by the chain's block at this height has reached its reward. | Retry once the chain moves on. |
| `unpriceable` | 503 | No price for a share on the chain: the newest template carries no block paying the sponsor there, its emission has ended, or there is no template yet. May never clear. | |
| `insufficientFloat` | 503 | The sponsor's balance does not cover the fees it has signed and this one. May never clear. | |
