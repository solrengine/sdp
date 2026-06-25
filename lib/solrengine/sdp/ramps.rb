# frozen_string_literal: true

module Solrengine
  module Sdp
    # Thin engine wrapper over solana-sdp's ramps surface (SDP fiat on/off-ramps).
    # Its only job is to default `provider:` from config.ramp_provider so apps
    # don't repeat it on every call — the same convenience custody_provider gives
    # wallet calls. Everything else passes straight through to the client; there
    # is no model and no extra state.
    #
    # SANDBOX-ONLY in v0.2: wired against SDP's ramp surface and verified against
    # the sandbox, not live fiat rails. Treat as preview.
    class Ramps
      # provider may be nil (no configured default) — then callers must pass
      # `provider:` per call, and the client validates it.
      def initialize(client:, provider: nil)
        @client = client
        @provider = provider
      end

      def onramp_currencies(**kwargs)
        @client.onramp_currencies(**with_provider(kwargs))
      end

      def offramp_currencies(**kwargs)
        @client.offramp_currencies(**with_provider(kwargs))
      end

      def onramp_quote(**kwargs)
        @client.onramp_quote(**with_provider(kwargs))
      end

      def onramp_execute(**kwargs)
        @client.onramp_execute(**with_provider(kwargs))
      end

      def offramp_execute(**kwargs)
        @client.offramp_execute(**with_provider(kwargs))
      end

      # The sandbox event hook — no provider involved; pure passthrough.
      def simulate_ramp(**payload)
        @client.simulate_ramp(**payload)
      end

      private

      # Inject the configured provider unless the caller named one explicitly
      # (an explicit `provider: nil` is honored — it means "don't scope").
      def with_provider(kwargs)
        return kwargs if kwargs.key?(:provider) || @provider.nil?

        kwargs.merge(provider: @provider)
      end
    end
  end
end
