import Config

config :tay_calendar,
  event_defaults: %{
    before: "5m + travel",
    after: "25m"
  }

import_config "#{Mix.env()}.exs"
