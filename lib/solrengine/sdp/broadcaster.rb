# frozen_string_literal: true

module Solrengine
  module Sdp
    # Turns a chain-change signal ("this wallet's account changed") into the
    # app's configured broadcasts — or into silence. The WebSocket
    # notification is only a doorbell: it carries no data. The broadcaster
    # re-fetches everything displayed from the authoritative source (SDP) and
    # broadcasts only when every fetch succeeded, so screens never regress
    # from good content to an "unavailable" state mid-session; the last good
    # content simply stays.
    #
    # The app supplies broadcast targets — via Solrengine::Sdp.configure or
    # the targets: argument — as an ordered array of hashes:
    #
    #   config.broadcast_targets = [
    #     { name: :activity,
    #       fetch:  ->(user) { ActivityFeed.entries_for(user) },
    #       render: ->(user, entries) {
    #         Turbo::StreamsChannel.broadcast_update_to(
    #           user.realtime_stream, target: "activity",
    #           partial: "activity/feed", locals: { entries: entries })
    #       } },
    #     { name: :balance, fetch: ..., render: ... }
    #   ]
    #
    # The ENGINE owns the doorbell invariants; the lambdas own the app
    # specifics:
    #
    #   * All-or-nothing: every target's fetch runs first, in configured
    #     order. Any fetch raising — or returning :unavailable — means NO
    #     renders at all this attempt (nil is valid data; signal "I could not
    #     fetch" with :unavailable or an exception).
    #   * Consumed doorbells retry: a WebSocket notification never re-fires,
    #     so a transient SDP hiccup would otherwise permanently miss the
    #     update. The WHOLE cycle (fetch + render) retries up to
    #     configuration.broadcast_retries attempts, sleeping
    #     broadcast_retry_delay seconds between attempts (zero it in tests).
    #     Safe to sleep: solrengine-realtime invokes subscribers on a
    #     dedicated per-wallet broadcast thread.
    #   * Priority order: renders run in the configured array order — put
    #     fast, money-bearing regions first, decorative ones last.
    #   * Request-context-free: lambdas run in a watcher process, outside any
    #     HTTP request. Current.user, session, and request-thread locals are
    #     nil; partials need explicit locals.
    #
    # USD enrichment inside fetch lambdas: Solrengine::Sdp.usd_value_for(balance)
    # — SDP's usd_value when present, Jupiter-derived when solrengine-tokens
    # is available, nil otherwise. Price failures never fail a fetch.
    #
    # Turbo deliberately never appears in this class: render lambdas do the
    # actual broadcasting, so the engine core carries no turbo-rails
    # dependency and the invariants are testable without it.
    class Broadcaster
      TARGET_KEYS = %i[name fetch render].freeze

      def self.call(wallet_address, targets: nil)
        new(wallet_address, targets: targets).call
      end

      def initialize(wallet_address, targets: nil)
        @wallet_address = wallet_address
        @targets = validate_targets(targets || configuration.broadcast_targets)
      end

      # Resolves the wallet owner and runs the broadcast cycle. Unknown or
      # not-yet-ready wallets (the fee payer, external counterparties) are a
      # silent no-op — not ours to broadcast. Returns true when a cycle
      # completed, false when retries were exhausted, nil on no-op.
      def call
        if @targets.empty?
          logger&.info(
            "[Solrengine::Sdp::Broadcaster] No broadcast_targets configured — nothing to broadcast. " \
            "Set config.broadcast_targets in a Solrengine::Sdp.configure block to enable realtime updates."
          )
          return
        end

        # This executes on a long-lived per-wallet broadcast thread
        # (solrengine-realtime), NOT inside an HTTP request. Rails only
        # auto-releases AR connections at request boundaries, so a bare
        # find_by here permanently holds a connection on the thread.  With
        # a default pool of 5 that means the sixth wallet's broadcast
        # raises ConnectionTimeoutError — rescued by the realtime registry
        # and silently dropped. with_connection returns the lease to the
        # pool as soon as the block exits, before the fetch/render/sleep
        # cycle starts. App-provided fetch lambdas may also touch the DB;
        # that is the app's concern and is intentionally out of this scope.
        user = ActiveRecord::Base.connection_pool.with_connection do
          configuration.user_model.wallet_ready.find_by(wallet_address: @wallet_address)
        end
        return unless user

        attempts = configuration.broadcast_retries
        attempts.times do |attempt|
          return true if attempt_broadcast(user)

          sleep configuration.broadcast_retry_delay unless attempt == attempts - 1
        end

        logger&.warn(
          "[Solrengine::Sdp::Broadcaster] Giving up on #{@wallet_address}: " \
          "SDP unavailable — keeping last good content"
        )
        false
      end

      private

      # One fetch-and-broadcast attempt. True when every fetch succeeded and
      # every render ran; false on any failure so the caller can retry.
      # Never renders partial data. A render raising also fails the attempt —
      # the whole cycle re-runs, which is safe because renders re-broadcast
      # the same regions with fresh data.
      def attempt_broadcast(user)
        data = fetch_all(user)
        return false unless data

        @targets.each { |target| target[:render].call(user, data[target[:name]]) }
        true
      rescue StandardError => e
        logger&.warn(
          "[Solrengine::Sdp::Broadcaster] Attempt for #{@wallet_address} failed: #{e.class}: #{e.message}"
        )
        false
      end

      # Runs every fetch in configured order. Returns the data keyed by
      # target name, or nil as soon as any fetch returns :unavailable.
      def fetch_all(user)
        @targets.each_with_object({}) do |target, data|
          value = target[:fetch].call(user)
          return nil if value == :unavailable

          data[target[:name]] = value
        end
      end

      # Misconfigured targets are a programming error, not a transient
      # failure — fail loudly at construction, outside the retry loop.
      def validate_targets(targets)
        targets = Array(targets)
        targets.each do |target|
          unless target.respond_to?(:[]) && target[:name] &&
                 target[:fetch].respond_to?(:call) && target[:render].respond_to?(:call)
            raise ConfigurationError,
              "Each broadcast target needs #{TARGET_KEYS.map(&:inspect).join(', ')} " \
              "with callable fetch/render, got: #{target.inspect}"
          end
        end
        targets
      end

      def configuration
        Solrengine::Sdp.configuration
      end

      def logger
        configuration.logger
      end
    end
  end
end
