# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

# Broadcaster — the doorbell invariants as engine code. Render lambdas are
# plain recording procs: Turbo stays out of the engine core, so the four
# doorbell rules are testable without a turbo-rails dependency.
class BroadcasterTest < ActiveSupport::TestCase
  ADDRESS = "7gWatchedWalletBase58xyz11111111111111111"
  SOL_MINT = "So11111111111111111111111111111111111111112"
  JUPITER_URL = %r{https://api\.jup\.ag/price/v3}

  setup do
    Solrengine::Sdp.reset_configuration!
    @log = StringIO.new
    Solrengine::Sdp.configure do |config|
      config.api_key = "test-key"
      config.broadcast_retry_delay = 0 # never sleep in tests
      config.logger = ActiveSupport::Logger.new(@log)
    end
    User.delete_all
    @user = User.create!(
      email: "owner@example.com", sdp_provisioning_state: "ready",
      sdp_wallet_id: "wal_1", wallet_address: ADDRESS
    )
    @events = []
  end

  teardown do
    Solrengine::Sdp.stop_realtime!
    Solrengine::Sdp.reset_configuration!
  end

  # --- doorbell rule 1: broadcast only on success (F2 happy path) -------------

  def test_happy_path_renders_every_target_in_priority_order_after_all_fetches
    configure_targets(recording_target(:activity), recording_target(:balance))

    assert Solrengine::Sdp::Broadcaster.call(ADDRESS)

    assert_equal(
      [
        [ :fetch, :activity ], [ :fetch, :balance ],            # ALL fetches first…
        [ :render, :activity, "activity-data" ],                # …then renders, in
        [ :render, :balance, "balance-data" ]                   # configured order
      ],
      @events
    )
  end

  def test_render_receives_the_user_and_its_own_targets_data
    seen = nil
    configure_targets(
      { name: :balance,
        fetch: ->(_user) { { sol: "1.5" } },
        render: ->(user, data) { seen = [ user, data ] } }
    )

    Solrengine::Sdp::Broadcaster.call(ADDRESS)

    assert_equal [ @user, { sol: "1.5" } ], seen
  end

  # --- all-or-nothing ----------------------------------------------------------

  def test_a_raising_fetch_means_zero_renders_after_retries_exhausted
    configure_targets(
      recording_target(:balance),
      recording_target(:activity, fetch: ->(_user) { raise Sdp::Error, "boom" })
    )

    refute Solrengine::Sdp::Broadcaster.call(ADDRESS)

    renders = @events.select { |event| event.first == :render }
    assert_empty renders
    # The whole cycle retried broadcast_retries times (default 3 attempts).
    assert_equal 3, @events.count { |event| event == [ :fetch, :balance ] }
    assert_match(/Giving up on #{ADDRESS}/, @log.string)
  end

  def test_a_fetch_returning_unavailable_means_zero_renders
    configure_targets(
      recording_target(:balance, fetch: ->(_user) { :unavailable }),
      recording_target(:activity)
    )

    refute Solrengine::Sdp::Broadcaster.call(ADDRESS)

    assert_empty @events.select { |event| event.first == :render }
  end

  # --- doorbell rule 2: consumed doorbells retry --------------------------------

  def test_transient_fetch_failure_retries_the_whole_cycle_then_renders
    attempts = 0
    configure_targets(
      recording_target(:balance, fetch: ->(_user) {
        attempts += 1
        raise Sdp::Error, "hiccup" if attempts == 1

        "balance-data"
      }),
      recording_target(:activity)
    )

    assert Solrengine::Sdp::Broadcaster.call(ADDRESS)

    assert_equal 2, attempts # failed once, succeeded on the retry
    assert_equal(
      [ [ :render, :balance, "balance-data" ], [ :render, :activity, "activity-data" ] ],
      @events.select { |event| event.first == :render }
    )
  end

  def test_a_raising_render_also_retries_the_whole_cycle
    render_attempts = 0
    configure_targets(
      { name: :balance,
        fetch: ->(_user) { @events << [ :fetch, :balance ]; "data" },
        render: ->(_user, _data) {
          render_attempts += 1
          raise "cable hiccup" if render_attempts == 1
        } }
    )

    assert Solrengine::Sdp::Broadcaster.call(ADDRESS)

    assert_equal 2, render_attempts
    assert_equal 2, @events.count { |event| event == [ :fetch, :balance ] } # re-fetched, not replayed
  end

  def test_retry_count_honors_configured_broadcast_retries
    Solrengine::Sdp.configure { |config| config.broadcast_retries = 2 }
    configure_targets(recording_target(:balance, fetch: ->(_user) { :unavailable }))

    refute Solrengine::Sdp::Broadcaster.call(ADDRESS)

    assert_equal 2, @events.count { |event| event == [ :fetch, :balance ] }
  end

  # --- AE3: USD enrichment ------------------------------------------------------

  def test_usd_value_for_prefers_sdp_provided_usd_value_and_never_calls_jupiter
    jupiter = stub_request(:get, JUPITER_URL)
    balance = Sdp::Balance.new(token: "SOL", mint: SOL_MINT, ui_amount: "2.0", usd_value: "301.50")

    assert_equal "301.50", Solrengine::Sdp.usd_value_for(balance)
    assert_not_requested(jupiter)
  end

  def test_usd_value_for_derives_from_jupiter_when_sdp_omits_usd_value
    stub_request(:get, JUPITER_URL).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { SOL_MINT => { "usdPrice" => 150.0 } }.to_json
    )
    balance = Sdp::Balance.new(token: "SOL", mint: SOL_MINT, ui_amount: "2.0", usd_value: nil)

    assert_equal BigDecimal("300.0"), Solrengine::Sdp.usd_value_for(balance)
  end

  def test_jupiter_failure_yields_nil_usd_and_never_fails_the_fetch
    stub_request(:get, JUPITER_URL).to_return(status: 500)
    balance = Sdp::Balance.new(token: "SOL", mint: SOL_MINT, ui_amount: "2.0", usd_value: nil)

    configure_targets(
      { name: :balance,
        fetch: ->(_user) { { sol: balance.ui_amount, usd: Solrengine::Sdp.usd_value_for(balance) } },
        render: ->(_user, data) { @events << [ :render, :balance, data ] } }
    )

    assert Solrengine::Sdp::Broadcaster.call(ADDRESS)

    # Price is decorative: the broadcast still happened, with usd: nil.
    assert_equal [ [ :render, :balance, { sol: "2.0", usd: nil } ] ], @events
  end

  # --- no-ops ---------------------------------------------------------------------

  def test_unknown_wallet_is_a_noop_with_zero_fetch_calls
    configure_targets(recording_target(:balance))

    assert_nil Solrengine::Sdp::Broadcaster.call("ExternalCounterpartyWallet1111111111111")

    assert_empty @events
  end

  def test_non_ready_owner_is_a_noop
    @user.update!(sdp_provisioning_state: "provisioning")
    configure_targets(recording_target(:balance))

    assert_nil Solrengine::Sdp::Broadcaster.call(ADDRESS)

    assert_empty @events
  end

  def test_unconfigured_targets_do_not_crash_and_log_a_hint
    assert_nil Solrengine::Sdp::Broadcaster.call(ADDRESS) # default: no targets

    assert_match(/No broadcast_targets configured/, @log.string)
  end

  def test_malformed_target_raises_configuration_error_outside_the_retry_loop
    configure_targets({ name: :broken, fetch: "not callable", render: nil })

    assert_raises(Solrengine::Sdp::ConfigurationError) do
      Solrengine::Sdp::Broadcaster.call(ADDRESS)
    end
  end

  # --- connection pool hygiene (P2 fix) -----------------------------------------
  #
  # Broadcaster.call is invoked on a long-lived per-wallet broadcast thread by
  # solrengine-realtime. Rails only auto-releases AR connections at request
  # boundaries; without with_connection the user lookup permanently holds one per
  # thread and the pool (default 5) exhausts on the sixth wallet. In-memory SQLite
  # is per-connection, so a spawned thread's fresh connection would see an empty
  # database — the lease semantics are asserted on the main thread instead:
  # release_connection returns this thread's lease, and with_connection inside
  # call must check out and return rather than leave a connection claimed.
  def test_broadcaster_call_releases_ar_connection_after_user_lookup
    configure_targets(recording_target(:balance))
    ActiveRecord::Base.connection_pool.release_connection

    Solrengine::Sdp::Broadcaster.call(ADDRESS)

    refute ActiveRecord::Base.connection_pool.active_connection?,
      "Broadcaster left an AR connection checked out — the long-lived " \
      "broadcast thread would exhaust the pool at pool-size wallets " \
      "without with_connection"
  end

  def test_per_call_targets_override_the_configured_ones
    configure_targets(recording_target(:configured))

    Solrengine::Sdp::Broadcaster.call(ADDRESS, targets: [ recording_target(:override) ])

    assert_equal [ [ :fetch, :override ], [ :render, :override, "override-data" ] ], @events
  end

  # --- realtime registry integration (through the real solrengine-realtime) ------

  def test_start_realtime_registers_the_broadcaster_and_dispatch_invokes_it
    Solrengine::Realtime.on_account_change = nil # silence the gem's default puts subscriber
    configure_targets(recording_target(:balance))

    Solrengine::Sdp.start_realtime!
    Solrengine::Realtime.dispatch(ADDRESS)

    assert_equal [ [ :fetch, :balance ], [ :render, :balance, "balance-data" ] ], @events
  end

  def test_stop_realtime_unsubscribes
    Solrengine::Realtime.on_account_change = nil
    configure_targets(recording_target(:balance))

    Solrengine::Sdp.start_realtime!
    Solrengine::Sdp.stop_realtime!
    Solrengine::Realtime.dispatch(ADDRESS)

    assert_empty @events
  end

  def test_engine_and_a_second_dummy_subscriber_both_fire_on_one_dispatch
    Solrengine::Realtime.on_account_change = nil
    configure_targets(recording_target(:balance))
    dummy_seen = nil
    Solrengine::Realtime.subscribe(:dummy_app_subscriber) { |address| dummy_seen = address }

    Solrengine::Sdp.start_realtime!
    Solrengine::Realtime.dispatch(ADDRESS)

    assert_equal ADDRESS, dummy_seen
    assert_includes @events, [ :render, :balance, "balance-data" ]
  ensure
    Solrengine::Realtime.unsubscribe(:dummy_app_subscriber)
  end

  private

  def configure_targets(*targets)
    Solrengine::Sdp.configure { |config| config.broadcast_targets = targets }
  end

  # A target whose fetch and render record their invocation (and order) into
  # @events. Default fetch returns "#{name}-data".
  def recording_target(name, fetch: ->(_user) { "#{name}-data" })
    events = @events
    {
      name: name,
      fetch: ->(user) {
        events << [ :fetch, name ]
        fetch.call(user)
      },
      render: ->(_user, data) { events << [ :render, name, data ] }
    }
  end
end
