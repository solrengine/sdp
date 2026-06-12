# frozen_string_literal: true

require "bigdecimal"
require "securerandom"

module Solrengine
  module Sdp
    # Engine-owned record of every transfer the app attempts through SDP —
    # the row IS the audit trail and the thing the app renders (R6: every
    # transfer settles into a renderable terminal state).
    #
    # Status mapping (the HTD table, one-to-one):
    #
    #   SDP pending/processing → "processing"  (non-terminal, polled)
    #   SDP confirmed          → "confirmed"   (user-facing success; tracking
    #                                           CONTINUES to finalized)
    #   SDP finalized          → "finalized"   (terminal)
    #   SDP failed             → "failed"      (terminal; SDP error captured)
    #   engine-local           → "expired"     (terminal; stuck in processing
    #                                           past expired_transfer_deadline)
    #   engine-local           → "unknown"     (POST read-timeout: outcome
    #                                           unknown; reconciled by memo
    #                                           token via list_transfers)
    #
    # The create POST is NEVER retried — SDP has no idempotency key, so a
    # blind re-send risks a double-spend (demo TransfersController /
    # RecurringExecution discipline). The row is created BEFORE the POST so
    # even a crash mid-request leaves evidence to reconcile against.
    class Transfer < ActiveRecord::Base
      self.table_name = "solrengine_sdp_transfers"

      # ~5000 lamports: one signature's network fee, held back from the
      # spendable balance so a SOL send can pay for its own transaction.
      FEE_BUFFER = BigDecimal("0.000005")

      # App memo and engine token compose rather than replace each other:
      # "rent | sdp-1a2b3c4d5e6f7a8b". The token half is what timeout
      # reconciliation scans for; the app half survives round-trip to chain.
      MEMO_TOKEN_PREFIX = "sdp-"
      MEMO_SEPARATOR = " | "

      STATUSES = %w[processing confirmed finalized failed expired unknown].freeze
      # confirmed is NOT terminal: it is user-facing success, but tracking
      # continues until SDP reports finalized.
      TERMINAL_STATUSES = %w[finalized failed expired].freeze

      SDP_STATUS_MAP = {
        "pending" => "processing",
        "processing" => "processing",
        "confirmed" => "confirmed",
        "finalized" => "finalized",
        "failed" => "failed"
      }.freeze

      validates :source_wallet_id, :destination, :token, :amount, :memo_token, presence: true
      validates :status, inclusion: { in: STATUSES }

      # Rows TrackTransferJob still owes a verdict on — includes confirmed,
      # which is user-facing success but not yet finalized (tracking continues
      # until SDP reports finalized).
      scope :unsettled, -> { where.not(status: TERMINAL_STATUSES) }
      scope :terminal, -> { where(status: TERMINAL_STATUSES) }

      class << self
        # Creates the row, runs the balance preflight, POSTs the transfer to
        # SDP exactly once, and enqueues confirmation tracking. Returns the
        # row in whatever state the POST left it (the app renders from it).
        #
        # Raises InsufficientBalance — before any row or POST — when the
        # preflight shows the SOL balance can't cover amount + FEE_BUFFER.
        def execute!(source:, destination:, amount:, token: "SOL", memo: nil)
          # Normalize to a plain decimal string ("1.5", never "0.15e1"):
          # stored and sent as a string so no float drift ever touches money.
          amount = BigDecimal(amount.to_s).to_s("F")

          # Preflight is SOL-only in v0.1 (SPL would need the mint row plus a
          # separate SOL fee check); for SPL tokens the POST is the authority.
          ensure_balance_covers!(source, amount) if token == "SOL"

          transfer = create!(
            source_wallet_id: source,
            destination: destination,
            token: token,
            amount: amount,
            memo: memo,
            memo_token: "#{MEMO_TOKEN_PREFIX}#{SecureRandom.hex(8)}",
            status: "processing",
            submitted_at: Time.current
          )
          transfer.submit_to_sdp!
          TrackTransferJob.perform_later(transfer) unless transfer.terminal?
          transfer
        end

        # Recovery entry point: re-enqueues TrackTransferJob for unsettled
        # rows nothing is tracking anymore. Closes the crash window between
        # create!/submit_to_sdp! and the tracking enqueue, and adopts orphans
        # after queue data loss. The updated_at guard (two poll intervals)
        # avoids double-enqueueing rows under ACTIVE tracking — every poll
        # and settle touches the row, so a row untouched for two intervals
        # has no live tracker. Returns the count enqueued.
        def resume_tracking!
          cutoff = Time.current - (Solrengine::Sdp.configuration.transfer_poll_interval * 2)
          count = 0
          unsettled.where(updated_at: ..cutoff).find_each do |transfer|
            TrackTransferJob.perform_later(transfer)
            count += 1
          end
          count
        end

        def engine_status_for(sdp_status)
          # Unrecognized SDP statuses map to "processing": non-terminal, keep
          # polling — safer than inventing a verdict for a status SDP adds in
          # a later version.
          SDP_STATUS_MAP.fetch(sdp_status.to_s, "processing")
        end

        private

        # Never hand SDP a transfer that can't pay for itself — but only
        # block on a balance we positively read. A nil balance (SOL row
        # missing or balances unreadable) does NOT block: SDP omits rows on
        # RPC hiccups, and the POST — not the preflight — is the authority
        # on whether the transfer can execute.
        def ensure_balance_covers!(wallet_id, amount)
          balance = sol_balance(wallet_id)
          return if balance.nil?

          required = BigDecimal(amount) + FEE_BUFFER
          return unless required > balance

          raise InsufficientBalance,
            "Insufficient SOL: wallet #{wallet_id} holds #{balance.to_s("F")} SOL but " \
            "#{required.to_s("F")} is required (#{amount} + #{FEE_BUFFER.to_s("F")} fee buffer)."
        end

        # SOL balance as BigDecimal, or nil when unknown — nil is never zero.
        def sol_balance(wallet_id)
          row = Solrengine::Sdp.client.wallet_balances(wallet_id).find { |b| b.token == "SOL" }
          return nil if row.nil? || row.ui_amount.nil?

          BigDecimal(row.ui_amount.to_s)
        rescue ::Sdp::Error, ArgumentError, TypeError
          nil
        end
      end

      STATUSES.each do |name|
        define_method("#{name}?") { status == name }
      end

      def terminal?
        TERMINAL_STATUSES.include?(status)
      end

      # The memo actually sent to SDP: app memo (when given) + engine token.
      def composed_memo
        [ memo, memo_token ].compact.join(MEMO_SEPARATOR)
      end

      # The single, never-retried POST. Every outcome lands on the row:
      #
      #   success        → adopt SDP's id/status/signature (mapped status)
      #   SigningPending → stay processing; 202 details noted on sdp_error
      #   Timeout        → "unknown" (outcome unknown — reconcile by memo token)
      #   Unavailable    → "failed", "unsent:" prefix (request never processed)
      #   other Sdp::Error (TransferExecutionError/TransactionFailed/rejections)
      #                  → "failed" with the renderable message (AE2)
      def submit_to_sdp!
        adopt!(
          Solrengine::Sdp.client.create_transfer(
            source: source_wallet_id,
            destination: destination,
            amount: amount,
            token: token,
            memo: composed_memo
          )
        )
      rescue ::Sdp::SigningPending => e
        # HTTP 202: accepted, awaiting additional signatures. Non-terminal —
        # tracked like any processing transfer once SDP exposes the id.
        update!(
          status: "processing",
          sdp_transfer_id: e.details.is_a?(Hash) ? (e.details[:transfer_id] || e.details[:id]) : nil,
          sdp_error: "signing_pending: #{e.message}"
        )
      rescue ::Sdp::Timeout
        # Read timeout on the POST: SDP may or may not have executed it.
        # NEVER re-POST; TrackTransferJob reconciles via the memo token.
        update!(status: "unknown")
      rescue ::Sdp::Unavailable => e
        # Connection refused/reset or a 5xx without SDP's error shape: the
        # request was never processed, so no money moved. The "unsent:"
        # prefix distinguishes this from an on-chain failure.
        settle!("failed", sdp_error: "unsent: #{e.message}")
      rescue ::Sdp::Error => e
        # TransferExecutionError (the Kora/FL-11 gate, AE2), TransactionFailed,
        # and every other SDP rejection: terminal, message renderable as-is.
        settle!("failed", sdp_error: e.message)
      end

      # Maps an Sdp::Transfer struct onto this row per the status table.
      # Tolerates omitted optional fields (struct members are nil): existing
      # id/signature are never clobbered with nil.
      def adopt!(sdp_transfer)
        mapped = self.class.engine_status_for(sdp_transfer.status)
        attributes = {
          sdp_transfer_id: sdp_transfer.id || sdp_transfer_id,
          sdp_status: sdp_transfer.status,
          status: mapped,
          signature: sdp_transfer.signature || signature
        }
        attributes[:sdp_error] = sdp_transfer.error if sdp_transfer.error
        attributes[:settled_at] = Time.current if TERMINAL_STATUSES.include?(mapped) && settled_at.nil?
        update!(attributes)
      end

      # Lands the row in a terminal state and timestamps the verdict.
      def settle!(terminal_status, sdp_error: nil)
        update!(
          status: terminal_status,
          sdp_error: sdp_error || self[:sdp_error],
          settled_at: Time.current
        )
      end
    end
  end
end
