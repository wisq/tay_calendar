import Config
alias TayCalendar.Secrets

case System.fetch_env("TZDATA_DATA_DIR") do
  {:ok, path} -> config :tzdata, :data_dir, path
  :error -> :noop
end
