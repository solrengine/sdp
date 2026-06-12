# frozen_string_literal: true

module Solrengine
  module Sdp
    class Engine < ::Rails::Engine
      isolate_namespace Solrengine::Sdp

      # A missing API key must fail loudly at boot, not at the first wallet
      # call. Exemptions:
      #   - test env: suites stub HTTP and configure explicitly
      #   - infrastructure rake tasks (assets:, db:, app:, ...): CI and
      #     Docker image builds run these without production secrets
      config.after_initialize do
        next if Rails.env.test?
        next if Solrengine::Sdp.exempt_rake_context?

        Solrengine::Sdp.configuration.validate!
      end
    end
  end
end
