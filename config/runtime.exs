import Config
alias TayCalendar.Secrets

if config_env() in [:dev, :prod] do
  config :google_maps, api_key: Secrets.fetch!("GOOGLE_MAPS_API_KEY")
end
