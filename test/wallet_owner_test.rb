# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

# ActiveSupport::TestCase (not bare Minitest::Test): ActiveJob::TestHelper's
# assertions lean on its tagged-logging plumbing.
class WalletOwnerTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    Solrengine::Sdp.reset_configuration!
    Solrengine::Sdp.configure do |config|
      config.api_key = "test-key"
      config.label_namespace = "testns"
    end
    User.delete_all
  end

  teardown do
    Solrengine::Sdp.reset_configuration!
  end

  # --- states ----------------------------------------------------------------

  def test_provisioning_states_constant
    assert_equal %w[pending provisioning ready failed], Solrengine::Sdp::WalletOwner::PROVISIONING_STATES
  end

  def test_state_predicates_track_the_column
    user = User.create!(email: "a@example.com")

    assert user.wallet_pending?
    refute user.wallet_provisioning? || user.wallet_ready? || user.wallet_failed?

    user.update!(sdp_provisioning_state: "provisioning")
    assert user.wallet_provisioning?

    user.update!(sdp_provisioning_state: "ready")
    assert user.wallet_ready?

    user.update!(sdp_provisioning_state: "failed")
    assert user.wallet_failed?
  end

  # The reference schema is NOT NULL, but hosts whose migration predates the
  # default (or skipped the backfill) must still read as pending.
  def test_null_state_reads_as_pending
    user = User.new(email: "a@example.com")
    user[:sdp_provisioning_state] = nil

    assert_equal "pending", user.wallet_provisioning_state
    assert user.wallet_pending?
  end

  def test_wallet_ready_scope_returns_only_ready_users
    ready = User.create!(email: "ready@example.com", sdp_provisioning_state: "ready")
    User.create!(email: "pending@example.com")
    User.create!(email: "failed@example.com", sdp_provisioning_state: "failed")

    assert_equal [ ready.id ], User.wallet_ready.pluck(:id)
  end

  # --- label -------------------------------------------------------------------

  def test_sdp_wallet_label_composes_namespace_and_id
    user = User.create!(email: "a@example.com")

    assert_equal "testns-user-#{user.id}", user.sdp_wallet_label
  end

  def test_two_namespaces_produce_non_colliding_labels_for_the_same_id
    user = User.create!(email: "a@example.com")

    Solrengine::Sdp.configure { |config| config.label_namespace = "alpha" }
    alpha_label = user.sdp_wallet_label

    Solrengine::Sdp.configure { |config| config.label_namespace = "beta" }
    beta_label = user.sdp_wallet_label

    refute_equal alpha_label, beta_label
    assert_equal "alpha-user-#{user.id}", alpha_label
    assert_equal "beta-user-#{user.id}", beta_label
  end

  # --- provision_wallet! -------------------------------------------------------

  def test_provision_wallet_enqueues_the_job_when_pending
    user = User.create!(email: "a@example.com")

    assert_enqueued_with(job: Solrengine::Sdp::ProvisionWalletJob, args: [ user ]) do
      user.provision_wallet!
    end
  end

  def test_provision_wallet_is_a_noop_when_already_ready
    user = User.create!(email: "a@example.com", sdp_provisioning_state: "ready")

    assert_no_enqueued_jobs do
      refute user.provision_wallet!
    end
  end

  def test_provision_wallet_is_a_noop_while_provisioning
    user = User.create!(email: "a@example.com", sdp_provisioning_state: "provisioning")

    assert_no_enqueued_jobs do
      refute user.provision_wallet!
    end
  end

  def test_provision_wallet_noop_logs_to_configured_logger_when_ready
    log = StringIO.new
    Solrengine::Sdp.configure { |config| config.logger = ActiveSupport::Logger.new(log) }
    user = User.create!(email: "a@example.com", sdp_provisioning_state: "ready")

    refute user.provision_wallet!

    assert_match(/\[Solrengine::Sdp\] provision_wallet! no-op for User##{user.id}/, log.string)
    assert_match(/state is ready/, log.string)
  end

  def test_provision_wallet_noop_logs_to_configured_logger_when_provisioning
    log = StringIO.new
    Solrengine::Sdp.configure { |config| config.logger = ActiveSupport::Logger.new(log) }
    user = User.create!(email: "a@example.com", sdp_provisioning_state: "provisioning")

    refute user.provision_wallet!

    assert_match(/state is provisioning/, log.string)
  end

  def test_provision_wallet_noop_logs_to_default_stdout_logger_when_unconfigured
    # Configuration#logger lazily builds a $stdout default, so the logger is
    # never nil — the no-op message lands on stdout out of the box.
    user = User.create!(email: "a@example.com", sdp_provisioning_state: "ready")

    assert_output(/state is ready/) { refute user.provision_wallet! }
  end

  def test_provision_wallet_re_enqueues_from_failed
    user = User.create!(email: "a@example.com", sdp_provisioning_state: "failed")

    assert_enqueued_with(job: Solrengine::Sdp::ProvisionWalletJob, args: [ user ]) do
      user.provision_wallet!
    end
  end

  def test_provision_wallet_re_enqueues_from_stale_provisioning
    # The claiming worker died: updated_at is past the lease (default 600s),
    # so the row is abandoned, not owned — re-enqueue instead of no-op.
    user = User.create!(email: "a@example.com", sdp_provisioning_state: "provisioning")
    user.update_column(:updated_at, 11.minutes.ago) # update_column: must NOT renew the lease

    assert_enqueued_with(job: Solrengine::Sdp::ProvisionWalletJob, args: [ user ]) do
      user.provision_wallet!
    end
  end

  # --- retry_provisioning! -----------------------------------------------------

  def test_retry_provisioning_resets_failed_and_enqueues
    user = User.create!(
      email: "a@example.com",
      sdp_provisioning_state: "failed",
      sdp_provisioning_error: "Wallet provisioning not supported for provider: local"
    )

    assert_enqueued_with(job: Solrengine::Sdp::ProvisionWalletJob, args: [ user ]) do
      user.retry_provisioning!
    end

    user.reload
    assert user.wallet_pending?
    assert_nil user.sdp_provisioning_error
  end

  def test_retry_provisioning_is_a_noop_unless_failed
    user = User.create!(email: "a@example.com", sdp_provisioning_state: "ready")

    assert_no_enqueued_jobs do
      refute user.retry_provisioning!
    end

    assert user.reload.wallet_ready?
  end

  def test_retry_provisioning_resets_stale_provisioning_and_enqueues
    # Abandoned claim (worker died before settling): retry_provisioning!
    # re-arms it exactly like a failed row.
    user = User.create!(
      email: "a@example.com",
      sdp_provisioning_state: "provisioning",
      sdp_provisioning_error: "leftover reason from an earlier failed run"
    )
    user.update_column(:updated_at, 11.minutes.ago) # update_column: must NOT renew the lease

    assert_enqueued_with(job: Solrengine::Sdp::ProvisionWalletJob, args: [ user ]) do
      user.retry_provisioning!
    end

    user.reload
    assert user.wallet_pending?
    assert_nil user.sdp_provisioning_error
  end

  def test_retry_provisioning_is_a_noop_on_fresh_provisioning
    # updated_at is "now": a live job owns the row — leave it alone.
    user = User.create!(email: "a@example.com", sdp_provisioning_state: "provisioning")

    assert_no_enqueued_jobs do
      refute user.retry_provisioning!
    end

    assert user.reload.wallet_provisioning?
  end
end
