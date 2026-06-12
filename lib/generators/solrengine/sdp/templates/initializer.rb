# solrengine-sdp — custodial Solana wallets via the Solana Developer Platform.
#
# api_key, base_url, and custody_provider already fall back to SDP_API_KEY,
# SDP_API_BASE_URL, and SDP_CUSTODY_PROVIDER from ENV; the explicit
# assignments below just make the wiring visible. A missing api_key fails
# loudly at boot (Solrengine::Sdp::ConfigurationError), not at the first
# wallet call.
Solrengine::Sdp.configure do |config|
  config.api_key = ENV["SDP_API_KEY"]
  config.base_url = ENV.fetch("SDP_API_BASE_URL", "http://127.0.0.1:8787")

  # Wallet-per-User requires a MANAGED custody provider (e.g. "privy") —
  # SDP's local custody holds a single root wallet and rejects per-user
  # wallet provisioning (Sdp::ProviderCapabilityError).
  config.custody_provider = ENV["SDP_CUSTODY_PROVIDER"]

  # Prefix for SDP wallet labels ("#{label_namespace}-user-#{id}") — guards
  # against collisions when several apps share one SDP project. Defaults to
  # the Rails application name.
  # config.label_namespace = "myapp"

  # The wallet-owner model (the one including Solrengine::Sdp::WalletOwner).
  # Defaults to "User".
  # config.user_class = "Account"

  # Realtime broadcast targets — what bin/sdp_watcher re-fetches and pushes
  # when a wallet's account changes on chain. Ordered: put fast,
  # money-bearing regions first. The lambdas run in the watcher process,
  # OUTSIDE any HTTP request: Current attributes and the session are
  # unavailable, so partials must receive explicit locals.
  #
  # config.broadcast_targets = [
  #   { name: :balance,
  #     fetch: ->(user) { Solrengine::Sdp.client.wallet_balances(user.sdp_wallet_id) },
  #     render: ->(user, balances) {
  #       Turbo::StreamsChannel.broadcast_update_to(
  #         [ user, :wallet ],
  #         target: "wallet_balance",
  #         partial: "wallets/balance",
  #         locals: { balances: balances }
  #       )
  #     } }
  # ]
end
