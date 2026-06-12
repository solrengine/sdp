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
WebMock.disable_net_connect!

# ActiveJob in test mode for U7/U8 job specs.
ActiveJob::Base.queue_adapter = :test
ActiveJob::Base.logger = ActiveSupport::Logger.new(File::NULL)

# In-memory SQLite — U7/U8 extend this schema as models land.
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :users, force: true do |t|
    t.string :email
    t.timestamps
  end
end

# Dummy app-side user model (the engine's default user_class).
class User < ActiveRecord::Base
end

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
