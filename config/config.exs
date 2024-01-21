import Config

config :tay_calendar,
  event_defaults: %{
    before: "5m + travel",
    after: "10m"
  },
  off_peak_charger: %{
    enabled: true,
    profile_name: "Home",
    minimum_charge_off_peak: 80,
    minimum_charge_on_peak: 30,
    off_peak_hours: [
      weekdays: {~T[19:00:00], ~T[07:00:00]},
      weekends: :all_day
    ],
    timezone: "America/Toronto"
  }

import_config "#{Mix.env()}.exs"
