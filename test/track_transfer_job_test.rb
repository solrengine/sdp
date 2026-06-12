# frozen_string_literal: true

require_relative "test_helper"

# TrackTransferJob — polls every non-terminal transfer to a verdict and
# reconciles unknown-outcome rows by memo token.
class TrackTransferJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  BASE_URL = "http://sdp.test:8787"
  TRANSFERS_URL = "#{BASE_URL}/v1/payments/transfers"
  BALANCES_URL = "#{BASE_URL}/v1/payments/wallets/wal_src/balances"
  TRANSFER_URL = "#{TRANSFERS_URL}/tr_1"
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

  # --- terminal short-circuit --------------------------------------------------

  def test_terminal_row_returns_without_http
    transfer = create_row(status: "finalized", settled_at: Time.current)

    perform_track(transfer) # any HTTP call would raise (nothing stubbed)

    assert_equal 0, WebMock::RequestRegistry.instance.requested_signatures.hash.size
    assert_equal 0, enqueued_jobs.size
  end

  # --- polling -------------------------------------------------------------------

  def test_confirmed_is_user_facing_success_but_tracking_continues
    transfer = create_row
    stub_get_transfer(status: "confirmed", signature: "5sigBase58")

    perform_track(transfer)

    transfer.reload
    assert transfer.confirmed?
    assert_equal "confirmed", transfer.sdp_status
    assert_equal "5sigBase58", transfer.signature
    assert_nil transfer.settled_at, "confirmed is not settled — finalized is"
    assert_enqueued_with(job: Solrengine::Sdp::TrackTransferJob, args: [ transfer ])
  end

  def test_finalized_settles_the_row_terminally
    transfer = create_row(status: "confirmed", signature: "5sigBase58")
    stub_get_transfer(status: "finalized", signature: "5sigBase58")

    perform_track(transfer)

    transfer.reload
    assert transfer.finalized?
    assert transfer.terminal?
    assert_not_nil transfer.settled_at
    assert_equal 0, enqueued_jobs.size
  end

  def test_sdp_failure_settles_failed_with_the_sdp_error_captured
    transfer = create_row
    stub_get_transfer(status: "failed", error: "insufficient lamports for rent")

    perform_track(transfer)

    transfer.reload
    assert transfer.failed?
    assert_equal "insufficient lamports for rent", transfer.sdp_error
    assert_not_nil transfer.settled_at
    assert_equal 0, enqueued_jobs.size
  end

  def test_still_processing_within_deadline_reenqueues
    transfer = create_row
    stub_get_transfer(status: "processing")

    perform_track(transfer)

    transfer.reload
    assert transfer.processing?
    assert_enqueued_with(job: Solrengine::Sdp::TrackTransferJob, args: [ transfer ])
  end

  # --- engine-local expired ---------------------------------------------------------

  def test_stuck_processing_past_deadline_expires_terminally
    # No stub on purpose: expiry is decided before any SDP I/O, so any HTTP
    # call here would raise a WebMock NetConnectNotAllowedError.
    transfer = create_row(submitted_at: 16.minutes.ago) # default deadline: 15 minutes

    perform_track(transfer)

    transfer.reload
    assert transfer.expired?
    assert transfer.terminal?
    assert_not_nil transfer.settled_at
    assert_equal 0, enqueued_jobs.size
  end

  def test_processing_past_deadline_expires_even_while_sdp_is_down
    transfer = create_row(submitted_at: 16.minutes.ago)
    stub_request(:get, TRANSFER_URL).to_return(status: 503)

    perform_track(transfer)

    transfer.reload
    assert transfer.expired?, "expiry must not depend on a successful GET — it never fires during an outage otherwise"
    assert_not_nil transfer.settled_at
    assert_not_requested :get, TRANSFER_URL
    assert_equal 0, enqueued_jobs.size
  end

  def test_confirmed_past_deadline_does_not_expire_and_keeps_tracking
    # Row must already be confirmed: the pre-I/O deadline guard expires
    # processing rows before any GET, so a processing fixture would never
    # reach the confirmed-keeps-tracking branch this test pins.
    transfer = create_row(status: "confirmed", signature: "5sig", submitted_at: 16.minutes.ago)
    stub_get_transfer(status: "confirmed", signature: "5sig")

    perform_track(transfer)

    transfer.reload
    assert transfer.confirmed?, "expiring user-facing success would retract money the user saw move"
    assert_enqueued_with(job: Solrengine::Sdp::TrackTransferJob, args: [ transfer ])
  end

  # --- unknown → memo-token reconciliation ---------------------------------------------

  def test_reconcile_adopts_the_sdp_row_found_by_memo_token_on_a_later_page
    transfer = create_row(status: "unknown", sdp_transfer_id: nil, memo_token: "sdp-abc123")
    stub_list_page(
      query: { "wallet" => "wal_src" },
      rows: [ { id: "tr_other", status: "confirmed", memo: "someone else" } ],
      meta: { hasMore: true, page: 1 }
    )
    stub_list_page(
      query: { "wallet" => "wal_src", "page" => "2" },
      rows: [ { id: "tr_42", status: "processing", memo: "rent | sdp-abc123" } ],
      meta: { hasMore: false, page: 2 }
    )

    perform_track(transfer)

    transfer.reload
    assert transfer.processing?, "adopted row continues as a normal tracked transfer"
    assert_equal "tr_42", transfer.sdp_transfer_id
    assert_equal "processing", transfer.sdp_status
    assert_enqueued_with(job: Solrengine::Sdp::TrackTransferJob, args: [ transfer ])
  end

  def test_reconcile_adopting_a_finalized_row_settles_immediately
    transfer = create_row(status: "unknown", sdp_transfer_id: nil, memo_token: "sdp-abc123")
    stub_list_page(
      query: { "wallet" => "wal_src" },
      rows: [ { id: "tr_42", status: "finalized", signature: "5sig", memo: "sdp-abc123" } ],
      meta: { hasMore: false, page: 1 }
    )

    perform_track(transfer)

    transfer.reload
    assert transfer.finalized?
    assert_equal "tr_42", transfer.sdp_transfer_id
    assert_not_nil transfer.settled_at
    assert_equal 0, enqueued_jobs.size
  end

  def test_reconcile_without_match_past_deadline_settles_failed_unsent
    # No stub on purpose: reconcile exhaustion is decided before any SDP I/O,
    # so any HTTP call here would raise a WebMock NetConnectNotAllowedError.
    transfer = create_row(status: "unknown", sdp_transfer_id: nil,
                          memo_token: "sdp-abc123", submitted_at: 16.minutes.ago)

    perform_track(transfer)

    transfer.reload
    assert transfer.failed?
    assert_equal "unsent (reconcile exhausted)", transfer.sdp_error
    assert_not_nil transfer.settled_at
    assert_equal 0, enqueued_jobs.size
  end

  def test_reconcile_without_match_within_deadline_reenqueues_and_stays_unknown
    transfer = create_row(status: "unknown", sdp_transfer_id: nil, memo_token: "sdp-abc123")
    stub_list_page(query: { "wallet" => "wal_src" }, rows: [], meta: { hasMore: false, page: 1 })

    perform_track(transfer)

    transfer.reload
    assert transfer.unknown?
    assert_enqueued_with(job: Solrengine::Sdp::TrackTransferJob, args: [ transfer ])
  end

  def test_unknown_past_deadline_settles_unsent_even_while_sdp_is_down
    transfer = create_row(status: "unknown", sdp_transfer_id: nil,
                          memo_token: "sdp-abc123", submitted_at: 16.minutes.ago)
    stub_request(:get, TRANSFERS_URL).with(query: { "wallet" => "wal_src" }).to_return(status: 503)

    perform_track(transfer)

    transfer.reload
    assert transfer.failed?, "an outage must not keep an unknown row alive past the reconcile deadline"
    assert_equal "unsent (reconcile exhausted)", transfer.sdp_error
    assert_not_nil transfer.settled_at
    assert_equal 0, enqueued_jobs.size
  end

  def test_processing_row_without_sdp_id_reconciles_via_memo_token
    # A SigningPending 202 with no id in its details leaves a processing row
    # with no sdp_transfer_id — get_transfer(nil) would hit a malformed URL,
    # so the job must reconcile by memo token instead.
    transfer = create_row(sdp_transfer_id: nil, memo_token: "sdp-abc123")
    stub_list_page(
      query: { "wallet" => "wal_src" },
      rows: [ { id: "tr_42", status: "processing", memo: "rent | sdp-abc123" } ],
      meta: { hasMore: false, page: 1 }
    )

    perform_track(transfer)

    transfer.reload
    assert transfer.processing?
    assert_equal "tr_42", transfer.sdp_transfer_id, "adopted the SDP row found by memo token"
    assert_enqueued_with(job: Solrengine::Sdp::TrackTransferJob, args: [ transfer ])
  end

  # --- API errors never strand a row -------------------------------------------------

  def test_404_on_get_transfer_flips_to_unknown_for_memo_reconciliation
    transfer = create_row
    stub_request(:get, TRANSFER_URL).to_return(status: 404)

    perform_track(transfer)

    transfer.reload
    assert transfer.unknown?, "a 404 means the id provably doesn't exist — the memo token decides, not a 404 poll loop"
    assert_enqueued_with(job: Solrengine::Sdp::TrackTransferJob, args: [ transfer ])
  end

  def test_non_transport_error_past_deadline_settles_failed_with_the_reason
    # A confirmed row is the one state that still polls past the deadline
    # (processing expires and unknown settles unsent before any I/O), so it
    # is where a persistent API error must finally land a verdict.
    transfer = create_row(status: "confirmed", signature: "5sig", submitted_at: 16.minutes.ago)
    stub_request(:get, TRANSFER_URL).to_return(status: 401)

    perform_track(transfer)

    transfer.reload
    assert transfer.failed?
    assert_match(/HTTP 401/, transfer.sdp_error)
    assert_not_nil transfer.settled_at
    assert_equal 0, enqueued_jobs.size
  end

  def test_rate_limited_within_deadline_reenqueues_without_touching_the_row
    transfer = create_row
    stub_request(:get, TRANSFER_URL).to_return(status: 429)

    perform_track(transfer)

    transfer.reload
    assert transfer.processing?, "no verdict invented from a rate limit"
    assert_enqueued_with(job: Solrengine::Sdp::TrackTransferJob, args: [ transfer ])
  end

  # --- transport retries (GETs are safe) -------------------------------------------------

  def test_transient_get_failure_retries_via_active_job
    transfer = create_row
    stub_request(:get, TRANSFER_URL).to_return(status: 503)

    perform_track(transfer) # retry_on swallows + re-enqueues

    transfer.reload
    assert transfer.processing?, "row untouched until a poll succeeds"
    assert_enqueued_with(job: Solrengine::Sdp::TrackTransferJob, args: [ transfer ])
  end

  def test_retry_exhaustion_hands_off_to_a_fresh_poll_instead_of_orphaning_the_row
    transfer = create_row
    stub_request(:get, TRANSFER_URL).to_return(status: 503)

    job = Solrengine::Sdp::TrackTransferJob.new(transfer)
    job.executions = 4
    job.exception_executions = { [ ::Sdp::Unavailable, ::Sdp::Timeout ].to_s => 4 }
    job.perform_now # final attempt fails → exhaustion block re-enqueues fresh

    transfer.reload
    assert transfer.processing?, "no verdict invented from a transport failure"
    assert_enqueued_with(job: Solrengine::Sdp::TrackTransferJob, args: [ transfer ])
  end

  # --- end-to-end happy path (the plan's Happy scenario) ----------------------------------

  def test_execute_then_track_through_confirmed_to_finalized
    stub_request(:get, BALANCES_URL).to_return(
      status: 200, headers: JSON_HEADERS,
      body: { data: { walletBalances: { balances: [ { token: "SOL", uiAmount: "10" } ] } },
              meta: {} }.to_json
    )
    stub_request(:post, TRANSFERS_URL).to_return(
      status: 201, headers: JSON_HEADERS,
      body: { data: { transfer: { id: "tr_1", status: "pending" } }, meta: {} }.to_json
    )

    transfer = Solrengine::Sdp::Transfer.execute!(
      source: "wal_src", destination: "Dest58Base", amount: "1.5"
    )
    assert transfer.processing?
    assert_equal "tr_1", transfer.sdp_transfer_id

    stub_get_transfer(status: "confirmed", signature: "5sigBase58")
    perform_track(transfer)
    transfer.reload
    assert transfer.confirmed?
    assert_nil transfer.settled_at

    stub_get_transfer(status: "finalized", signature: "5sigBase58")
    perform_track(transfer)
    transfer.reload
    assert transfer.finalized?
    assert_equal "5sigBase58", transfer.signature
    assert_not_nil transfer.settled_at
  end

  private

  def create_row(attrs = {})
    Solrengine::Sdp::Transfer.create!({
      source_wallet_id: "wal_src",
      destination: "Dest58Base",
      token: "SOL",
      amount: "1.0",
      memo_token: "sdp-#{SecureRandom.hex(8)}",
      status: "processing",
      sdp_transfer_id: "tr_1",
      submitted_at: Time.current
    }.merge(attrs))
  end

  def perform_track(transfer)
    Solrengine::Sdp::TrackTransferJob.perform_now(transfer)
  end

  def stub_get_transfer(status:, signature: nil, error: nil)
    body = { id: "tr_1", status: status }
    body[:signature] = signature if signature
    body[:error] = error if error
    stub_request(:get, TRANSFER_URL).to_return(
      status: 200, headers: JSON_HEADERS,
      body: { data: { transfer: body }, meta: {} }.to_json
    )
  end

  def stub_list_page(query:, rows:, meta:)
    stub_request(:get, TRANSFERS_URL).with(query: query).to_return(
      status: 200, headers: JSON_HEADERS,
      body: { data: rows, meta: meta }.to_json
    )
  end
end
