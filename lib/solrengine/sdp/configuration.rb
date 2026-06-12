# frozen_string_literal: true

module Solrengine
  module Sdp
    # Engine configuration: explicit attributes with ENV fallbacks
    # (rpc/auth family pattern — a real class, not bare mattr_accessor).
    #
    #   Solrengine::Sdp.configure do |config|
    #     config.api_key    = Rails.application.credentials.dig(:sdp, :api_key)
    #     config.user_class = "Account"
    #   end
    class Configuration
      DEFAULT_BASE_URL = "http://127.0.0.1:8787"
      DEFAULT_EXPIRED_TRANSFER_DEADLINE = 15 * 60 # seconds
      DEFAULT_TRANSFER_POLL_INTERVAL = 3 # seconds — confirmation is usually seconds away

      attr_writer :api_key, :base_url, :custody_provider, :label_namespace
      attr_accessor :user_class, :expired_transfer_deadline, :transfer_poll_interval,
                    :broadcast_retry_delay, :broadcast_retries

      def initialize
        @user_class = "User"
        @expired_transfer_deadline = DEFAULT_EXPIRED_TRANSFER_DEADLINE
        @transfer_poll_interval = DEFAULT_TRANSFER_POLL_INTERVAL
        @broadcast_retry_delay = 2
        @broadcast_retries = 3
      end

      def api_key
        @api_key || ENV["SDP_API_KEY"]
      end

      def base_url
        @base_url || ENV.fetch("SDP_API_BASE_URL", DEFAULT_BASE_URL)
      end

      def custody_provider
        @custody_provider || ENV["SDP_CUSTODY_PROVIDER"]
      end

      # Prefix for SDP wallet labels ("#{label_namespace}-user-#{id}").
      # Defaults to the Rails application name, else "app".
      def label_namespace
        @label_namespace || default_label_namespace
      end

      # Lazily constantized so the engine can be configured before the app's
      # user model is loadable (initializer-time safe).
      def user_model
        Object.const_get(user_class)
      end

      # Boot check used by the engine's after_initialize hook, also callable
      # directly. A missing key must fail loudly at boot, not at the first
      # wallet call.
      def validate!
        return self unless api_key.to_s.strip.empty?

        raise ConfigurationError,
          "Solrengine::Sdp api_key is not set. The engine cannot talk to the SDP API without it. " \
          "Set the SDP_API_KEY environment variable (start the local SDP stack and export the " \
          "seeded key) or assign config.api_key in a Solrengine::Sdp.configure block. " \
          "Optionally set SDP_API_BASE_URL (default: #{DEFAULT_BASE_URL})."
      end

      private

      def default_label_namespace
        name = rails_application_name
        name.nil? || name.empty? ? "app" : name
      end

      def rails_application_name
        return nil unless defined?(Rails) && Rails.respond_to?(:application) && Rails.application

        Rails.application.class.name&.split("::")&.first&.downcase
      end
    end
  end
end
