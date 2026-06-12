# frozen_string_literal: true

# Standalone minitest — family convention: no dummy Rails app. Rails pieces
# are loaded individually (active_record / active_job / active_support), so
# Rails::Engine is never defined here and lib/solrengine/sdp.rb skips the
# engine require. The Configuration class is tested directly.
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

# In-memory SQLite — U8 extends this schema as models land. The users columns
# are the reference schema for U10's migration template (WalletOwner expects
# exactly these names/defaults).
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
end

# Dummy app-side user model (the engine's default user_class).
class User < ActiveRecord::Base
  include Solrengine::Sdp::WalletOwner
end

# app/ is autoloaded by the engine in a Rails host; standalone tests load it
# explicitly.
require_relative "../app/jobs/solrengine/sdp/provision_wallet_job"

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
