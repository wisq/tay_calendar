import Config

config :tay_calendar,
  event_defaults: %{
    before: "5m + travel",
    after: "15m"
  }

import_config "#{Mix.env()}.exs"
