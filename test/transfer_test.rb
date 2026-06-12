# frozen_string_literal: true

require_relative "test_helper"

# Transfer.execute! — the create flow: preflight, claim-row-before-POST,
# single non-retried POST, every outcome persisted on the row.
class TransferTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  BASE_URL = "http://sdp.test:8787"
  TRANSFERS_URL = "#{BASE_URL}/v1/payments/transfers"
  BALANCES_URL = "#{BASE_URL}/v1/payments/wallets/wal_src/balances"
  JSON_HEADERS = { "Content-Type" => "application/json" }.freeze

  setup do
    Solrengine::Sdp.reset_configuration!
    Solrengine::Sdp.configure do |config|
      config.api_key = "test-key"
      config.base_url = BASE_URL
    end
    Solrengine::Sdp::Transfer.delete_all
  end

  teardown do
    Solrengine::Sdp.reset_configuration!
  end

  # --- happy path -----------------------------------------------------------

  def test_execute_creates_processing_row_with_sdp_id_and_enqueues_tracking
    stub_sol_balance("10")
    stub_request(:post, TRANSFERS_URL).to_return(
      status: 201, headers: JSON_HEADERS,
      body: { data: { transfer: { id: "tr_1", status: "pending", token: "SOL", amount: "1.5" } },
              meta: {} }.to_json
    )

    transfer = execute_transfer(amount: "1.5")

    assert transfer.processing?
    refute transfer.terminal?
    assert_equal "tr_1", transfer.sdp_transfer_id
    assert_equal "pending", transfer.sdp_status
    assert_equal "1.5", transfer.amount
    assert_not_nil transfer.submitted_at
    assert_nil transfer.settled_at
    assert_enqueued_with(job: Solrengine::Sdp::TrackTransferJob, args: [ transfer ])
  end

  def test_execute_with_synchronous_confirmation_lands_confirmed_and_keeps_tracking
    stub_sol_balance("10")
    stub_request(:post, TRANSFERS_URL).to_return(
      status: 201, headers: JSON_HEADERS,
      body: { data: { transfer: { id: "tr_1", status: "confirmed", signature: "5sigBase58" } },
              meta: {} }.to_json
    )

    transfer = execute_transfer

    assert transfer.confirmed?
    assert_equal "5sigBase58", transfer.signature
    assert_nil transfer.settled_at, "confirmed is user-facing success, not settled"
    assert_enqueued_with(job: Solrengine::Sdp::TrackTransferJob, args: [ transfer ])
  end

  # --- AE2: Kora gate vs generic outage --------------------------------------

  def test_kora_gate_502_lands_failed_with_the_kora_reason
    stub_sol_balance("10")
    stub_request(:post, TRANSFERS_URL).to_return(
      status: 502, headers: JSON_HEADERS,
      body: {
        error: {
          code: "SOLANA_RPC_ERROR",
          message: "NativeAdapter.signAndSend not supported - use KoraAdapter for gasless transactions"
        },
        meta: {}
      }.to_json
    )

    transfer = execute_transfer

    assert transfer.failed?
    assert transfer.terminal?
    assert_not_nil transfer.settled_at
    assert_includes transfer.sdp_error, "Kora"
    assert_equal 0, enqueued_jobs.size, "terminal at create: no tracking job"
  end

  def test_generic_502_lands_failed_unsent_with_no_kora_claim
    stub_sol_balance("10")
    stub_request(:post, TRANSFERS_URL).to_return(
      status: 502, body: "RPC node unreachable" # no SDP error shape → Unavailable
    )

    transfer = execute_transfer

    assert transfer.failed?
    assert transfer.sdp_error.start_with?("unsent:"), "Unavailable means the request was never processed"
    refute_includes transfer.sdp_error, "Kora"
    assert_equal 0, enqueued_jobs.size
  end

  # --- POST read-timeout: outcome unknown ------------------------------------

  def test_post_read_timeout_lands_unknown_and_enqueues_reconciliation
    stub_sol_balance("10")
    post_stub = stub_request(:post, TRANSFERS_URL).to_raise(Net::ReadTimeout)

    transfer = execute_transfer

    assert_requested post_stub, times: 1 # the POST is NEVER retried
    assert transfer.unknown?
    refute transfer.terminal?
    assert_nil transfer.sdp_transfer_id
    assert_enqueued_with(job: Solrengine::Sdp::TrackTransferJob, args: [ transfer ])
  end

  # --- TransactionFailed ------------------------------------------------------

  def test_on_chain_failure_lands_failed_with_the_renderable_reason
    stub_sol_balance("10")
    stub_request(:post, TRANSFERS_URL).to_return(
      status: 400, headers: JSON_HEADERS,
      body: { error: { code: "TRANSACTION_FAILED", message: "insufficient lamports for rent" },
              meta: {} }.to_json
    )

    transfer = execute_transfer

    assert transfer.failed?
    assert_includes transfer.sdp_error, "insufficient lamports"
    refute transfer.sdp_error.start_with?("unsent:"), "the transaction WAS attempted"
  end

  # --- 202 SIGNING_PENDING -----------------------------------------------------

  def test_signing_pending_202_keeps_processing_with_details_and_tracks
    stub_sol_balance("10")
    stub_request(:post, TRANSFERS_URL).to_return(
      status: 202, headers: JSON_HEADERS,
      body: {
        error: { code: "SIGNING_PENDING", message: "Awaiting additional signatures",
                 details: { transferId: "tr_9" } },
        meta: {}
      }.to_json
    )

    transfer = execute_transfer

    assert transfer.processing?
    assert transfer.sdp_error.start_with?("signing_pending:")
    assert_equal "tr_9", transfer.sdp_transfer_id
    assert_enqueued_with(job: Solrengine::Sdp::TrackTransferJob, args: [ transfer ])
  end

  def test_signing_pending_202_with_id_key_falls_back_to_sdp_id
    # details has { id: } but no { transferId: } — implementation reads
    # e.details[:transfer_id] || e.details[:id], so :id is the fallback.
    stub_sol_balance("10")
    stub_request(:post, TRANSFERS_URL).to_return(
      status: 202, headers: JSON_HEADERS,
      body: {
        error: { code: "SIGNING_PENDING", message: "Awaiting additional signatures",
                 details: { id: "tr_9" } },
        meta: {}
      }.to_json
    )

    transfer = execute_transfer

    assert transfer.processing?
    assert_equal "tr_9", transfer.sdp_transfer_id
    assert_enqueued_with(job: Solrengine::Sdp::TrackTransferJob, args: [ transfer ])
  end

  def test_signing_pending_202_with_non_hash_details_stays_processing_with_nil_id
    stub_sol_balance("10")
    stub_request(:post, TRANSFERS_URL).to_return(
      status: 202, headers: JSON_HEADERS,
      body: {
        error: { code: "SIGNING_PENDING", message: "Awaiting additional signatures",
                 details: "awaiting" },
        meta: {}
      }.to_json
    )

    transfer = execute_transfer

    assert transfer.processing?
    assert_nil transfer.sdp_transfer_id
    assert transfer.sdp_error.start_with?("signing_pending:")
    assert_enqueued_with(job: Solrengine::Sdp::TrackTransferJob, args: [ transfer ])
  end

  # --- balance preflight ---------------------------------------------------------

  def test_insufficient_balance_raises_without_creating_a_row_or_posting
    stub_sol_balance("0.5")

    assert_raises(Solrengine::Sdp::InsufficientBalance) do
      execute_transfer(amount: "1")
    end

    assert_equal 0, Solrengine::Sdp::Transfer.count
    assert_not_requested :post, TRANSFERS_URL
    assert_equal 0, enqueued_jobs.size
  end

  def test_missing_sol_balance_row_does_not_block_the_post
    # SDP omits balance rows on RPC hiccups — the POST is the authority.
    stub_request(:get, BALANCES_URL).to_return(
      status: 200, headers: JSON_HEADERS,
      body: { data: { walletBalances: { walletId: "wal_src", balances: [
        { token: "USDC", uiAmount: "5" }
      ] } }, meta: {} }.to_json
    )
    stub_pending_create

    transfer = execute_transfer

    assert transfer.processing?
    assert_requested :post, TRANSFERS_URL
  end

  def test_unreadable_balances_do_not_block_the_post
    stub_request(:get, BALANCES_URL).to_return(status: 503)
    stub_pending_create

    transfer = execute_transfer

    assert transfer.processing?
    assert_requested :post, TRANSFERS_URL
  end

  # --- non-SOL token: preflight is skipped entirely ----------------------------

  def test_non_sol_token_skips_balance_preflight_and_posts_directly
    # No balance stub registered — WebMock strict mode will raise if the GET fires.
    stub_pending_create

    transfer = Solrengine::Sdp::Transfer.execute!(
      source: "wal_src", destination: "Dest58Base", amount: "5", token: "USDC"
    )

    assert transfer.processing?
    assert_equal "tr_1", transfer.sdp_transfer_id
    assert_not_requested :get, BALANCES_URL
    assert_enqueued_with(job: Solrengine::Sdp::TrackTransferJob, args: [ transfer ])
  end

  # --- memo composition ------------------------------------------------------------

  def test_app_memo_composes_with_the_engine_token_and_is_sent_to_sdp
    stub_sol_balance("10")
    stub_pending_create

    transfer = execute_transfer(memo: "rent")

    assert_equal "rent", transfer.memo
    assert_match(/\Asdp-\h{16}\z/, transfer.memo_token)
    composed = "rent | #{transfer.memo_token}"
    assert_equal composed, transfer.composed_memo
    assert_requested(:post, TRANSFERS_URL) do |request|
      JSON.parse(request.body)["memo"] == composed
    end
  end

  def test_without_app_memo_the_engine_token_is_the_whole_memo
    stub_sol_balance("10")
    stub_pending_create

    transfer = execute_transfer

    assert_nil transfer.memo
    assert_equal transfer.memo_token, transfer.composed_memo
    assert_requested(:post, TRANSFERS_URL) do |request|
      JSON.parse(request.body)["memo"] == transfer.memo_token
    end
  end

  # --- mapping ---------------------------------------------------------------------

  def test_sdp_status_mapping_matches_the_table
    expected = {
      "pending" => "processing",
      "processing" => "processing",
      "confirmed" => "confirmed",
      "finalized" => "finalized",
      "failed" => "failed"
    }
    expected.each do |sdp_status, engine_status|
      assert_equal engine_status, Solrengine::Sdp::Transfer.engine_status_for(sdp_status)
    end
    # Unknown SDP statuses stay non-terminal so polling continues.
    assert_equal "processing", Solrengine::Sdp::Transfer.engine_status_for("brand-new-status")
  end

  def test_sdp_row_with_omitted_optional_fields_maps_cleanly
    stub_sol_balance("10")
    stub_request(:post, TRANSFERS_URL).to_return(
      status: 201, headers: JSON_HEADERS,
      body: { data: { transfer: { id: "tr_1", status: "pending" } }, meta: {} }.to_json
    )

    transfer = execute_transfer

    assert transfer.processing?
    assert_equal "tr_1", transfer.sdp_transfer_id
    assert_nil transfer.signature
    assert_nil transfer.sdp_error
  end

  def test_terminal_and_unsettled_semantics
    transfer = Solrengine::Sdp::Transfer.new
    terminal = { "processing" => false, "confirmed" => false, "finalized" => true,
                 "failed" => true, "expired" => true, "unknown" => false }
    terminal.each do |status, expectation|
      transfer.status = status
      assert_equal expectation, transfer.terminal?, "terminal?(#{status})"
    end

    rows = Solrengine::Sdp::Transfer::STATUSES.index_with do |status|
      Solrengine::Sdp::Transfer.create!(
        source_wallet_id: "wal_src", destination: "dest", token: "SOL", amount: "1",
        memo_token: "sdp-#{status}", status: status
      )
    end
    assert_equal [ rows["processing"], rows["confirmed"], rows["unknown"] ].map(&:id).sort,
                 Solrengine::Sdp::Transfer.unsettled.pluck(:id).sort
    assert_equal [ rows["finalized"], rows["failed"], rows["expired"] ].map(&:id).sort,
                 Solrengine::Sdp::Transfer.terminal.pluck(:id).sort
  end

  # --- resume_tracking! --------------------------------------------------------

  def test_resume_tracking_enqueues_stale_unsettled_rows_and_returns_the_count
    transfer = create_row(status: "processing", memo_token: "sdp-stale")
    # update_column: a touch would put the row back inside the active-tracking
    # window. 10s > 2 × the default 3s poll interval.
    transfer.update_column(:updated_at, 10.seconds.ago)

    count = nil
    assert_enqueued_with(job: Solrengine::Sdp::TrackTransferJob, args: [ transfer ]) do
      count = Solrengine::Sdp::Transfer.resume_tracking!
    end
    assert_equal 1, count
  end

  def test_resume_tracking_skips_terminal_rows
    row = create_row(status: "finalized", memo_token: "sdp-final")
    row.update_column(:updated_at, 10.seconds.ago)

    assert_no_enqueued_jobs do
      assert_equal 0, Solrengine::Sdp::Transfer.resume_tracking!
    end
  end

  def test_resume_tracking_skips_recently_touched_rows
    # updated_at is "now": an active tracker just touched the row — enqueueing
    # again would double-track it.
    create_row(status: "processing", memo_token: "sdp-live")

    assert_no_enqueued_jobs do
      assert_equal 0, Solrengine::Sdp::Transfer.resume_tracking!
    end
  end

  private

  def create_row(status:, memo_token:)
    Solrengine::Sdp::Transfer.create!(
      source_wallet_id: "wal_src", destination: "Dest58Base", token: "SOL", amount: "1",
      memo_token: memo_token, status: status, submitted_at: Time.current
    )
  end

  def execute_transfer(amount: "1", memo: nil)
    Solrengine::Sdp::Transfer.execute!(
      source: "wal_src", destination: "Dest58Base", amount: amount, memo: memo
    )
  end

  def stub_sol_balance(ui_amount)
    stub_request(:get, BALANCES_URL).to_return(
      status: 200, headers: JSON_HEADERS,
      body: { data: { walletBalances: { walletId: "wal_src", balances: [
        { token: "SOL", mint: "So11111111111111111111111111111111111111112",
          uiAmount: ui_amount, decimals: 9 }
      ] } }, meta: {} }.to_json
    )
  end

  def stub_pending_create
    stub_request(:post, TRANSFERS_URL).to_return(
      status: 201, headers: JSON_HEADERS,
      body: { data: { transfer: { id: "tr_1", status: "pending" } }, meta: {} }.to_json
    )
  end
end
