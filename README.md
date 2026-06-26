# solrengine-sdp

Rails engine for **Wallet-per-User** custodial Solana wallets backed by the [Solana Developer Platform (SDP)](https://github.com/solana-foundation/solana-developer-platform). Your users sign up with an email — the engine provisions an SDP custody wallet for each of them, persists and tracks every transfer to a renderable terminal state, and pushes live balance updates to the browser when money moves on chain.

It composes the SolRengine family: the [solana-sdp](https://github.com/solrengine/solana-sdp) API client underneath, [solrengine-realtime](https://github.com/solrengine/realtime) for WebSocket account subscriptions, and (optionally) [solrengine-tokens](https://github.com/solrengine/tokens) as a USD price source. This is the "you hold wallets for your users" path; for "your users bring their own wallets", see the rest of the family at [solrengine.org](https://solrengine.org).

## Prerequisites

Honest list — SDP is pre-mainnet and devnet-oriented, and Wallet-per-User has real infrastructure requirements:

| You need | Why | Without it |
|---|---|---|
| A running SDP instance (self-hosted dev stack or managed) | The engine talks to SDP's wallets + payments API | Nothing works; boot check fails on a missing key |
| A **managed custody provider** (e.g. [Privy](https://privy.io)) configured in SDP | Per-user wallet provisioning | Local custody holds a **single root wallet** and rejects `POST /v1/wallets` (`Sdp::ProviderCapabilityError`) |
| **Kora** as SDP's fee-payment provider (`FEE_PAYMENT_PROVIDER=kora`) | Transfer execution | The native adapter can build and sign transfers but **cannot submit them** (`Sdp::TransferExecutionError`) |
| An SDP API key with `custody:admin`, `wallets:*`, and `payments:*` scopes | Custody init, provisioning, balances, transfers | 403 `Sdp::InsufficientPermissions` |
| A non-`async` Action Cable adapter in development | The watcher broadcasts from its own process | The install generator handles this — see [Cable adapter](#cable-adapter) |
| A Helius-class RPC endpoint (for SPL token balances) | Public devnet RPC lacks the indexing SDP uses for token balances | SOL still works; SPL balance rows may be missing |

## Quickstart

From zero to a confirmed transfer updating the screen live:

```sh
rails new mywallet
cd mywallet
```

Add to the `Gemfile`:

```ruby
gem "solrengine-sdp"
gem "dotenv-rails", groups: [ :development, :test ] # or load .env your own way
```

Then:

```sh
bundle install
bin/rails generate solrengine:sdp:install
bin/rails db:migrate
```

The generator created migrations, `config/initializers/solrengine_sdp.rb`, `bin/sdp_watcher`, a `Procfile.dev` entry, `.env` keys, and switched development Action Cable to Solid Cable (follow its printed instructions for the `solid_cable_messages` table). Fill in `.env`:

```sh
SDP_API_KEY=sk_...                      # custody:admin + wallets:* + payments:* scopes
SDP_API_BASE_URL=http://127.0.0.1:8787  # your SDP instance
SDP_CUSTODY_PROVIDER=privy              # managed provider — see Prerequisites
```

Opt in to provisioning on signup — uncomment in `app/models/user.rb`:

```ruby
after_create_commit :provision_wallet!
```

Run everything (web + watcher):

```sh
bin/dev
```

Sign up a user — `provision_wallet!` drives `pending → provisioning → ready` and fills `wallet_address`. Fund it from the devnet faucet and move money:

```ruby
user = User.last
user.wallet_ready? # => true

# Devnet-only faucet (1 SOL). One attempt, never retried.
Solrengine::Sdp::Faucet.new.request_airdrop(user.wallet_address, 1_000_000_000)

# Persisted, tracked transfer — the returned row is what you render.
transfer = Solrengine::Sdp::Transfer.execute!(
  source: user.sdp_wallet_id,
  destination: "RecipientPublicKeyBase58...",
  amount: "0.1",
  memo: "first transfer"
)
transfer.status # "processing" → tracked to "confirmed" → "finalized"
```

With `broadcast_targets` configured (see [Realtime](#realtime)) and a `turbo_stream_from` subscription on the page, the recipient's balance region updates live the moment the transfer lands — that is `bin/sdp_watcher` ringing the doorbell.

## Configuration

`config/initializers/solrengine_sdp.rb` (generated):

```ruby
Solrengine::Sdp.configure do |config|
  config.api_key = ENV["SDP_API_KEY"]
  # ...
end
```

| Attribute | Default | Purpose |
|---|---|---|
| `api_key` | `ENV["SDP_API_KEY"]` | SDP API key. Missing key fails **at boot** (`ConfigurationError`), not at the first wallet call. |
| `base_url` | `ENV["SDP_API_BASE_URL"]`, else `http://127.0.0.1:8787` | SDP API base URL. |
| `custody_provider` | `ENV["SDP_CUSTODY_PROVIDER"]` | Custody provider passed on wallet creation. Must be a managed provider for Wallet-per-User. |
| `label_namespace` | Rails app name, else `"app"` | Prefix for SDP wallet labels (`"#{namespace}-user-#{id}"`); guards collisions when apps share an SDP project. |
| `user_class` | `"User"` | The wallet-owner model (the one including `Solrengine::Sdp::WalletOwner`). |
| `logger` | `Rails.logger` | Engine log sink. |
| `expired_transfer_deadline` | `900` (seconds) | Transfers stuck in `processing` past this settle as `expired`. |
| `transfer_poll_interval` | `3` (seconds) | `TrackTransferJob` re-poll cadence. |
| `broadcast_retries` | `3` | Attempts per doorbell ring (the notification never re-fires). |
| `broadcast_retry_delay` | `2` (seconds) | Sleep between broadcast attempts (zero it in tests). |
| `broadcast_targets` | `[]` | Ordered `{name:, fetch:, render:}` hashes — see [Realtime](#realtime). Empty means: log a hint, broadcast nothing. |

## Realtime

The WebSocket account subscription is a **doorbell, not a data feed**: the notification only signals *that* a wallet's account changed. `bin/sdp_watcher` (its own process, in `Procfile.dev`) holds one subscription per wallet-ready user; on any change `Solrengine::Sdp::Broadcaster` re-fetches everything displayed from the authoritative source (SDP) and pushes your configured Turbo Stream updates.

The engine owns the doorbell invariants:

- **All-or-nothing** — every target's `fetch` runs first; any failure (raise or `:unavailable`) means no renders this attempt, so screens never regress from good content to an error state. Last good content stays.
- **Consumed doorbells retry** — the whole cycle retries `broadcast_retries` times, because a WebSocket notification never re-fires.
- **Priority order** — renders run in configured order; put money-bearing regions first.
- **Request-context-free** — lambdas run in the watcher process: no `Current`, no session, partials need explicit locals.

```ruby
config.broadcast_targets = [
  { name: :balance,
    fetch: ->(user) { Solrengine::Sdp.client.wallet_balances(user.sdp_wallet_id) },
    render: ->(user, balances) {
      Turbo::StreamsChannel.broadcast_update_to(
        [ user, :wallet ],
        target: "wallet_balance",
        partial: "wallets/balance",
        locals: { balances: balances }
      )
    } }
]
```

USD enrichment inside fetch lambdas: `Solrengine::Sdp.usd_value_for(balance)` — SDP's own `usd_value` when present, Jupiter-derived when solrengine-tokens is installed, `nil` otherwise. Price failures never fail a fetch.

**SOL-only doorbell in v0.1**: the system-account subscription sees lamport changes on the wallet address itself. SPL deposits land in Associated Token Accounts this subscription does not see — token balances are correct on page load, they just don't ring the doorbell yet. ATA subscriptions are planned.

**Degradation contract**: if the watcher isn't running, screens are correct on load — they just don't update live.

### Cable adapter

Rails' default `async` Action Cable adapter delivers broadcasts **in-process only** — everything the watcher pushes from its own process is silently dropped: no error, no log, the browser just never updates. The install generator rewrites the development adapter to Solid Cable (or tells you exactly what to do when your cable.yml isn't the stock layout), and `bin/sdp_watcher` performs a boot-time broadcast self-check plus an explicit async-adapter warning so a broken cable backend dies loudly instead of broadcasting into the void.

## Transfers

`Solrengine::Sdp::Transfer` is the engine-owned audit row — created *before* the POST to SDP, so even a crash mid-request leaves evidence to reconcile against. The create POST is **never retried** (SDP has no idempotency key; a blind re-send risks a double-spend); timeouts are reconciled by a unique memo token instead.

| Engine status | From | Terminal? | Meaning |
|---|---|---|---|
| `processing` | SDP `pending`/`processing` (and unrecognized statuses) | No | Submitted; `TrackTransferJob` polls until a verdict. |
| `confirmed` | SDP `confirmed` | No | **User-facing success** — tracking continues to finalized. |
| `finalized` | SDP `finalized` | Yes | Done. |
| `failed` | SDP `failed`, SDP rejections, or unreachable-SDP (`sdp_error` prefixed `unsent:`) | Yes | Renderable reason on `sdp_error`. |
| `expired` | engine-local | Yes | Stuck in `processing` past `expired_transfer_deadline` — verdict, not limbo. |
| `unknown` | engine-local | No | POST read-timeout: outcome unknown. Reconciled via the memo token through SDP's transfer list — adopted if found, `failed` if provably absent. |

`Transfer.execute!` runs a SOL balance preflight (`amount + 0.000005` fee buffer) and raises `InsufficientBalance` before any row or POST when the wallet provably can't cover it; an unreadable balance never blocks — the POST is the authority.

## Issuance

`Solrengine::Sdp::Token` issues a fungible SPL token through SDP and records every supply action as an engine-owned audit row. Mint authority is a custodial signing wallet (`signing_wallet_id`).

```ruby
token = Solrengine::Sdp::Token.register!(           # off-chain record (create_token)
  name: "Kudos Points", symbol: "KUDO", decimals: 0,
  signing_wallet_id: treasury_wallet_id
)
token.deploy!                                       # on-chain mint (deploy_token)

token.mint!(destination: user.wallet_address, amount: 10)  # credit — async, MintJob
token.burn!(source: user.wallet_address,                   # debit  — async, BurnJob
            signing_wallet_id: user.sdp_wallet_id, amount: 10)
```

`amount` is a **decimal token amount** — SDP scales it by the token's `decimals`, so `10` on a 0-decimal token is 10 whole tokens (it is **not** base units). Whole amounts are sent without a trailing `.0` (which SDP rejects for a 0-decimal token as "too many decimal places").

Each `mint!`/`burn!` persists a `TokenMint`/`TokenBurn` row, then enqueues a single **never-retried** POST. The atomic claim (`minting → in_flight`) guarantees a mint/burn is never sent twice (SDP has no idempotency key); unlike a transfer there is no mint-transaction list to reconcile against, so a read-timeout lands `unknown` and is surfaced, never auto-re-sent.

| Mint / Burn status | Terminal? | Meaning |
|---|---|---|
| `minting` / `burning` | No | Recorded, not yet sent. |
| `in_flight` | No | Claimed; the POST is in flight. A crash here is left for manual reconcile, never re-sent. |
| `minted` / `burned` | Yes | Confirmed on-chain. |
| `failed` | Yes | SDP rejected it, or it was never sent — reason on `sdp_error`. |
| `unknown` | No | POST read-timeout: outcome uncertain. Never re-sent; surfaced for review. |

App-initiated issuance is its own doorbell: on settle, `MintJob`/`BurnJob` ring the balance broadcast (the configured `broadcast_targets`) for the affected wallet, so an earn/redeem updates the UI live — including the first — without relying on the chain-WebSocket watcher, which sees a wallet's native account, not the token ATA a mint credits.

## Errors

Engine errors (all `< Solrengine::Sdp::Error < StandardError`):

| Error | Raised |
|---|---|
| `Solrengine::Sdp::ConfigurationError` | Boot/configure time: missing API key, malformed broadcast targets. |
| `Solrengine::Sdp::InsufficientBalance` | `Transfer.execute!` preflight — before any row or POST exists. |
| `Solrengine::Sdp::Faucet::RateLimited` / `TimedOut` / `Unavailable` | Devnet faucet outcomes — `TimedOut` means the airdrop *may* still land; don't double-fund. |

Transport and API errors raised while talking to SDP come from the client gem — `Sdp::Error` and its subclasses, including the two capability gates (`Sdp::ProviderCapabilityError` for local-custody provisioning, `Sdp::TransferExecutionError` for the native fee adapter). See the [solana-sdp error taxonomy](https://github.com/solrengine/solana-sdp#errors).

## SDP compatibility

Tested against SDP **v0.31** (`Solrengine::Sdp::COMPATIBLE_SDP_VERSION`). SDP is pre-1.0 and breaks its API between minors; the compatible version is bumped — and the suite re-verified — on every SDP upgrade rather than claiming an open-ended range.

## Local development

The Gemfile path-sources sibling checkouts: `../solana-sdp`, `../solrengine-realtime` (needs the `feat/subscriber-registry` branch for the 0.2 registry), `../solrengine-rpc`, and `../solrengine-tokens` (optional price source, dev-only — it is not a gemspec dependency). Clone them next to this repo, then:

```sh
bundle install
bundle exec rake test
bundle exec rubocop
```

Note: until solana-sdp and the realtime 0.2 branch are pushed to GitHub, CI's sibling-clone steps will fail remotely; local development is unaffected.

## See also

- [solana-sdp](https://github.com/solrengine/solana-sdp) — the plain-Ruby SDP API client this engine builds on (usable without Rails).
- [solrengine](https://github.com/solrengine/solrengine) — the meta-gem for the connect-your-wallet path; this engine is deliberately not among its dependencies (custodial mode is opt-in).
- [solrengine.org](https://solrengine.org) — the SolRengine family: the connect-your-wallet stack, and how both custody models compose.

## License

MIT
