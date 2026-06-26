# frozen_string_literal: true

module Solrengine
  module Sdp
    # Sends a single mint to SDP, off the web request. The mint POST is NEVER
    # retried — SDP has no idempotency key, so a blind re-send risks a
    # double-mint. The atomic claim (minting → in_flight) means a crash +
    # queue-retry, or two workers racing the same row, can never send twice:
    # only the claim winner POSTs; a row already claimed is left as-is.
    #
    # Transport failures are handled INSIDE TokenMint#submit_to_sdp!
    # (Timeout → unknown, Unavailable → failed), so this job never raises for
    # an automatic retry to catch.
    #
    # Inherits ActiveJob::Base directly so the engine never depends on the
    # host app's ApplicationJob (same posture as ProvisionWalletJob).
    class MintJob < ActiveJob::Base
      queue_as :default

      # Row deleted between enqueue and perform: nothing to mint.
      discard_on ActiveJob::DeserializationError

      def perform(mint)
        return unless mint.claim! # false → already attempted; never re-send

        mint.submit_to_sdp!
        # App-initiated issuance is its own doorbell. The chain-WebSocket
        # watcher only sees a wallet's native account, not the token ATA a
        # mint credits, so it never rings for an earn — but WE know the mint
        # just landed. Ring the balance broadcast directly (every earn,
        # including the first). A broadcast failure must never fail a settled
        # mint: the money already moved.
        broadcast_balance(mint.destination) if mint.minted?
      end

      private

      def broadcast_balance(wallet_address)
        Broadcaster.call(wallet_address)
      rescue StandardError => e
        Rails.logger&.warn("[Solrengine::Sdp::MintJob] post-mint broadcast failed: #{e.class}: #{e.message}")
      end
    end
  end
end
