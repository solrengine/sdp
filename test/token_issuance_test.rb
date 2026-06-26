# frozen_string_literal: true

require_relative "test_helper"

module Solrengine
  module Sdp
    # The issuance Token model + MintJob — the engine half of M3 Workstream C.
    # Mint is a single never-retried POST (no idempotency key); the atomic
    # claim guarantees a mint is never sent twice.
    class TokenIssuanceTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper

      BASE_URL = "http://sdp.test:8787"
      ISSUANCE = "#{BASE_URL}/v1/issuance/tokens".freeze
      JSON_HEADERS = { "Content-Type" => "application/json" }.freeze

      def setup
        Solrengine::Sdp.reset_configuration!
        Solrengine::Sdp.configure do |c|
          c.api_key = "test-key"
          c.base_url = BASE_URL
        end
        Solrengine::Sdp::TokenMint.delete_all
        Solrengine::Sdp::Token.delete_all
      end

      def teardown
        Solrengine::Sdp.reset_configuration!
        super # webmock/minitest resets stubs + history
      end

      def deployed_token
        Solrengine::Sdp::Token.create!(name: "Points", symbol: "PTS", decimals: 0,
          signing_wallet_id: "wal_treasury", sdp_token_id: "tok_1", mint_address: "Mint1", status: "deployed")
      end

      # Records the wallet addresses Broadcaster.call is invoked with while the
      # block runs, restoring the real method after (no minitest/mock dep).
      def capturing_broadcasts
        rung = []
        original = Solrengine::Sdp::Broadcaster.method(:call)
        Solrengine::Sdp::Broadcaster.singleton_class.send(:define_method, :call) { |addr, *| rung << addr }
        yield
        rung
      ensure
        Solrengine::Sdp::Broadcaster.singleton_class.send(:define_method, :call, original)
      end

      def stub_mint(body)
        stub_request(:post, "#{ISSUANCE}/tok_1/mint")
          .to_return(status: 200, headers: JSON_HEADERS, body: body.to_json)
      end

      # -- register! / deploy! ----------------------------------------------------

      def test_register_creates_a_token_record
        stub_request(:post, ISSUANCE)
          .to_return(status: 201, headers: JSON_HEADERS, body: { data: { token: { id: "tok_1", status: "pending" } }, meta: {} }.to_json)

        token = Solrengine::Sdp::Token.register!(name: "Points", symbol: "PTS", signing_wallet_id: "wal_t")

        assert_equal "tok_1", token.sdp_token_id
        assert_equal "created", token.status
        assert_not token.deployed?
      end

      def test_deploy_records_the_mint_address
        token = Solrengine::Sdp::Token.create!(name: "Points", symbol: "PTS", signing_wallet_id: "wal_t", sdp_token_id: "tok_1", status: "created")
        stub_request(:post, "#{ISSUANCE}/tok_1/deploy")
          .to_return(status: 200, headers: JSON_HEADERS, body: { data: { token: { status: "active", mintAddress: "MintAddr" } }, meta: {} }.to_json)

        token.deploy!

        assert token.deployed?
        assert_equal "MintAddr", token.mint_address
        assert_equal "deployed", token.status
      end

      def test_deploy_failure_marks_failed_and_re_raises
        token = Solrengine::Sdp::Token.create!(name: "Points", symbol: "PTS", signing_wallet_id: "wal_t", sdp_token_id: "tok_1", status: "created")
        stub_request(:post, "#{ISSUANCE}/tok_1/deploy")
          .to_return(status: 400, headers: JSON_HEADERS, body: { error: { code: "BAD_REQUEST", message: "boom" }, meta: {} }.to_json)

        assert_raises(::Sdp::BadRequest) { token.deploy! }
        assert_equal "failed", token.reload.status
      end

      # -- mint! records + enqueues -----------------------------------------------

      def test_mint_records_a_pending_mint_and_enqueues_the_job
        token = deployed_token
        assert_enqueued_jobs 1, only: Solrengine::Sdp::MintJob do
          mint = token.mint!(destination: "user_wallet", amount: 100)
          assert mint.minting?
          # Whole amounts go out WITHOUT a trailing ".0" — SDP rejects "100.0"
          # for a 0-decimal token ("Amount has too many decimal places").
          assert_equal "100", mint.amount
          assert_equal token, mint.token
        end
      end

      def test_mint_amount_is_normalized_to_a_clean_decimal_string
        token = deployed_token
        # whole numbers (int, float, decimal-string) never carry a ".0";
        # genuine fractions keep their places but shed trailing zeros.
        {
          10 => "10", 50.0 => "50", "1000" => "1000",
          "1.50" => "1.5", "0.5" => "0.5"
        }.each do |given, expected|
          assert_equal expected, token.mint!(destination: "w", amount: given).amount,
            "amount #{given.inspect} should store as #{expected.inspect}"
        end
      end

      # -- MintJob outcomes -------------------------------------------------------

      def test_mint_job_confirms_into_minted
        token = deployed_token
        stub = stub_mint(data: { transaction: { id: "tx_1", status: "confirmed", signature: "Sig1" }, token_account: "ata_1" }, meta: {})

        perform_enqueued_jobs { token.mint!(destination: "user_wallet", amount: 5) }

        mint = Solrengine::Sdp::TokenMint.last
        assert mint.minted?
        assert_equal "Sig1", mint.signature
        assert_equal "ata_1", mint.token_account
        assert_requested stub, times: 1
      end

      def test_mint_job_marks_failed_on_sdp_error
        token = deployed_token
        stub_request(:post, "#{ISSUANCE}/tok_1/mint")
          .to_return(status: 400, headers: JSON_HEADERS, body: { error: { code: "BAD_REQUEST", message: "nope" }, meta: {} }.to_json)

        perform_enqueued_jobs { token.mint!(destination: "u", amount: 1) }

        mint = Solrengine::Sdp::TokenMint.last
        assert mint.failed?
        assert_equal "nope", mint.sdp_error
      end

      def test_mint_read_timeout_lands_unknown_and_is_not_retried
        token = deployed_token
        # A reset on the POST is an unknown outcome (a re-send could double-mint).
        stub = stub_request(:post, "#{ISSUANCE}/tok_1/mint").to_raise(Errno::ECONNRESET)

        perform_enqueued_jobs { token.mint!(destination: "u", amount: 1) }

        mint = Solrengine::Sdp::TokenMint.last
        assert mint.unknown?
        assert_requested stub, times: 1 # never re-POSTed
      end

      def test_a_mint_is_never_sent_twice
        token = deployed_token
        stub = stub_mint(data: { transaction: { id: "tx", status: "confirmed" } }, meta: {})

        mint = token.mint!(destination: "u", amount: 1)
        Solrengine::Sdp::MintJob.perform_now(mint)
        Solrengine::Sdp::MintJob.perform_now(mint) # second run must not re-POST

        assert_requested stub, times: 1
        assert mint.reload.minted?
      end

      def test_mint_job_rings_the_balance_doorbell_for_the_destination_on_success
        token = deployed_token
        stub_mint(data: { transaction: { id: "tx_1", status: "confirmed" } }, meta: {})
        mint = token.mint!(destination: "UserWallet", amount: 5)

        rung = capturing_broadcasts { Solrengine::Sdp::MintJob.perform_now(mint) }

        assert mint.reload.minted?
        assert_equal [ "UserWallet" ], rung, "a confirmed mint should ring the destination's balance doorbell"
      end

      def test_mint_job_does_not_broadcast_when_the_mint_is_not_minted
        token = deployed_token
        stub_request(:post, "#{ISSUANCE}/tok_1/mint")
          .to_return(status: 400, headers: JSON_HEADERS, body: { error: { code: "BAD_REQUEST", message: "no" }, meta: {} }.to_json)
        mint = token.mint!(destination: "UserWallet", amount: 5)

        rung = capturing_broadcasts { Solrengine::Sdp::MintJob.perform_now(mint) }

        assert mint.reload.failed?
        assert_empty rung, "a failed mint must not broadcast"
      end

      # -- burn (redeem) ----------------------------------------------------------

      def stub_burn(body)
        stub_request(:post, "#{ISSUANCE}/tok_1/burn")
          .to_return(status: 200, headers: JSON_HEADERS, body: body.to_json)
      end

      def test_burn_records_a_pending_burn_and_enqueues_the_job
        token = deployed_token
        assert_enqueued_jobs 1, only: Solrengine::Sdp::BurnJob do
          burn = token.burn!(source: "user_pubkey", signing_wallet_id: "wal_user", amount: 3)
          assert burn.burning?
          assert_equal "3", burn.amount
          assert_equal "wal_user", burn.signing_wallet_id
        end
      end

      def test_burn_job_confirms_into_burned
        token = deployed_token
        stub = stub_burn(data: { transaction: { id: "tx_b", status: "confirmed", signature: "BurnSig" } }, meta: {})

        perform_enqueued_jobs { token.burn!(source: "user_pubkey", signing_wallet_id: "wal_user", amount: 3) }

        burn = Solrengine::Sdp::TokenBurn.last
        assert burn.burned?
        assert_equal "BurnSig", burn.signature
        assert_requested stub, times: 1
      end

      def test_burn_read_timeout_lands_unknown_and_is_not_retried
        token = deployed_token
        stub = stub_request(:post, "#{ISSUANCE}/tok_1/burn").to_raise(Errno::ECONNRESET)

        perform_enqueued_jobs { token.burn!(source: "u", signing_wallet_id: "wal_user", amount: 1) }

        assert Solrengine::Sdp::TokenBurn.last.unknown?
        assert_requested stub, times: 1
      end

      def test_a_burn_is_never_sent_twice
        token = deployed_token
        stub = stub_burn(data: { transaction: { id: "tx", status: "confirmed" } }, meta: {})

        burn = token.burn!(source: "u", signing_wallet_id: "wal_user", amount: 1)
        Solrengine::Sdp::BurnJob.perform_now(burn)
        Solrengine::Sdp::BurnJob.perform_now(burn)

        assert_requested stub, times: 1
        assert burn.reload.burned?
      end

      def test_burn_job_rings_the_balance_doorbell_for_the_source_on_success
        token = deployed_token
        stub_burn(data: { transaction: { id: "tx_b", status: "confirmed" } }, meta: {})
        burn = token.burn!(source: "HolderWallet", signing_wallet_id: "wal_user", amount: 3)

        rung = capturing_broadcasts { Solrengine::Sdp::BurnJob.perform_now(burn) }

        assert burn.reload.burned?
        assert_equal [ "HolderWallet" ], rung, "a confirmed burn should ring the source's balance doorbell"
      end
    end
  end
end
