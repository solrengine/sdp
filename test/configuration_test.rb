# frozen_string_literal: true

require_relative "test_helper"

class ConfigurationTest < Minitest::Test
  include EnvHelper

  def setup
    Solrengine::Sdp.reset_configuration!
  end

  def teardown
    Solrengine::Sdp.reset_configuration!
    super # webmock/minitest resets stubs + request history in Minitest::Test#teardown
  end

  # --- ENV fallbacks -------------------------------------------------------

  def test_api_key_and_base_url_resolve_from_env
    with_env("SDP_API_KEY" => "env-key", "SDP_API_BASE_URL" => "http://sdp.example:9999") do
      config = Solrengine::Sdp::Configuration.new

      assert_equal "env-key", config.api_key
      assert_equal "http://sdp.example:9999", config.base_url
    end
  end

  def test_base_url_defaults_to_local_sdp_stack
    with_env("SDP_API_BASE_URL" => nil) do
      assert_equal "http://127.0.0.1:8787", Solrengine::Sdp::Configuration.new.base_url
    end
  end

  def test_custody_provider_resolves_from_env_and_nil_is_ok
    with_env("SDP_CUSTODY_PROVIDER" => nil) do
      assert_nil Solrengine::Sdp::Configuration.new.custody_provider
    end

    with_env("SDP_CUSTODY_PROVIDER" => "privy") do
      assert_equal "privy", Solrengine::Sdp::Configuration.new.custody_provider
    end
  end

  def test_explicit_configure_wins_over_env
    with_env("SDP_API_KEY" => "env-key", "SDP_API_BASE_URL" => "http://env.example") do
      config = Solrengine::Sdp.configure do |c|
        c.api_key = "explicit-key"
        c.base_url = "http://explicit.example"
      end

      assert_equal "explicit-key", config.api_key
      assert_equal "http://explicit.example", config.base_url
    end
  end

  # --- defaults ------------------------------------------------------------

  def test_defaults
    config = Solrengine::Sdp::Configuration.new

    assert_equal "User", config.user_class
    assert_equal 15 * 60, config.expired_transfer_deadline
    assert_equal 2, config.broadcast_retry_delay
    assert_equal 3, config.broadcast_retries
  end

  def test_label_namespace_defaults_to_app_without_rails_application
    # The generator tests load railties, so the Rails constant may exist —
    # but the suite never boots an application, which is what the default is
    # keyed on.
    assert_nil Rails.application if defined?(Rails) && Rails.respond_to?(:application)
    assert_equal "app", Solrengine::Sdp::Configuration.new.label_namespace
  end

  def test_label_namespace_explicit_value_wins
    config = Solrengine::Sdp::Configuration.new
    config.label_namespace = "neobank"

    assert_equal "neobank", config.label_namespace
  end

  # --- user_model ----------------------------------------------------------

  def test_user_model_constantizes_default_user
    assert_equal User, Solrengine::Sdp::Configuration.new.user_model
  end

  def test_user_model_constantizes_lazily
    config = Solrengine::Sdp::Configuration.new
    config.user_class = "LateDefinedUser" # not defined yet — must not raise here

    assert_raises(NameError) { config.user_model }

    Object.const_set(:LateDefinedUser, Class.new)

    assert_equal LateDefinedUser, config.user_model
  ensure
    Object.send(:remove_const, :LateDefinedUser) if Object.const_defined?(:LateDefinedUser)
  end

  # --- validate! -----------------------------------------------------------

  def test_validate_raises_on_blank_api_key_with_actionable_message
    with_env("SDP_API_KEY" => nil) do
      config = Solrengine::Sdp::Configuration.new

      error = assert_raises(Solrengine::Sdp::ConfigurationError) { config.validate! }

      assert_includes error.message, "SDP_API_KEY"
      assert_includes error.message, "Solrengine::Sdp.configure"
      assert_includes error.message, "SDP_API_BASE_URL"
    end
  end

  def test_validate_raises_on_whitespace_only_api_key
    config = Solrengine::Sdp::Configuration.new
    config.api_key = "   "

    assert_raises(Solrengine::Sdp::ConfigurationError) { config.validate! }
  end

  def test_validate_returns_self_when_api_key_present
    config = Solrengine::Sdp::Configuration.new
    config.api_key = "key"

    assert_same config, config.validate!
  end

  # --- client memoization ---------------------------------------------------

  def test_client_is_memoized_and_resets_on_reconfigure
    Solrengine::Sdp.configure { |c| c.api_key = "key-one" }
    first = Solrengine::Sdp.client

    assert_same first, Solrengine::Sdp.client

    Solrengine::Sdp.configure { |c| c.api_key = "key-two" }
    second = Solrengine::Sdp.client

    refute_same first, second
  end

  def test_client_raises_actionable_error_when_unconfigured
    with_env("SDP_API_KEY" => nil) do
      assert_raises(Solrengine::Sdp::ConfigurationError) { Solrengine::Sdp.client }
    end
  end

  # --- exempt-task detection -------------------------------------------------

  def test_exempt_context_detects_infrastructure_tasks
    assert Solrengine::Sdp.exempt_context?([ "assets:precompile" ])
    assert Solrengine::Sdp.exempt_context?([ "db:migrate" ])
    assert Solrengine::Sdp.exempt_context?([ "app:template" ])
    assert Solrengine::Sdp.exempt_context?([ "server", "assets:precompile" ])
  end

  def test_exempt_context_rejects_regular_contexts
    refute Solrengine::Sdp.exempt_context?([ "server" ])
    refute Solrengine::Sdp.exempt_context?([ "solrengine:custom" ])
    refute Solrengine::Sdp.exempt_context?([])
  end

  # --- optional tokens price source ------------------------------------------

  def test_price_source_available_when_tokens_gem_present
    # solrengine-tokens is path-sourced in the Gemfile for exactly this test.
    assert Solrengine::Sdp.price_source_available?
  end

  def test_price_for_returns_nil_when_jupiter_call_fails
    sol_mint = "So11111111111111111111111111111111111111112"
    stub_request(:get, %r{https://api\.jup\.ag/price/v3}).to_return(status: 500)

    assert_nil Solrengine::Sdp.price_for(sol_mint)
  end
end
