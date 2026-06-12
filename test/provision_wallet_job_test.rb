# frozen_string_literal: true

require_relative "test_helper"

# ActiveSupport::TestCase (not bare Minitest::Test): ActiveJob::TestHelper's
# assertions lean on its tagged-logging plumbing.
class ProvisionWalletJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  BASE_URL = "http://sdp.test:8787"
  WALLETS_URL = "#{BASE_URL}/v1/wallets"
  JSON_HEADERS = { "Content-Type" => "application/json" }.freeze

  setup do
    Solrengine::Sdp.reset_configuration!
    Solrengine::Sdp.configure do |config|
      config.api_key = "test-key"
      config.base_url = BASE_URL
      config.label_namespace = "testns"
      config.custody_provider = "privy"
    end
    User.delete_all
  end

  teardown do
    Solrengine::Sdp.reset_configuration!
  end

  # --- F1 happy path -----------------------------------------------------------

  def test_fresh_user_gets_a_wallet_and_lands_ready
    user = User.create!(email: "a@example.com")
    stub_empty_wallet_list
    create_stub = stub_wallet_create(label: user.sdp_wallet_label)

    Solrengine::Sdp::ProvisionWalletJob.perform_now(user)

    assert_requested create_stub, times: 1
    user.reload
    assert user.wallet_ready?
    assert_equal "wal_1", user.sdp_wallet_id
    assert_equal "PubKey1Base58", user.wallet_address
    assert_nil user.sdp_provisioning_error
  end

  # --- AE1: FL-10 capability gate ----------------------------------------------

  def test_capability_gate_lands_failed_with_renderable_reason_and_no_retry
    user = User.create!(email: "a@example.com")
    stub_empty_wallet_list
    create_stub = stub_request(:post, WALLETS_URL).to_return(
      status: 400,
      headers: JSON_HEADERS,
      body: {
        error: { code: "BAD_REQUEST", message: "Wallet provisioning not supported for provider: local" },
        meta: {}
      }.to_json
    )

    assert_no_enqueued_jobs do
      Solrengine::Sdp::ProvisionWalletJob.perform_now(user)
    end

    assert_requested create_stub, times: 1 # terminal: no retry burned
    user.reload
    assert user.wallet_failed?
    assert_includes user.sdp_provisioning_error, "managed provider"
  end

  # --- adoption ------------------------------------------------------------------

  def test_adopts_existing_wallet_by_label_without_creating
    user = User.create!(email: "a@example.com")
    stub_request(:get, WALLETS_URL).to_return(
      status: 200,
      headers: JSON_HEADERS,
      body: {
        data: { wallets: [
          { walletId: "wal_other", publicKey: "PubKeyOther", label: "testns-user-0", status: "active" },
          { walletId: "wal_adopted", publicKey: "PubKeyAdopted", label: user.sdp_wallet_label, status: "active" }
        ] },
        meta: {}
      }.to_json
    )

    Solrengine::Sdp::ProvisionWalletJob.perform_now(user)

    assert_not_requested :post, WALLETS_URL
    user.reload
    assert user.wallet_ready?
    assert_equal "wal_adopted", user.sdp_wallet_id
    assert_equal "PubKeyAdopted", user.wallet_address
  end

  # --- idempotency / race guard ----------------------------------------------------

  def test_ready_user_returns_immediately_without_http
    user = User.create!(
      email: "a@example.com",
      sdp_provisioning_state: "ready", sdp_wallet_id: "wal_1", wallet_address: "PubKey1"
    )

    Solrengine::Sdp::ProvisionWalletJob.perform_now(user) # any HTTP call would raise (nothing stubbed)

    assert_equal 0, WebMock::RequestRegistry.instance.requested_signatures.hash.size
    assert user.reload.wallet_ready?
  end

  def test_duplicate_job_cannot_steal_a_held_claim
    # updated_at is "now" (just created): the lease is live, so a fresh job
    # must leave the row to the worker that owns it.
    user = User.create!(email: "a@example.com", sdp_provisioning_state: "provisioning")

    Solrengine::Sdp::ProvisionWalletJob.perform_now(user) # claim fails → no HTTP (nothing stubbed)

    assert_equal 0, WebMock::RequestRegistry.instance.requested_signatures.hash.size
    user.reload
    assert user.wallet_provisioning? # untouched: the owning job will settle it
    assert_nil user.sdp_wallet_id
  end

  # --- stale-claim lease takeover -----------------------------------------------

  def test_fresh_job_takes_over_a_stale_provisioning_claim_and_adopts_by_label
    # A worker died between claim and settle: the row is stuck in
    # provisioning with an updated_at past the lease (default 600s).
    user = User.create!(email: "a@example.com", sdp_provisioning_state: "provisioning")
    user.update_column(:updated_at, 11.minutes.ago) # update_column: must NOT renew the lease

    # The dead worker's create may have SUCCEEDED before it died — the list
    # returns the wallet by label, and adoption (not a second create) proves
    # takeover can never double-provision.
    stub_request(:get, WALLETS_URL).to_return(
      status: 200, headers: JSON_HEADERS,
      body: {
        data: { wallets: [
          { walletId: "wal_adopted", publicKey: "PubKeyAdopted", label: user.sdp_wallet_label, status: "active" }
        ] },
        meta: {}
      }.to_json
    )

    Solrengine::Sdp::ProvisionWalletJob.perform_now(user) # fresh job (executions 1), not a retry

    assert_not_requested :post, WALLETS_URL
    user.reload
    assert user.wallet_ready?
    assert_equal "wal_adopted", user.sdp_wallet_id
    assert_equal "PubKeyAdopted", user.wallet_address
  end

  # --- transport retries -------------------------------------------------------------

  def test_transient_error_keeps_the_claim_and_enqueues_a_retry
    user = User.create!(email: "a@example.com")
    stub_request(:get, WALLETS_URL).to_return(status: 503)

    Solrengine::Sdp::ProvisionWalletJob.perform_now(user) # retry_on swallows + re-enqueues

    assert_enqueued_with(job: Solrengine::Sdp::ProvisionWalletJob, args: [ user ])
    assert user.reload.wallet_provisioning?, "claim must stay held across retries"
  end

  def test_retry_execution_resumes_the_held_claim_and_succeeds
    user = User.create!(email: "a@example.com", sdp_provisioning_state: "provisioning")
    stub_empty_wallet_list
    stub_wallet_create(label: user.sdp_wallet_label)

    job = Solrengine::Sdp::ProvisionWalletJob.new(user)
    job.executions = 1 # perform_now increments → executions 2 = a retry run
    job.perform_now

    user.reload
    assert user.wallet_ready?
    assert_equal "wal_1", user.sdp_wallet_id
  end

  # Exhaustion approach: rather than chasing 5 scheduled retries through the
  # test adapter, prime the job's retry counters to attempts - 1 and run once —
  # the final attempt fails, so retry_on's exhaustion block (the real
  # production path) fires end-to-end. retry_on counts per exception group via
  # exception_executions (Rails 6+); executions feeds the claim's resume logic.
  def test_retry_exhaustion_lands_failed_with_the_transport_reason
    user = User.create!(email: "a@example.com")
    stub_request(:get, WALLETS_URL).to_return(status: 503)

    job = Solrengine::Sdp::ProvisionWalletJob.new(user)
    job.executions = 4
    job.exception_executions = { [ ::Sdp::Unavailable, ::Sdp::Timeout ].to_s => 4 }

    assert_no_enqueued_jobs do
      job.perform_now
    end

    user.reload
    assert user.wallet_failed?
    assert_includes user.sdp_provisioning_error, "Retries exhausted"
  end

  # --- other terminal SDP errors --------------------------------------------------

  def test_non_transport_sdp_errors_are_terminal_failed
    user = User.create!(email: "a@example.com")
    stub_request(:get, WALLETS_URL).to_return(
      status: 401,
      headers: JSON_HEADERS,
      body: { error: { code: "UNAUTHORIZED", message: "Invalid API key" }, meta: {} }.to_json
    )

    assert_no_enqueued_jobs do
      Solrengine::Sdp::ProvisionWalletJob.perform_now(user)
    end

    user.reload
    assert user.wallet_failed?
    assert_includes user.sdp_provisioning_error, "Invalid API key"
  end

  # --- deleted user mid-flight ------------------------------------------------------

  def test_user_deleted_before_perform_is_discarded_silently
    user = User.create!(email: "a@example.com")
    Solrengine::Sdp::ProvisionWalletJob.perform_later(user)
    user.destroy!

    perform_enqueued_jobs # DeserializationError → discard_on → no raise, no HTTP

    assert_equal 0, WebMock::RequestRegistry.instance.requested_signatures.hash.size
    assert_equal 0, enqueued_jobs.size
  end

  private

  def stub_empty_wallet_list
    stub_request(:get, WALLETS_URL).to_return(
      status: 200, headers: JSON_HEADERS,
      body: { data: { wallets: [] }, meta: {} }.to_json
    )
  end

  def stub_wallet_create(label:)
    stub_request(:post, WALLETS_URL)
      .with(body: { label: label, provider: "privy" })
      .to_return(
        status: 201, headers: JSON_HEADERS,
        body: {
          data: { wallet: { walletId: "wal_1", publicKey: "PubKey1Base58", label: label, status: "active" } },
          meta: {}
        }.to_json
      )
  end
end
