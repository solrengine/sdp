# frozen_string_literal: true

module Solrengine
  module Sdp
    # Engine-owned record of every mint attempted through SDP — the audit
    # trail and the never-double-mint guard.
    #
    # Status machine:
    #   minting   → just recorded, not yet sent (created before the POST)
    #   in_flight → claimed by MintJob; the POST is being sent (atomic claim
    #               so a crash + queue-retry never re-sends the same mint)
    #   minted    → confirmed on-chain (terminal)
    #   failed    → SDP rejected it, or it was never sent (terminal)
    #   unknown   → the POST read-timed out: outcome uncertain. NEVER re-sent
    #               (double-mint risk), and SDP exposes no mint-transaction
    #               listing to reconcile against — surfaced for manual review.
    #
    # The mint POST is NEVER retried (SDP has no idempotency key). Unlike a
    # Transfer there is no memo-token reconcile path (no list endpoint for
    # mint transactions), so a timed-out mint stays `unknown` rather than
    # auto-resolving.
    class TokenMint < ActiveRecord::Base
      self.table_name = "solrengine_sdp_token_mints"

      MEMO_TOKEN_PREFIX = "sdpmint-"
      MEMO_SEPARATOR = " | "

      STATUSES = %w[minting in_flight minted failed unknown].freeze
      TERMINAL_STATUSES = %w[minted failed unknown].freeze

      belongs_to :token, class_name: "Solrengine::Sdp::Token"

      validates :destination, :amount, :memo_token, presence: true
      validates :status, inclusion: { in: STATUSES }

      STATUSES.each { |s| define_method("#{s}?") { status == s } }

      scope :unsettled, -> { where.not(status: TERMINAL_STATUSES) }

      def pending?
        %w[minting in_flight].include?(status)
      end

      # Atomic claim: minting → in_flight in one UPDATE. Returns true only for
      # the caller that won the claim, so a crash + queue-retry (or two workers)
      # can never send the same mint twice. A row stuck in_flight is a
      # crashed-mid-send and is left for manual reconcile, never auto-re-sent.
      def claim!
        won = self.class.where(id: id, status: "minting").update_all(status: "in_flight", updated_at: Time.current)
        reload if won == 1
        won == 1
      end

      # The single, never-retried mint POST. Every outcome lands on the row.
      def submit_to_sdp!
        tx = Solrengine::Sdp.client.mint_token(
          token.sdp_token_id,
          signing_wallet_id: token.signing_wallet_id,
          destination: destination,
          amount: amount,
          memo: composed_memo
        )
        update!(
          status: terminal_for(tx.status),
          signature: tx.signature,
          sdp_transaction_id: tx.id,
          token_account: tx.token_account,
          sdp_error: tx.error,
          settled_at: Time.current
        )
      rescue ::Sdp::Timeout
        # Outcome unknown — NEVER re-send. No mint-tx listing to reconcile.
        update!(status: "unknown")
      rescue ::Sdp::Unavailable => e
        # Request never processed — safe to mark failed (no money moved).
        update!(status: "failed", sdp_error: "unsent: #{e.message}", settled_at: Time.current)
      rescue ::Sdp::Error => e
        update!(status: "failed", sdp_error: e.message, settled_at: Time.current)
      end

      def composed_memo
        [ memo, memo_token ].compact.join(MEMO_SEPARATOR)
      end

      private

      # mint_token returns a confirmed TokenTransaction on success. A non-
      # confirmed status can't be polled (no get-mint endpoint), so anything
      # that isn't clearly confirmed/finalized or failed lands as unknown.
      def terminal_for(sdp_status)
        case sdp_status.to_s
        when "confirmed", "finalized" then "minted"
        when "failed" then "failed"
        else "unknown"
        end
      end
    end
  end
end
