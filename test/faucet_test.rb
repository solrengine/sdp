# frozen_string_literal: true

require_relative "test_helper"

# Devnet faucet — one attempt, never retried, every outcome mapped to a typed
# error so callers can distinguish "definitely didn't happen" (Unavailable)
# from "may still land" (TimedOut).
class FaucetTest < ActiveSupport::TestCase
  include EnvHelper

  RPC_URL = "https://rpc.devnet.test"
  ADDRESS = "7g4PublicKeyBase58xyz"
  LAMPORTS = 1_000_000_000

  def test_success_returns_the_airdrop_signature_and_sends_a_proper_json_rpc_request
    stub_rpc.to_return(rpc_result("5sigAirdrop111"))

    signature = faucet.request_airdrop(ADDRESS, LAMPORTS)

    assert_equal "5sigAirdrop111", signature
    assert_requested(:post, RPC_URL) do |req|
      body = JSON.parse(req.body)
      body["jsonrpc"] == "2.0" &&
        body["method"] == "requestAirdrop" &&
        body["params"] == [ ADDRESS, LAMPORTS ] &&
        req.headers["Content-Type"] == "application/json"
    end
  end

  def test_http_429_raises_rate_limited
    stub_rpc.to_return(status: 429, body: "Too Many Requests")

    assert_raises(Solrengine::Sdp::Faucet::RateLimited) { faucet.request_airdrop(ADDRESS, LAMPORTS) }
  end

  def test_json_rpc_error_with_rate_limit_text_raises_rate_limited
    stub_rpc.to_return(rpc_error("airdrop request rate limit reached for the day"))

    error = assert_raises(Solrengine::Sdp::Faucet::RateLimited) { faucet.request_airdrop(ADDRESS, LAMPORTS) }
    assert_match(/rate limit/i, error.message)
  end

  def test_json_rpc_error_without_rate_limit_text_raises_unavailable
    stub_rpc.to_return(rpc_error("Invalid params: invalid pubkey"))

    error = assert_raises(Solrengine::Sdp::Faucet::Unavailable) { faucet.request_airdrop(ADDRESS, LAMPORTS) }
    assert_match(/invalid pubkey/i, error.message)
  end

  def test_http_500_raises_unavailable
    stub_rpc.to_return(status: 500, body: "oops")

    assert_raises(Solrengine::Sdp::Faucet::Unavailable) { faucet.request_airdrop(ADDRESS, LAMPORTS) }
  end

  def test_2xx_body_without_result_or_error_raises_unavailable
    stub_rpc.to_return(status: 200, body: { jsonrpc: "2.0", id: 1 }.to_json)

    assert_raises(Solrengine::Sdp::Faucet::Unavailable) { faucet.request_airdrop(ADDRESS, LAMPORTS) }
  end

  def test_read_timeout_raises_timed_out_after_exactly_one_attempt
    # A faucet POST is never retried — the airdrop may still land.
    stub = stub_rpc.to_raise(Net::ReadTimeout)

    assert_raises(Solrengine::Sdp::Faucet::TimedOut) { faucet.request_airdrop(ADDRESS, LAMPORTS) }
    assert_requested(stub, times: 1)
  end

  def test_connect_timeout_raises_unavailable
    # The airdrop was never requested — a funding fallback is safe.
    stub = stub_rpc.to_timeout

    assert_raises(Solrengine::Sdp::Faucet::Unavailable) { faucet.request_airdrop(ADDRESS, LAMPORTS) }
    assert_requested(stub, times: 1)
  end

  def test_connection_refused_raises_unavailable_after_exactly_one_attempt
    stub = stub_rpc.to_raise(Errno::ECONNREFUSED)

    assert_raises(Solrengine::Sdp::Faucet::Unavailable) { faucet.request_airdrop(ADDRESS, LAMPORTS) }
    assert_requested(stub, times: 1)
  end

  def test_rpc_url_comes_from_solana_rpc_url_env
    with_env("SOLANA_RPC_URL" => "https://custom.devnet.test") do
      assert_equal "https://custom.devnet.test", Solrengine::Sdp::Faucet.new.rpc_url
    end
  end

  def test_rpc_url_defaults_to_the_public_devnet_endpoint
    with_env("SOLANA_RPC_URL" => nil) do
      assert_equal Solrengine::Sdp::Faucet::DEFAULT_RPC_URL, Solrengine::Sdp::Faucet.new.rpc_url
    end
  end

  def test_error_taxonomy_descends_from_the_engine_error
    assert_operator Solrengine::Sdp::Faucet::Error, :<, Solrengine::Sdp::Error
    assert_operator Solrengine::Sdp::Faucet::RateLimited, :<, Solrengine::Sdp::Faucet::Error
    assert_operator Solrengine::Sdp::Faucet::Unavailable, :<, Solrengine::Sdp::Faucet::Error
    assert_operator Solrengine::Sdp::Faucet::TimedOut, :<, Solrengine::Sdp::Faucet::Error
  end

  private

  def faucet
    Solrengine::Sdp::Faucet.new(rpc_url: RPC_URL)
  end

  def stub_rpc
    stub_request(:post, RPC_URL)
  end

  def rpc_result(signature)
    {
      status: 200,
      headers: { "Content-Type" => "application/json" },
      body: { jsonrpc: "2.0", result: signature, id: 1 }.to_json
    }
  end

  def rpc_error(message, code: -32602)
    {
      status: 200,
      headers: { "Content-Type" => "application/json" },
      body: { jsonrpc: "2.0", error: { code: code, message: message }, id: 1 }.to_json
    }
  end
end
