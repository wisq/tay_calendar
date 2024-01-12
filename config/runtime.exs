import Config
alias TayCalendar.Secrets

if config_env() in [:dev, :prod] do
  config :google_maps, api_key: Secrets.fetch!("GOOGLE_MAPS_API_KEY")
end

case System.fetch_env("TZDATA_DATA_DIR") do
  {:ok, path} -> config :tzdata, :data_dir, path
  :error -> :noop
end
