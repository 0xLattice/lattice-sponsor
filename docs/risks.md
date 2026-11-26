# lattice-sponsor operator risks

What running a sponsor exposes its operator to, and the limits that bound
each exposure. Read it before putting coin on a sponsor's key, or before
trusting someone else's sponsor with a file or a deposit. The flags named
here are in [Operating](operating.md#flags).

## Summary

| Exposure | Bounded by |
|---|---|
| A draft reaching what the key owns | The key owns the float and nothing else. |
| Clients withholding the shares that are blocks | The float; `--most-pay`; one block reward of credit per height. |
| Fees signed and never submitted | The work that paid for them; one hold per signer under a fund. |
| Payouts on shares that win nothing | The float; half of each height's block. |
| Content you did not choose, served from your node | `--storage-budget`; takedowns. |
| Other people's deposits in your key | Nothing in the code: sites trust the operator. |

## The key

A co-signature lends the key's authority to the whole body it signs. The
sponsor refuses a draft that names its address as an account, a demander or
a withdrawer, or inside an action's key or values, and one that does not
balance without it. So its own debit can only be the fee and the client's
`pay`.

A chain's policies may still read the signer list, which no check can
bound. The key must therefore hold its float and nothing else: it must own
nothing a draft could reach.

Do not sign transactions with the key elsewhere. One that takes a pending
payout's nonce leaves that payout unconfirmed and unpaid until you release
it ([Operating](operating.md#release-an-unconfirmed-payout)).

## Withheld blocks

A client can withhold the shares that are blocks, as against any pool, and
nothing in the sponsor detects it. Its credit then buys:

- fees, and
- with `--most-pay`, coins paid to the client itself.

That is up to the fee plus `--most-pay` (by default a block reward) per
transaction, from the key's balance, which also holds the blocks the sponsor
wins. The float is the operator's bound on that loss. Set `--most-pay 0` to
keep it to fees.

All the credit one block height backs, across every client, stops at that
block's reward.

## Fees signed and not submitted

A signed fee and `pay` are held against the float until the client's nonce
passes them, so a body never submitted stays held
([Float and holds](operating.md#float-and-holds)). Its client paid for it in
work, which earns the key as much on average.

Without `--funds` or `--payout-at`, holds are kept in memory, and a restart
forgets them.

## Payouts

Payouts are the same bet as fees without the cap per transaction: each share
is paid at its expected value whether or not it wins, and the sponsor keeps
the blocks it does win.

- On average the float neither grows nor shrinks by it.
- A run of bad luck, or shares withheld, draw it down.
- A payout that no longer fits the float waits until it does.
- Payout work backs at most half of each height's block.

## Storage

Every pinned file is served by the operator's node, from the operator's IP
address, to anyone who asks for it. The sponsor does not look at what it
pins: anyone who pays can upload anything. So the operator answers for what
it serves and must be able to remove it.

- `--storage-budget` bounds the bytes pinned at once, uploads not yet pinned
  included.
- A takedown unpins a file and blocks its CIDs for good
  ([Operating](operating.md#take-a-file-down)).
- Nothing paid for a file taken down is refunded.

An uploader, for their part, trusts the host for availability only: bytes
are checked by CID.

## Funds

A fund's deposit joins the key's one balance, so its luck is shared. Blocks
the readers' work fails to win, and shares withheld by any client, cost
every deposit and the operator's float alike, not the site whose readers
caused them.

For a site lending float:

- A fund backs only transactions that write nothing but keys under its
  prefixes. But anyone may fund any prefixes, and anyone who writes under
  them uses the fund's room: a site's prefixes should be ones only its own
  readers write.
- Deposits cannot be withdrawn yet.
- The operator holds the coin and keeps the deposits. A site trusts it to do
  so honestly, as an uploader trusts a storage sponsor.

## Restarts

Credit is held in memory, so a restart forfeits clients' unspent shares and
uploads not yet pinned ([State](operating.md#in-memory)).
