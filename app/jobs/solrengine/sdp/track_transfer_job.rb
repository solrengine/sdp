# frozen_string_literal: true

module Solrengine
  module Sdp
    # Settles every Transfer row into a terminal state (R6). Two modes,
    # keyed on the row's status:
    #
    #   processing/confirmed → poll get_transfer, map per the status table,
    #     re-enqueue until terminal. A row stuck in processing past
    #     Configuration#expired_transfer_deadline settles as engine-local
    #     "expired" (SDP has no such status). confirmed keeps tracking —
    #     it is user-facing success, but finalized is the terminal verdict.
    #
    #   unknown (the create POST read-timed out) → reconcile: scan the source
    #     wallet's transfers for the engine memo token. Found → adopt the SDP
    #     row and keep tracking; not found past the deadline → settle as
    #     failed "unsent (reconcile exhausted)"; not found within it →
    #     re-enqueue and scan again.
    #
    # Backoff: a simple fixed wait (Configuration#transfer_poll_interval,
    # default 3s) rather than exponential — Solana confirmation latency is
    # bounded at seconds, and expired_transfer_deadline caps total tracking,
    # so growing waits would only delay the verdict.
    #
    # Inherits ActiveJob::Base directly so the engine never depends on the
    # host app's ApplicationJob (same posture as ProvisionWalletJob).
    class TrackTransferJob < ActiveJob::Base
      queue_as :default

      # Transfer row deleted between enqueue and perform: nothing to track.
      discard_on ActiveJob::DeserializationError

      # Everything this job sends is a GET (get_transfer / list_transfers),
      # so transport failures are always safe to retry — unlike the create
      # POST, which is never retried. On exhaustion, hand off to a fresh job
      # after the normal poll interval instead of orphaning the row: polling
      # resumes when SDP comes back, and the expired deadline still bounds
      # how long a processing row can stay unsettled.
      retry_on ::Sdp::Unavailable, ::Sdp::Timeout,
               wait: :polynomially_longer, attempts: 5 do |job, _error|
        job.class.set(wait: job.class.poll_interval).perform_later(job.arguments.first)
      end

      def self.poll_interval
        Solrengine::Sdp.configuration.transfer_poll_interval.seconds
      end

      def perform(transfer)
        return if transfer.terminal?

        if transfer.unknown?
          reconcile(transfer)
        else
          poll(transfer)
        end
      end

      private

      def poll(transfer)
        transfer.adopt!(Solrengine::Sdp.client.get_transfer(transfer.sdp_transfer_id))
        return if transfer.terminal?

        # Only processing rows expire. A confirmed row past the deadline is
        # user-facing success already — expiring it would retract money the
        # user saw move; we keep polling for finalized instead.
        if transfer.processing? && past_deadline?(transfer)
          transfer.settle!("expired")
          return
        end

        reenqueue(transfer)
      end

      def reconcile(transfer)
        match = find_by_memo_token(transfer)

        if match
          transfer.adopt!(match)
          reenqueue(transfer) unless transfer.terminal?
        elsif past_deadline?(transfer)
          # Reuses expired_transfer_deadline as the reconcile deadline: if the
          # transfer existed, the scan would have found the memo token by now.
          transfer.settle!("failed", sdp_error: "unsent (reconcile exhausted)")
        else
          reenqueue(transfer)
        end
      end

      # Scans ALL pages of the source wallet's transfers through the lazy
      # enumerator. Simplest correct option: the match is normally on the
      # first page (the attempt just happened), SDP exposes no created-at
      # filter to cut the scan off at submitted_at, and the wallet-scoped
      # list is small for any one user. The memo token positively identifies
      # OUR attempt — no amount/recipient/time heuristics, so a concurrent
      # identical transfer can never be claimed as this one.
      def find_by_memo_token(transfer)
        Solrengine::Sdp.client
                       .list_transfers(wallet: transfer.source_wallet_id)
                       .find { |row| row.memo.to_s.include?(transfer.memo_token) }
      end

      def past_deadline?(transfer)
        Time.current - transfer.submitted_at > Solrengine::Sdp.configuration.expired_transfer_deadline
      end

      def reenqueue(transfer)
        self.class.set(wait: self.class.poll_interval).perform_later(transfer)
      end
    end
  end
end
