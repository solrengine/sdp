# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# Local development uses sibling checkouts (see README "Local development").
# CI clones the same repos into ../ so these paths resolve there too.
gem "solana-sdp", path: "../solana-sdp"
gem "solrengine-realtime", path: "../solrengine-realtime"
gem "solrengine-rpc", path: "../solrengine-rpc" # transitive: realtime depends on it

# Optional price source — dev/test only, so the soft-detection fallback
# (Solrengine::Sdp.price_for) is exercisable. NOT a gemspec dependency.
gem "solrengine-tokens", path: "../solrengine-tokens"

gem "irb"
gem "minitest"
gem "rake", "~> 13.0"
gem "sqlite3"
gem "webmock"

gem "rubocop-rails-omakase", require: false
