# frozen_string_literal: true

require "test_helper"
require "rails/generators"
require "rails/generators/test_case"
require "generators/solrengine/sdp/install_generator"

# Rails::Generators::TestCase against a scratch destination dir — no dummy
# Rails app needed (the family has no generator-test precedent; tokens ships
# its generator untested). railties is already a dependency via rails.
class InstallGeneratorTest < Rails::Generators::TestCase
  tests Solrengine::Sdp::InstallGenerator
  destination File.expand_path("tmp/generator", __dir__)
  setup :prepare_destination

  RAILS_DEFAULT_CABLE_YML = <<~YAML
    development:
      adapter: async

    test:
      adapter: test

    production:
      adapter: solid_cable
      connects_to:
        database:
          writing: cable
      polling_interval: 0.1.seconds
      message_retention: 1.day
  YAML

  def test_creates_migrations_initializer_watcher_procfile_and_env
    run_generator

    assert_migration "db/migrate/add_solrengine_sdp_to_users.rb" do |content|
      assert_match(/add_column :users, :sdp_wallet_id, :string/, content)
      assert_match(/add_column :users, :wallet_address, :string/, content)
      assert_match(/add_column :users, :sdp_provisioning_state, :string, default: "pending", null: false/, content)
      assert_match(/add_column :users, :sdp_provisioning_error, :string/, content)
      assert_match(/add_index :users, :sdp_provisioning_state/, content)
    end

    assert_migration "db/migrate/create_solrengine_sdp_transfers.rb" do |content|
      assert_match(/create_table :solrengine_sdp_transfers/, content)
      assert_match(/t\.string :memo_token, null: false/, content)
      assert_match(/add_index :solrengine_sdp_transfers, :memo_token, unique: true/, content)
      assert_match(/add_index :solrengine_sdp_transfers, :status/, content)
    end

    assert_file "config/initializers/solrengine_sdp.rb", /Solrengine::Sdp\.configure/
    assert_file "bin/sdp_watcher", /Solrengine::Sdp\.start_realtime!/
    assert File.executable?(File.join(destination_root, "bin/sdp_watcher")),
      "bin/sdp_watcher should be executable"
    assert_file "Procfile.dev", /^sdp_watcher: bin\/sdp_watcher$/
    assert_file ".env", /SDP_API_KEY=/
    assert_file ".env", /SDP_API_BASE_URL=http:\/\/127\.0\.0\.1:8787/
    assert_file ".env", /SDP_CUSTODY_PROVIDER=privy/
  end

  def test_running_twice_is_idempotent
    run_generator
    run_generator

    %w[add_solrengine_sdp_to_users create_solrengine_sdp_transfers].each do |name|
      matches = Dir.glob(File.join(destination_root, "db/migrate/*_#{name}.rb"))
      assert_equal 1, matches.length, "expected exactly one #{name} migration, got #{matches.inspect}"
    end

    procfile = File.read(File.join(destination_root, "Procfile.dev"))
    assert_equal 1, procfile.scan("sdp_watcher:").count

    env = File.read(File.join(destination_root, ".env"))
    assert_equal 1, env.scan("SDP_API_KEY=").count
  end

  def test_injects_wallet_owner_into_user_model_once
    write_destination_file "app/models/user.rb", <<~RUBY
      class User < ApplicationRecord
      end
    RUBY

    run_generator
    run_generator

    content = File.read(File.join(destination_root, "app/models/user.rb"))
    assert_equal 1, content.scan("include Solrengine::Sdp::WalletOwner").count
    assert_match(/# after_create_commit :provision_wallet!/, content)
  end

  def test_missing_user_model_skips_with_message
    output = run_generator

    assert_match(/app\/models\/user\.rb not found/, output)
    assert_no_file "app/models/user.rb"
  end

  def test_appends_to_existing_procfile_and_env
    write_destination_file "Procfile.dev", "web: bin/rails server\ncss: bin/rails tailwindcss:watch\n"
    write_destination_file ".env", "EXISTING_KEY=1\n"

    run_generator

    assert_file "Procfile.dev", /css: bin\/rails tailwindcss:watch\nsdp_watcher: bin\/sdp_watcher\n/
    assert_file ".env", /EXISTING_KEY=1/
    assert_file ".env", /SDP_API_KEY=/
  end

  def test_rewrites_default_async_cable_adapter_to_solid_cable
    write_destination_file "config/cable.yml", RAILS_DEFAULT_CABLE_YML

    run_generator

    assert_file "config/cable.yml" do |content|
      config = YAML.safe_load(content, aliases: true)
      assert_equal "solid_cable", config.dig("development", "adapter")
      assert_equal "0.1.seconds", config.dig("development", "polling_interval")
      # The rest of the file is untouched.
      assert_equal "test", config.dig("test", "adapter")
      assert_equal "solid_cable", config.dig("production", "adapter")
      assert_equal "cable", config.dig("production", "connects_to", "database", "writing")
    end
  end

  def test_creates_cable_yml_when_missing
    run_generator

    assert_file "config/cable.yml" do |content|
      config = YAML.safe_load(content, aliases: true)
      assert_equal "solid_cable", config.dig("development", "adapter")
      assert_equal "test", config.dig("test", "adapter")
    end
  end

  def test_leaves_non_async_cable_adapter_untouched
    cable = <<~YAML
      development:
        adapter: redis
        url: redis://localhost:6379/1
    YAML
    write_destination_file "config/cable.yml", cable

    output = run_generator

    assert_match(/cable adapter OK/, output)
    assert_equal cable, File.read(File.join(destination_root, "config/cable.yml"))
  end

  def test_refuses_loudly_on_unrecognizable_async_cable_config
    cable = <<~YAML
      development:
        adapter: async # tuned
        executor: custom
    YAML
    write_destination_file "config/cable.yml", cable

    output = run_generator

    assert_match(/NOT touching config\/cable\.yml/, output)
    assert_match(/solid_cable/, output)
    assert_equal cable, File.read(File.join(destination_root, "config/cable.yml"))
  end

  private

  def write_destination_file(relative_path, content)
    path = File.join(destination_root, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end
end
