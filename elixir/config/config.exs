import Config

config :phoenix, :json_library, Jason

config :cognition, CognitionWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: CognitionWeb.ErrorHTML, json: CognitionWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Cognition.PubSub,
  live_view: [signing_salt: "cognition-live-view"],
  secret_key_base: String.duplicate("s", 64),
  check_origin: false,
  server: false
