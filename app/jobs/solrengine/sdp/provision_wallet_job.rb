# frozen_string_literal: true

module Solrengine
  module Sdp
    # Provisions an SDP custody wallet for a WalletOwner row, driving the
    # four-state machine: pending → provisioning → ready | failed.
    #
    # Idempotent three ways:
    #
    #   1. The row is already ready → return immediately.
    #   2. Optimistic claim: only the job that flips the row pending/failed →
    #      provisioning proceeds; a duplicate concurrent job updates 0 rows
    #      and returns without touching the network. A provisioning row whose
    #      lease has lapsed (worker died between claim and settle) may be
    #      taken over — see #claim.
    #   3. Label adoption: when SDP already has a wallet labeled
    #      "#{namespace}-user-#{id}" (a previous create succeeded but the
    #      response was lost, e.g. a read timeout), adopt it instead of
    #      creating a duplicate.
    #
    # Failure posture:
    #
    #   - Transport errors (Unavailable/Timeout) retry with backoff; the claim
    #     stays held across retries (see #claim). Exhaustion lands the row in
    #     failed with the transport reason — never a silent dead-letter.
    #   - ProviderCapabilityError (the FL-10 gate: local custody cannot create
    #     per-user wallets) is terminal: failed immediately, with the
    #     actionable "use a managed provider" message renderable to the app.
    #   - Any other Sdp::Error is equally terminal — retrying auth/validation
    #     bugs changes nothing; the reason is stored, not buried in logs.
    #
    # Inherits ActiveJob::Base directly so the engine never depends on the
    # host app's ApplicationJob being defined or compatible.
    class ProvisionWalletJob < ActiveJob::Base
      queue_as :default

      # User deleted between enqueue and perform: nothing to provision.
      discard_on ActiveJob::DeserializationError

      # Block form fires on exhaustion (after the final attempt): settle the
      # row in failed with the transport reason so the app can render it and
      # offer retry_provisioning!.
      retry_on ::Sdp::Unavailable, ::Sdp::Timeout,
               wait: :polynomially_longer, attempts: 5 do |job, error|
        job.mark_provisioning_failed(job.arguments.first, "Retries exhausted: #{error.message}")
      end

      def perform(user)
        return if user.wallet_ready?
        return unless claim(user)

        wallet = existing_wallet_for(user) || create_wallet_for(user)
        user.update!(
          sdp_wallet_id: wallet.id,
          wallet_address: wallet.public_key,
          sdp_provisioning_state: "ready",
          sdp_provisioning_error: nil
        )
      rescue ::Sdp::Unavailable, ::Sdp::Timeout
        raise # retry_on handles backoff; the claim stays held for the retry
      rescue ::Sdp::Error => e
        # Terminal: capability gates (AE1) and auth/validation errors fail the
        # same way no matter how often they are retried. Reason is renderable.
        mark_provisioning_failed(user, e.message)
      end

      # Settles the row in failed — but only when this job holds the claim
      # (row is in provisioning), so a stale job can never clobber a row
      # another job has since taken to ready. Public because the retry_on
      # exhaustion block runs outside the instance's private context.
      def mark_provisioning_failed(user, reason)
        user.class
            .where(id: user.id, sdp_provisioning_state: "provisioning")
            .update_all(sdp_provisioning_state: "failed", sdp_provisioning_error: reason)
      end

      private

      # Optimistic claim: flip pending/failed → provisioning guarded by the
      # current state; 1 row updated means this job owns the row, 0 means a
      # concurrent job does — return without any network traffic. Retry
      # executions (executions > 1) may resume from provisioning, because the
      # claim was kept across the transient failure that triggered the retry.
      #
      # Stale-claim takeover: ANY execution (fresh jobs included, not just
      # retries) may also take over a provisioning row whose updated_at is
      # older than Configuration#provisioning_lease — a worker that died
      # between claim and settle would otherwise strand the row forever.
      # Takeover is safe because label adoption makes re-running safe: a
      # completed-but-unrecorded create is adopted by label, so takeover
      # cannot double-provision. And the lease prevents takeover of a LIVE
      # job — every claim renews updated_at, and any live job's retries and
      # settles touch updated_at well within the lease.
      def claim(user)
        claimable = %w[pending failed]
        claimable += [ "provisioning" ] if executions > 1

        lease_cutoff = Time.current - Solrengine::Sdp.configuration.provisioning_lease

        user.class
            .where(id: user.id, sdp_provisioning_state: claimable)
            .or(
              user.class.where(id: user.id, sdp_provisioning_state: "provisioning")
                        .where(updated_at: ..lease_cutoff)
            )
            .update_all(sdp_provisioning_state: "provisioning", updated_at: Time.current) == 1
      end

      # GET /v1/wallets is not paginated at SDP v0.28 — the full list comes
      # back in one response. list_wallets already routes through the client
      # gem's paginating enumerator, so if SDP adds transfers-style pagination
      # to wallets this scan keeps working unchanged.
      def existing_wallet_for(user)
        Solrengine::Sdp.client.list_wallets.find { |wallet| wallet.label == user.sdp_wallet_label }
      end

      def create_wallet_for(user)
        Solrengine::Sdp.client.create_wallet(
          label: user.sdp_wallet_label,
          provider: Solrengine::Sdp.configuration.custody_provider
        )
      end
    end
  end
end
