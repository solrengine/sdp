# frozen_string_literal: true

module Solrengine
  module Sdp
    VERSION = "0.1.0"

    # The SDP release this engine version is tested against. SDP breaks its
    # API between minors; bump this (and re-verify) on every SDP upgrade.
    COMPATIBLE_SDP_VERSION = "0.28"
  end
end
