# frozen_string_literal: true

require "solana-sdp"

require_relative "sdp/version"
require_relative "sdp/errors"
require_relative "sdp/configuration"
require_relative "sdp/wallet_owner"
require_relative "sdp/engine" if defined?(Rails::Engine)

module Solrengine
  # Rails engine for custodial Solana wallets backed by the Solana Developer
  # Platform (SDP). Composes the solana-sdp client with the solrengine family.
  module Sdp
    # Rake task prefixes for which the boot-time api_key check is skipped:
    # CI and Docker image builds run these without production secrets.
    EXEMPT_TASK_PREFIXES = %w[assets: db: app: tmp: log:].freeze

    class << self
      def configuration
        @configuration ||= Configuration.new
      end

      def configure
        yield(configuration)
        @client = nil
        configuration
      end

      # Memoized SDP API client built from the configuration. Reset whenever
      # `configure` runs, so reconfiguring always yields a fresh client.
      def client
        @client ||= ::Sdp::Client.new(
          api_key: configuration.validate!.api_key,
          base_url: configuration.base_url
        )
      end

      def reset_configuration!
        @configuration = nil
        @client = nil
      end

      # Pure function over rake task names so the exemption logic is
      # unit-testable: exempt_context?(["assets:precompile"]) => true.
      def exempt_context?(task_names)
        Array(task_names).any? do |task|
          EXEMPT_TASK_PREFIXES.any? { |prefix| task.to_s.start_with?(prefix) }
        end
      end

      # True when the current process is an exempt rake task (boot check skip).
      def exempt_rake_context?
        return false unless defined?(Rake) && Rake.respond_to?(:application)

        application = Rake.application
        return false unless application.respond_to?(:top_level_tasks)

        exempt_context?(application.top_level_tasks)
      end

      # solrengine-tokens is an optional price source — never a hard
      # dependency. True when its JupiterClient is loadable.
      def price_source_available?
        return true if defined?(Solrengine::Tokens::JupiterClient)

        begin
          require "solrengine/tokens"
        rescue LoadError
          return false
        end

        defined?(Solrengine::Tokens::JupiterClient) ? true : false
      end

      # USD price for a mint via the optional tokens gem. Returns nil when the
      # gem is absent or the price lookup fails — price must never gate money
      # flows (the U9 broadcaster builds on this).
      def price_for(mint)
        return nil unless price_source_available?

        Solrengine::Tokens::JupiterClient.fetch_prices([ mint ])[mint]
      rescue StandardError
        nil
      end
    end
  end
end
