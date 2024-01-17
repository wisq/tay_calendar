import Config

config :logger, :console, format: "$metadata[$level] $message\n"
config :logger, level: :info
