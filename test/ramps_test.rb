# frozen_string_literal: true

require_relative "test_helper"

# Engine-level ramps helper. Its whole job is to default `provider:` from
# config.ramp_provider, so these drive the real solana-sdp client through
# WebMock to prove the default actually lands on the wire (and that an explicit
# provider overrides it). Everything else is plain passthrough.
class RampsTest < Minitest::Test
  include EnvHelper

  BASE_URL = "http://sdp.test:8787"
  RAMPS = "#{BASE_URL}/v1/payments/ramps".freeze
  JSON_HEADERS = { "Content-Type" => "application/json" }.freeze

  def setup
    Solrengine::Sdp.reset_configuration!
    Solrengine::Sdp.configure do |config|
      config.api_key = "test-key"
      config.base_url = BASE_URL
      config.ramp_provider = "bvnk"
    end
  end

  def teardown
    Solrengine::Sdp.reset_configuration!
    super # webmock/minitest resets stubs + history here
  end

  def test_onramp_quote_injects_the_configured_provider
    stub = stub_request(:post, "#{RAMPS}/onramp/quote")
      .with(body: hash_including("provider" => "bvnk"))
      .to_return(status: 200, headers: JSON_HEADERS,
                 body: { data: { quote: { id: "q_1" } }, meta: {} }.to_json)

    quote = Solrengine::Sdp.ramps.onramp_quote(
      counterparty_id: "cp_1", destination_wallet: "wal_a",
      crypto_token: "SOL", fiat_currency: "USD", fiat_amount: "100"
    )

    assert_requested stub
    assert_equal "q_1", quote.id
  end

  def test_an_explicit_provider_overrides_the_configured_default
    stub = stub_request(:post, "#{RAMPS}/onramp/execute")
      .with(body: hash_including("provider" => "other"))
      .to_return(status: 200, headers: JSON_HEADERS,
                 body: { data: { ramp: { id: "rmp_1" } }, meta: {} }.to_json)

    Solrengine::Sdp.ramps.onramp_execute(
      provider: "other", counterparty_id: "cp_1", destination_wallet: "wal_a",
      crypto_token: "SOL", fiat_currency: "USD", fiat_amount: "1"
    )

    assert_requested stub
  end

  def test_currencies_inject_the_provider_as_a_query_filter
    stub = stub_request(:get, "#{RAMPS}/onramp/currency")
      .with(query: hash_including("provider" => "bvnk"))
      .to_return(status: 200, headers: JSON_HEADERS,
                 body: { data: { currencies: { sources: [], destinations: [] }, pairs: [] }, meta: {} }.to_json)

    Solrengine::Sdp.ramps.onramp_currencies(source: "USD", dest: "SOL")

    assert_requested stub
  end

  def test_simulate_ramp_passes_through_with_no_provider
    stub = stub_request(:post, "#{RAMPS}/sandbox/simulate")
      .with(body: { rampId: "rmp_1", event: "PAYMENT_RECEIVED" })
      .to_return(status: 200, headers: JSON_HEADERS,
                 body: { data: { transaction: { id: "tx_1" } }, meta: {} }.to_json)

    Solrengine::Sdp.ramps.simulate_ramp(rampId: "rmp_1", event: "PAYMENT_RECEIVED")

    assert_requested stub
  end

  # With no configured default, the helper injects nothing and the caller's
  # per-call provider flows straight through (the client requires `provider:`).
  def test_with_no_configured_default_the_callers_provider_flows_through
    with_env("SDP_RAMP_PROVIDER" => nil) do
      Solrengine::Sdp.configure do |config|
        config.api_key = "test-key"
        config.base_url = BASE_URL
        config.ramp_provider = nil
      end

      stub = stub_request(:post, "#{RAMPS}/onramp/quote")
        .with(body: hash_including("provider" => "caller-supplied"))
        .to_return(status: 200, headers: JSON_HEADERS,
                   body: { data: { quote: { id: "q_2" } }, meta: {} }.to_json)

      Solrengine::Sdp.ramps.onramp_quote(
        provider: "caller-supplied", counterparty_id: "cp_1", destination_wallet: "wal_a",
        crypto_token: "SOL", fiat_currency: "USD", fiat_amount: "1"
      )

      assert_requested stub
    end
  end
end
