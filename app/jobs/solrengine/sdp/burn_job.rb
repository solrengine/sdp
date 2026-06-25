# frozen_string_literal: true

module Solrengine
  module Sdp
    # Sends a single burn to SDP, off the web request. The burn POST is NEVER
    # retried; the atomic claim (burning → in_flight) guarantees a burn is
    # never sent twice. Counterpart to MintJob — see it for the full rationale.
    class BurnJob < ActiveJob::Base
      queue_as :default

      discard_on ActiveJob::DeserializationError

      def perform(burn)
        return unless burn.claim! # false → already attempted; never re-send

        burn.submit_to_sdp!
      end
    end
  end
end
