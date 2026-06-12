# frozen_string_literal: true

module Solrengine
  module Sdp
    # Engine-level errors. Transport/API errors raised while talking to SDP
    # live in the solana-sdp client gem (Sdp::Error and subclasses); these
    # are the errors the ENGINE itself raises.
    class Error < StandardError; end

    # Raised at boot/configure time when the engine cannot operate
    # (see Configuration#validate!).
    class ConfigurationError < Error; end

    # Raised by Transfer.execute! when the balance preflight shows the source
    # wallet cannot cover amount + fee buffer. Raised BEFORE any row is
    # created and before any POST is made — there is nothing to reconcile,
    # the app just renders the message and lets the user adjust the amount.
    class InsufficientBalance < Error; end
  end
end
