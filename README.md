# solrengine-sdp

Rails engine for custodial Solana wallets backed by the [Solana Developer Platform (SDP)](https://github.com/solana-foundation/solana-developer-platform): Wallet-per-User provisioning, locally persisted transfers with confirmation tracking, and real-time balance broadcasts — composing the [solana-sdp](https://github.com/solrengine/solana-sdp) client with the solrengine family (realtime, and optionally tokens for USD prices). Tested against SDP v0.28 (`Solrengine::Sdp::COMPATIBLE_SDP_VERSION`); SDP requires a managed custody provider (e.g. Privy) for Wallet-per-User and Kora for fee payment.

Full docs land with the install generator.

## Local development

The Gemfile path-sources sibling checkouts: `../solana-sdp`, `../solrengine-realtime` (needs the `feat/subscriber-registry` branch for the 0.2 registry), `../solrengine-rpc`, and `../solrengine-tokens` (optional price source, dev-only — it is not a gemspec dependency). Clone them next to this repo, then:

```sh
bundle install
bundle exec rake test
bundle exec rubocop
```

Note: until solana-sdp and the realtime 0.2 branch are pushed to GitHub, CI's sibling-clone steps will fail remotely; local development is unaffected.

## License

MIT
