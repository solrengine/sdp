require_relative "lib/solrengine/sdp/version"

Gem::Specification.new do |spec|
  spec.name = "solrengine-sdp"
  spec.version = Solrengine::Sdp::VERSION
  spec.authors = [ "Jose Ferrer" ]
  spec.email = [ "estoy@moviendo.me" ]

  spec.summary = "Custodial Solana wallets for Rails via the Solana Developer Platform"
  spec.description = "Rails engine for SDP-backed apps: Wallet-per-User provisioning, transfer persistence and tracking, and real-time balance broadcasts built on the solrengine family."
  spec.homepage = "https://github.com/solrengine/sdp"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  spec.files = Dir["lib/**/*", "app/**/*", "config/**/*", "LICENSE", "README.md"]
  spec.require_paths = [ "lib" ]

  spec.add_dependency "rails", ">= 7.1"
  spec.add_dependency "solana-sdp", "~> 0.1"
  spec.add_dependency "solrengine-realtime", "~> 0.2"

  # solrengine-tokens is deliberately NOT a dependency: it is an optional
  # price source, soft-detected at runtime (Solrengine::Sdp.price_source_available?).
end
