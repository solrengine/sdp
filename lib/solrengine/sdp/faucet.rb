# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module Solrengine
  module Sdp
    # DEVNET-ONLY faucet client: POSTs JSON-RPC requestAirdrop straight to a
    # Solana devnet RPC for a wallet's public key. Mainnet has no faucet —
    # pointing this at a mainnet RPC just yields Unavailable errors. Picking
    # a devnet/localnet RPC URL is the caller's responsibility (the default
    # is the public devnet endpoint).
    #
    # One attempt, NEVER retried — an airdrop that timed out may still land,
    # and retrying just burns the per-address faucet allowance. Callers decide
    # what to do on failure (e.g. fall back to a treasury transfer).
    class Faucet
      DEFAULT_RPC_URL = "https://api.devnet.solana.com"
      OPEN_TIMEOUT = 2 # seconds — fail fast, funding flows are user-facing
      READ_TIMEOUT = 5 # seconds

      # The faucet reports rate limiting either as HTTP 429 or as a JSON-RPC
      # error whose message mentions the airdrop/rate limit.
      RATE_LIMIT_PATTERN = /rate.?limit|too many requests|airdrop limit|limit reached|429/i

      class Error < Solrengine::Sdp::Error; end

      # HTTP 429, or a JSON-RPC error that reads like a rate limit. The caller
      # should cool down before asking again.
      class RateLimited < Error; end

      # Connection failure, non-2xx status, or an unusable/erroneous RPC
      # response — the airdrop definitely did not happen. The faucet may work
      # again shortly; use a fallback now.
      class Unavailable < Error; end

      # The request was sent but no response arrived in time. The airdrop MAY
      # still land — the outcome is unknown, so callers must NOT treat this as
      # failure and must not double-fund through a fallback.
      class TimedOut < Error; end

      attr_reader :rpc_url

      def initialize(rpc_url: ENV.fetch("SOLANA_RPC_URL", DEFAULT_RPC_URL),
                     open_timeout: OPEN_TIMEOUT,
                     read_timeout: READ_TIMEOUT)
        @rpc_url = rpc_url
        @open_timeout = open_timeout
        @read_timeout = read_timeout
      end

      # Requests `lamports` for `address`. Returns the airdrop transaction
      # signature on success; raises RateLimited, TimedOut, or Unavailable
      # otherwise.
      def request_airdrop(address, lamports)
        uri = URI.parse(@rpc_url)
        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(
          jsonrpc: "2.0", id: 1, method: "requestAirdrop", params: [ address, lamports ]
        )

        response = Net::HTTP.start(
          uri.host, uri.port,
          use_ssl: uri.scheme == "https",
          open_timeout: @open_timeout,
          read_timeout: @read_timeout
        ) { |http| http.request(request) }

        handle(response)
      rescue Net::OpenTimeout => e
        # Connection never opened — the airdrop request was definitely not
        # sent. Unavailable (not TimedOut) so a funding fallback may run
        # without any double-funding risk.
        raise Unavailable, "Faucet unreachable (connect timeout): #{e.message}"
      rescue Net::ReadTimeout => e
        raise TimedOut, "Faucet timed out: #{e.message}"
      rescue Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH, SocketError, EOFError => e
        raise Unavailable, "Faucet unreachable: #{e.message}"
      end

      private

      def handle(response)
        status = response.code.to_i
        raise RateLimited, "Faucet rate limited (HTTP 429)" if status == 429
        raise Unavailable, "Faucet returned HTTP #{status}" unless (200..299).cover?(status)

        body = parse_json(response.body)
        raise Unavailable, "Faucet returned an unreadable response" unless body.is_a?(Hash)

        if (error = body["error"])
          message = error.is_a?(Hash) ? error["message"].to_s : error.to_s
          raise RateLimited, "Faucet rate limited: #{message}" if message.match?(RATE_LIMIT_PATTERN)

          raise Unavailable, "Faucet error: #{message.empty? ? 'unknown' : message}"
        end

        signature = body["result"]
        raise Unavailable, "Faucet response carried no signature" if signature.to_s.empty?

        signature
      end

      def parse_json(raw)
        return nil if raw.nil? || raw.empty?

        JSON.parse(raw)
      rescue JSON::ParserError
        nil
      end
    end
  end
end
