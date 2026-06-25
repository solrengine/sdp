# frozen_string_literal: true

# Standalone minitest — family convention: no dummy Rails app. Rails pieces
# are loaded individually (active_record / active_job / active_support), so
# Rails::Engine is not defined when this file loads and lib/solrengine/sdp.rb
# skips the engine require. The Configuration class is tested directly.
# NOTE: install_generator_test.rb later requires railties (rails/generators),
# so `defined?(Rails)` may be true across the suite — but Rails.application
# stays nil; tests must key off the application, never the constant.
require "minitest/autorun"
require "webmock/minitest"
require "active_support"
require "active_support/core_ext"
require "active_record"
require "active_job"

require "solrengine/sdp"

# Stub by default; nothing in this suite should hit the network.
# NOTE: webmock/minitest resets stubs + request history in Minitest::Test#teardown —
# test classes that define their own #teardown MUST call super or history leaks
# across tests.
WebMock.disable_net_connect!

# ActiveJob in test mode for U7/U8 job specs.
ActiveJob::Base.queue_adapter = :test
ActiveJob::Base.logger = ActiveSupport::Logger.new(File::NULL)

# GlobalID so ActiveJob can (de)serialize AR models — exercises the deleted-
# user → DeserializationError → discard_on path exactly as in a Rails app.
# Outside Rails the globalid railtie doesn't run, so wire it up by hand.
require "global_id"
GlobalID.app = "solrengine-sdp-test"
ActiveRecord::Base.include(GlobalID::Identification)

# In-memory SQLite — the tables here are the reference schema for U10's
# migration templates (WalletOwner and Transfer expect exactly these
# names/defaults).
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :users, force: true do |t|
    t.string :email
    t.string :sdp_wallet_id
    t.string :wallet_address
    t.string :sdp_provisioning_state, default: "pending", null: false
    t.string :sdp_provisioning_error
    t.timestamps
  end

  create_table :solrengine_sdp_transfers, force: true do |t|
    t.string :sdp_transfer_id              # nil until SDP responds (POST timeout → reconcile)
    t.string :source_wallet_id, null: false
    t.string :destination, null: false
    t.string :token, null: false, default: "SOL"
    t.string :amount, null: false          # decimal string — never a float
    t.string :memo                         # the app's memo (composes with memo_token)
    t.string :memo_token, null: false      # engine reconcile token
    t.string :status, null: false, default: "processing"
    t.string :sdp_status
    t.string :signature
    t.string :sdp_error
    t.datetime :submitted_at
    t.datetime :settled_at
    t.timestamps
  end
  add_index :solrengine_sdp_transfers, :memo_token, unique: true
  add_index :solrengine_sdp_transfers, :status

  create_table :solrengine_sdp_tokens, force: true do |t|
    t.string :sdp_token_id
    t.string :mint_address
    t.string :name, null: false
    t.string :symbol, null: false
    t.integer :decimals, null: false, default: 0
    t.string :signing_wallet_id, null: false
    t.string :status, null: false, default: "created"
    t.string :sdp_error
    t.timestamps
  end
  add_index :solrengine_sdp_tokens, :sdp_token_id, unique: true

  create_table :solrengine_sdp_token_mints, force: true do |t|
    t.references :token, null: false
    t.string :destination, null: false
    t.string :amount, null: false
    t.string :memo
    t.string :memo_token, null: false
    t.string :status, null: false, default: "minting"
    t.string :signature
    t.string :sdp_transaction_id
    t.string :token_account
    t.string :sdp_error
    t.datetime :submitted_at
    t.datetime :settled_at
    t.timestamps
  end
  add_index :solrengine_sdp_token_mints, :memo_token, unique: true
  add_index :solrengine_sdp_token_mints, :status

  create_table :solrengine_sdp_token_burns, force: true do |t|
    t.references :token, null: false
    t.string :source, null: false
    t.string :signing_wallet_id, null: false
    t.string :amount, null: false
    t.string :memo
    t.string :memo_token, null: false
    t.string :status, null: false, default: "burning"
    t.string :signature
    t.string :sdp_transaction_id
    t.string :sdp_error
    t.datetime :submitted_at
    t.datetime :settled_at
    t.timestamps
  end
  add_index :solrengine_sdp_token_burns, :memo_token, unique: true
  add_index :solrengine_sdp_token_burns, :status
end

# Dummy app-side user model (the engine's default user_class).
class User < ActiveRecord::Base
  include Solrengine::Sdp::WalletOwner
end

# app/ is autoloaded by the engine in a Rails host; standalone tests load it
# explicitly.
require_relative "../app/models/solrengine/sdp/transfer"
require_relative "../app/models/solrengine/sdp/token"
require_relative "../app/models/solrengine/sdp/token_mint"
require_relative "../app/models/solrengine/sdp/token_burn"
require_relative "../app/jobs/solrengine/sdp/provision_wallet_job"
require_relative "../app/jobs/solrengine/sdp/track_transfer_job"
require_relative "../app/jobs/solrengine/sdp/mint_job"
require_relative "../app/jobs/solrengine/sdp/burn_job"

# ENV save/restore for configuration tests.
module EnvHelper
  def with_env(pairs)
    saved = pairs.keys.to_h { |key| [ key, ENV[key] ] }
    pairs.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
