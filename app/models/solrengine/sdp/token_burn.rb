# frozen_string_literal: true

module Solrengine
  module Sdp
    # Engine-owned record of every burn attempted through SDP — the redeem-path
    # counterpart to TokenMint, with the same never-double-* discipline.
    #
    # Status: burning → in_flight → burned | failed | unknown (see TokenMint
    # for the rationale; a timed-out burn stays `unknown` — never re-sent, no
    # listing to reconcile against).
    #
    # Unlike a mint (signed by the token's mint authority), a burn is signed by
    # the SOURCE wallet's owner: signing_wallet_id is the user's custodial
    # wallet, not the treasury.
    class TokenBurn < ActiveRecord::Base
      self.table_name = "solrengine_sdp_token_burns"

      MEMO_TOKEN_PREFIX = "sdpburn-"
      MEMO_SEPARATOR = " | "

      STATUSES = %w[burning in_flight burned failed unknown].freeze
      TERMINAL_STATUSES = %w[burned failed unknown].freeze

      belongs_to :token, class_name: "Solrengine::Sdp::Token"

      validates :source, :signing_wallet_id, :amount, :memo_token, presence: true
      validates :status, inclusion: { in: STATUSES }

      STATUSES.each { |s| define_method("#{s}?") { status == s } }

      scope :unsettled, -> { where.not(status: TERMINAL_STATUSES) }

      def pending?
        %w[burning in_flight].include?(status)
      end

      # Atomic claim: burning → in_flight in one UPDATE, so a crash + retry or
      # two workers can never send the same burn twice.
      def claim!
        won = self.class.where(id: id, status: "burning").update_all(status: "in_flight", updated_at: Time.current)
        reload if won == 1
        won == 1
      end

      # The single, never-retried burn POST.
      def submit_to_sdp!
        tx = Solrengine::Sdp.client.burn_token(
          token.sdp_token_id,
          signing_wallet_id: signing_wallet_id,
          source: source,
          amount: amount,
          memo: composed_memo
        )
        update!(
          status: terminal_for(tx.status),
          signature: tx.signature,
          sdp_transaction_id: tx.id,
          sdp_error: tx.error,
          settled_at: Time.current
        )
      rescue ::Sdp::Timeout
        update!(status: "unknown")
      rescue ::Sdp::Unavailable => e
        update!(status: "failed", sdp_error: "unsent: #{e.message}", settled_at: Time.current)
      rescue ::Sdp::Error => e
        update!(status: "failed", sdp_error: e.message, settled_at: Time.current)
      end

      def composed_memo
        [ memo, memo_token ].compact.join(MEMO_SEPARATOR)
      end

      private

      def terminal_for(sdp_status)
        case sdp_status.to_s
        when "confirmed", "finalized" then "burned"
        when "failed" then "failed"
        else "unknown"
        end
      end
    end
  end
end
