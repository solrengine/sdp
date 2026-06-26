# frozen_string_literal: true

require "bigdecimal"
require "securerandom"

module Solrengine
  module Sdp
    # Engine-owned record of a token issued through SDP: registered off-chain
    # (create_token), then deployed on-chain (deploy_token), then minted/burned
    # via supply actions. Mirrors Transfer's "the row is the audit trail"
    # posture. Mint authority is signing_wallet_id (a custodial treasury wallet).
    class Token < ActiveRecord::Base
      self.table_name = "solrengine_sdp_tokens"

      STATUSES = %w[created deployed failed].freeze

      has_many :mints, class_name: "Solrengine::Sdp::TokenMint", dependent: :destroy
      has_many :burns, class_name: "Solrengine::Sdp::TokenBurn", dependent: :destroy

      validates :name, :symbol, :signing_wallet_id, presence: true
      validates :decimals, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
      validates :status, inclusion: { in: STATUSES }

      def deployed?
        mint_address.present?
      end

      class << self
        # Registers the token with SDP (off-chain record) and persists it.
        # Raises Sdp::Error if SDP rejects it (no row is created).
        def register!(name:, symbol:, signing_wallet_id:, decimals: 0)
          sdp = Solrengine::Sdp.client.create_token(
            name: name, symbol: symbol, decimals: decimals, signing_wallet_id: signing_wallet_id
          )
          create!(
            name: name, symbol: symbol, decimals: decimals,
            signing_wallet_id: signing_wallet_id, sdp_token_id: sdp.id, status: "created"
          )
        end
      end

      # Custodial sign-and-send deploy → on-chain mint. Records the mint
      # address; on failure the row is marked failed and the error re-raised
      # for the caller to render. Never retried (money-path).
      def deploy!
        sdp = Solrengine::Sdp.client.deploy_token(sdp_token_id)
        update!(mint_address: sdp.mint_address, status: "deployed")
        self
      rescue ::Sdp::Error => e
        update!(status: "failed", sdp_error: e.message)
        raise
      end

      # Records a mint and enqueues MintJob (the mint POST runs off the web
      # request, never retried). amount is a DECIMAL token amount — SDP scales
      # it by the token's decimals (whole numbers for a 0-decimal token).
      # Returns the TokenMint row.
      def mint!(destination:, amount:, memo: nil)
        mint = mints.create!(
          destination: destination,
          amount: normalize_amount(amount),
          memo: memo,
          memo_token: "#{TokenMint::MEMO_TOKEN_PREFIX}#{SecureRandom.hex(8)}",
          status: "minting",
          submitted_at: Time.current
        )
        MintJob.perform_later(mint)
        mint
      end

      # Records a burn and enqueues BurnJob (never retried). A burn is signed
      # by the source wallet's owner, so signing_wallet_id is the holder's
      # custodial wallet (the user), NOT the treasury. Returns the TokenBurn.
      def burn!(source:, signing_wallet_id:, amount:, memo: nil)
        burn = burns.create!(
          source: source,
          signing_wallet_id: signing_wallet_id,
          amount: normalize_amount(amount),
          memo: memo,
          memo_token: "#{TokenBurn::MEMO_TOKEN_PREFIX}#{SecureRandom.hex(8)}",
          status: "burning",
          submitted_at: Time.current
        )
        BurnJob.perform_later(burn)
        burn
      end

      private

      # BigDecimal#to_s("F") always renders a trailing ".0" — so a whole "10"
      # becomes "10.0", which a 0-decimal token refuses ("Amount has too many
      # decimal places"). Drop trailing fractional zeros (and the now-bare
      # decimal point) so whole amounts go out as "10". SDP still enforces the
      # token's decimals, so an over-precise amount surfaces as a failed write.
      def normalize_amount(value)
        BigDecimal(value.to_s).to_s("F").sub(/\.?0+\z/, "")
      end
    end
  end
end
