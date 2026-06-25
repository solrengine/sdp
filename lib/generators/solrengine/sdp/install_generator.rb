# frozen_string_literal: true

require "rails/generators"
require "yaml"

module Solrengine
  module Sdp
    # `bin/rails generate solrengine:sdp:install`
    #
    # One run gives a default Rails app everything Wallet-per-User needs:
    #
    #   * two timestamped migrations (WalletOwner columns on users + the
    #     solrengine_sdp_transfers table) — skipped when a migration of the
    #     same name already exists, so re-running never duplicates them
    #   * config/initializers/solrengine_sdp.rb (ENV-backed configuration)
    #   * `include Solrengine::Sdp::WalletOwner` injected into app/models/user.rb
    #   * bin/sdp_watcher + a Procfile.dev entry for it
    #   * SDP_* keys appended to .env
    #   * a working development cable adapter (see #configure_cable_adapter —
    #     the default async adapter silently drops the watcher's broadcasts)
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      MIGRATIONS = %w[
        add_solrengine_sdp_to_users
        create_solrengine_sdp_transfers
        create_solrengine_sdp_tokens
        create_solrengine_sdp_token_mints
      ].freeze

      # The exact development block `rails new` emits — the only async config
      # this generator rewrites mechanically. Anything else async-but-custom
      # gets loud manual instructions instead of risky surgery.
      ASYNC_DEVELOPMENT_BLOCK = "development:\n  adapter: async\n"
      SOLID_CABLE_DEVELOPMENT_BLOCK = <<~YAML
        development:
          adapter: solid_cable
          polling_interval: 0.1.seconds
          message_retention: 1.hour
      YAML

      def create_migrations
        base = Time.now.utc
        MIGRATIONS.each_with_index do |name, offset|
          if migration_exists?(name)
            say_status :skip, "db/migrate/*_#{name}.rb already exists", :yellow
            next
          end

          # +offset keeps the two versions unique within a single run.
          version = (base + offset).strftime("%Y%m%d%H%M%S")
          copy_file "#{name}.rb", "db/migrate/#{version}_#{name}.rb"
        end
      end

      def create_initializer
        copy_file "initializer.rb", "config/initializers/solrengine_sdp.rb"
      end

      def include_wallet_owner_in_user_model
        user_model = "app/models/user.rb"
        unless exists?(user_model)
          say_status :skip, "#{user_model} not found — add `include Solrengine::Sdp::WalletOwner` " \
            "to your wallet-owner model and point config.user_class at it", :yellow
          return
        end
        return if read(user_model).include?("Solrengine::Sdp::WalletOwner")

        inject_into_class user_model, "User", <<-RUBY
  include Solrengine::Sdp::WalletOwner

  # Provision a custody wallet on signup (opt-in — uncomment to enable):
  # after_create_commit :provision_wallet!

        RUBY
      end

      def install_watcher
        copy_file "sdp_watcher", "bin/sdp_watcher"
        chmod "bin/sdp_watcher", 0o755
      end

      def update_procfile
        if exists?("Procfile.dev")
          unless read("Procfile.dev").include?("sdp_watcher:")
            append_to_file "Procfile.dev", "sdp_watcher: bin/sdp_watcher\n"
          end
        else
          create_file "Procfile.dev", "web: bin/rails server\nsdp_watcher: bin/sdp_watcher\n"
        end
      end

      def append_env_keys
        return if exists?(".env") && read(".env").include?("SDP_API_KEY")

        if exists?(".env")
          append_to_file ".env", env_block
        else
          create_file ".env", env_block
        end
      end

      # The cable adapter is part of this engine's correctness, not a nicety:
      # the default `async` adapter accepts broadcasts but delivers them
      # in-process only, so everything bin/sdp_watcher (a separate process)
      # pushes would be silently dropped — no error, the browser just never
      # updates. Development must be on a cross-process adapter.
      #
      # Decision (documented): the meta-gem's surgery force-replaces
      # database.yml with its own multi-database layout; this generator stays
      # single-database and writes a solid_cable development block WITHOUT
      # connects_to (Solid Cable then uses the primary database) plus loud
      # instructions for the gem + table. bin/sdp_watcher proves the result
      # with a boot-time broadcast self-check.
      def configure_cable_adapter
        unless exists?("config/cable.yml")
          copy_file "cable.yml", "config/cable.yml"
          say_cable_instructions
          return
        end

        adapter = development_cable_adapter
        if adapter == "async"
          if read("config/cable.yml").include?(ASYNC_DEVELOPMENT_BLOCK)
            gsub_file "config/cable.yml", ASYNC_DEVELOPMENT_BLOCK, SOLID_CABLE_DEVELOPMENT_BLOCK
            say_cable_instructions
          else
            say_cable_refusal("development uses the async adapter in a non-default layout")
          end
        elsif adapter.is_a?(String) && !adapter.empty?
          say_status :identical, "config/cable.yml development adapter is #{adapter} — cable adapter OK", :blue
        else
          say_cable_refusal("could not determine the development adapter")
        end
      end

      def show_post_install
        say "\n  solrengine-sdp installed!", :green
        say <<~MSG

            Next steps:
              1. bin/rails db:migrate
              2. Fill in .env: SDP_API_KEY (needs custody:admin + wallets:* + payments:* scopes),
                 SDP_API_BASE_URL, SDP_CUSTODY_PROVIDER
              3. Wallet-per-User needs a MANAGED custody provider (e.g. Privy) and Kora for
                 transfer execution — see the solrengine-sdp README "Prerequisites"
              4. To provision wallets on signup, uncomment in app/models/user.rb:
                   after_create_commit :provision_wallet!
              5. bin/dev — Procfile.dev now runs bin/sdp_watcher alongside the web server

        MSG
      end

      private

      # Destination-rooted file helpers: plain File.exist?("Procfile.dev")
      # would resolve against the process CWD, which differs from the target
      # app in generator tests.
      def exists?(relative_path)
        File.exist?(File.join(destination_root, relative_path))
      end

      def read(relative_path)
        File.read(File.join(destination_root, relative_path))
      end

      def migration_exists?(name)
        Dir.glob(File.join(destination_root, "db", "migrate", "*_#{name}.rb")).any?
      end

      def development_cable_adapter
        config = YAML.safe_load(read("config/cable.yml"), aliases: true)
        return nil unless config.is_a?(Hash)

        development = config["development"]
        development.is_a?(Hash) ? development["adapter"] : nil
      rescue Psych::Exception
        nil
      end

      def env_block
        <<~ENV
          # Solana Developer Platform (solrengine-sdp). The API key needs the
          # custody:admin, wallets:* and payments:* scopes. For Wallet-per-User
          # the SDP project must use a managed custody provider (e.g. privy) —
          # local custody is a single root wallet and cannot provision per-user
          # wallets — and Kora for fee payment (FEE_PAYMENT_PROVIDER=kora).
          SDP_API_KEY=
          SDP_API_BASE_URL=http://127.0.0.1:8787
          SDP_CUSTODY_PROVIDER=privy
        ENV
      end

      def say_cable_instructions
        say <<~MSG, :yellow

            config/cable.yml development now uses Solid Cable (the default async
            adapter delivers in-process only and would silently drop everything
            bin/sdp_watcher broadcasts). To finish:

              1. Ensure `gem "solid_cable"` is in your Gemfile (Rails 8 apps have it;
                 older apps: `bundle add solid_cable && bin/rails solid_cable:install`,
                 then re-check that cable.yml development still says solid_cable).
              2. Create the solid_cable_messages table in your DEVELOPMENT database
                 (development runs Solid Cable on the primary database):
                   bin/rails runner 'load Rails.root.join("db/cable_schema.rb")'
              3. Restart your web server — a running Puma keeps the old adapter in memory.

            bin/sdp_watcher verifies the cable backend with a broadcast self-check at boot.
        MSG
      end

      def say_cable_refusal(reason)
        say <<~MSG, :red

            NOT touching config/cable.yml: #{reason}.
            The async adapter delivers broadcasts in-process only — everything
            bin/sdp_watcher pushes would be silently dropped. Please make the
            development adapter cross-process yourself (solid_cable or redis), e.g.:

            #{SOLID_CABLE_DEVELOPMENT_BLOCK.gsub(/^/, "    ")}
            then create the solid_cable_messages table in your development database:
              bin/rails runner 'load Rails.root.join("db/cable_schema.rb")'

            bin/sdp_watcher verifies the cable backend with a broadcast self-check at boot.
        MSG
      end
    end
  end
end
