# frozen_string_literal: true

require "active_support/concern"

module Solrengine
  module Sdp
    # Mixin for the host app's user (wallet-owner) model. Expects four columns
    # (the install generator adds them):
    #
    #   sdp_wallet_id           :string  — SDP's walletId once provisioned
    #   wallet_address          :string  — the wallet's Solana public key
    #   sdp_provisioning_state  :string, default: "pending", null: false
    #   sdp_provisioning_error  :string  — renderable failure reason
    #
    # Provisioning is a state machine, not a fire-and-forget job:
    #
    #   pending → provisioning → ready | failed
    #   failed  → pending                          (retry_provisioning!)
    #
    # ProvisionWalletJob drives every transition; "still provisioning" and
    # "permanently wallet-less" are always distinguishable, and a failure
    # carries a reason the app can render and re-trigger.
    #
    # Provisioning timing is the app's call — the concern deliberately wires
    # NO callback. To provision on signup, add one line to the host model:
    #
    #   after_create_commit :provision_wallet!
    #
    # States are plain strings rather than a Rails enum so the mixin cannot
    # collide with the host model's own enums or generated methods.
    module WalletOwner
      extend ActiveSupport::Concern

      PROVISIONING_STATES = %w[pending provisioning ready failed].freeze

      included do
        # Users whose custody wallet is fully provisioned — the only ones that
        # can move money or appear in wallet-keyed UI (recipients, feeds).
        scope :wallet_ready, -> { where(sdp_provisioning_state: "ready") }
      end

      # Tolerates NULL (rows predating the column default): no state is pending.
      def wallet_provisioning_state
        self[:sdp_provisioning_state].presence || "pending"
      end

      def wallet_pending?
        wallet_provisioning_state == "pending"
      end

      def wallet_provisioning?
        wallet_provisioning_state == "provisioning"
      end

      def wallet_ready?
        wallet_provisioning_state == "ready"
      end

      def wallet_failed?
        wallet_provisioning_state == "failed"
      end

      # SDP wallet label this user provisions under. The namespace prefix
      # guards against cross-app collisions when several apps share one SDP
      # project (see Configuration#label_namespace).
      def sdp_wallet_label
        "#{Solrengine::Sdp.configuration.label_namespace}-user-#{id}"
      end

      # Enqueues provisioning. No-op (with a log line) when the wallet is
      # already ready or a job currently owns the row; from failed it
      # re-enqueues — the job's claim accepts failed rows, so an explicit
      # reset via retry_provisioning! is equivalent but also clears the error.
      def provision_wallet!
        if wallet_ready? || wallet_provisioning?
          Solrengine::Sdp.configuration.logger&.info(
            "[Solrengine::Sdp] provision_wallet! no-op for #{self.class.name}##{id}: " \
            "state is #{wallet_provisioning_state}"
          )
          return false
        end

        ProvisionWalletJob.perform_later(self)
      end

      # Re-arms a failed row: clears the stored reason, resets to pending, and
      # enqueues a fresh job. Only valid from failed — anything else is a
      # no-op returning false.
      def retry_provisioning!
        return false unless wallet_failed?

        update!(sdp_provisioning_state: "pending", sdp_provisioning_error: nil)
        ProvisionWalletJob.perform_later(self)
      end
    end
  end
end
