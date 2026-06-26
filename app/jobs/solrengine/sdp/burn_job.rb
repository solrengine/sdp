# frozen_string_literal: true

module Solrengine
  module Sdp
    # Sends a single burn to SDP, off the web request. The burn POST is NEVER
    # retried; the atomic claim (burning → in_flight) guarantees a burn is
    # never sent twice. Counterpart to MintJob — see it for the full rationale.
    class BurnJob < ActiveJob::Base
      queue_as :default

      discard_on ActiveJob::DeserializationError

      def perform(burn)
        return unless burn.claim! # false → already attempted; never re-send

        burn.submit_to_sdp!
        # See MintJob: the burn is its own doorbell, so ring the source
        # wallet's balance broadcast directly when the burn settles.
        broadcast_balance(burn.source) if burn.burned?
      end

      private

      def broadcast_balance(wallet_address)
        Broadcaster.call(wallet_address)
      rescue StandardError => e
        Rails.logger&.warn("[Solrengine::Sdp::BurnJob] post-burn broadcast failed: #{e.class}: #{e.message}")
      end
    end
  end
end
