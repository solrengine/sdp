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
    #   unknown (the create POST read-timed out, the row never got an SDP id,
    #     or SDP 404ed the id we had) → reconcile: scan the source wallet's
    #     transfers for the engine memo token. Found → adopt the SDP row and
    #     keep tracking; not found → re-enqueue and scan again until the
    #     deadline settles it as failed "unsent (reconcile exhausted)".
    #
    # Deadline exhaustion is checked at the top of perform, BEFORE any SDP
    # I/O, so an SDP outage can never keep a row unsettled past its deadline
    # (an in-poll check would only fire after a successful GET).
    #
    # API errors never orphan a row (mirrors ProvisionWalletJob's posture):
    # Unavailable/Timeout propagate to retry_on; NotFound flips the row to
    # "unknown" so the memo token — not a 404 poll loop — decides; any other
    # Sdp::Error re-enqueues within the deadline and settles the row failed
    # (message renderable) past it.
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
        return if settle_past_deadline(transfer)

        if transfer.unknown?
          reconcile(transfer)
        else
          poll(transfer)
        end
      rescue ::Sdp::Unavailable, ::Sdp::Timeout
        raise # transport: retry_on owns backoff and the exhaustion handoff
      rescue ::Sdp::NotFound
        # The id provably doesn't exist at SDP — polling it would 404
        # forever. Reconcile by memo token instead: it positively identifies
        # OUR attempt (found → adopt; never found → the deadline settles
        # the row as unsent).
        transfer.update!(status: "unknown")
        reenqueue(transfer)
      rescue ::Sdp::Error => e
        # Auth/rate-limit/validation errors must never strand the row in a
        # dead-letter: within the deadline they read as an API hiccup —
        # re-enqueue and try again; past it the row settles failed with the
        # renderable reason.
        if past_deadline?(transfer)
          transfer.settle!("failed", sdp_error: e.message)
        else
          reenqueue(transfer)
        end
      end

      private

      # Deadline exhaustion, decided BEFORE any SDP I/O so the verdict lands
      # even while SDP is down. Only processing rows expire — a confirmed row
      # past the deadline is user-facing success already; expiring it would
      # retract money the user saw move, so it keeps polling for finalized.
      # Returns true when the row was settled.
      def settle_past_deadline(transfer)
        return false unless past_deadline?(transfer)

        if transfer.processing?
          transfer.settle!("expired")
        elsif transfer.unknown?
          # Reuses expired_transfer_deadline as the reconcile deadline: if
          # the transfer existed, the scan would have found the memo token
          # by now.
          transfer.settle!("failed", sdp_error: "unsent (reconcile exhausted)")
        else
          return false
        end

        true
      end

      def poll(transfer)
        # A SigningPending 202 whose details carried no id leaves a
        # processing row with no sdp_transfer_id — there is nothing to GET
        # (get_transfer(nil) is a malformed URL). Flip to "unknown" and
        # reconcile by memo token, exactly like a timed-out create.
        if transfer.sdp_transfer_id.nil?
          transfer.update!(status: "unknown")
          return reconcile(transfer)
        end

        transfer.adopt!(Solrengine::Sdp.client.get_transfer(transfer.sdp_transfer_id))
        reenqueue(transfer) unless transfer.terminal?
      end

      def reconcile(transfer)
        match = find_by_memo_token(transfer)

        if match
          transfer.adopt!(match)
          reenqueue(transfer) unless transfer.terminal?
        else
          # Deadline exhaustion settles in perform, before any I/O; within
          # the deadline, scan again next interval.
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
