defmodule TayCalendar.MixProject do
  use Mix.Project

  def project do
    [
      app: :tay_calendar,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {TayCalendar, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # branch: finch-deprecation (v1.4.2 + commit 972bf98)
      #   Fixes :protocol deprecation warning.
      {:goth, github: "wisq/goth", tag: "fe34b72"},
      {:req, "~> 0.4.0"},
      {:timex, "~> 3.7.11"},
      {:nimble_parsec, "~> 1.4.0"},
      {:porsche_conn_ex, github: "wisq/porsche_conn_ex", tag: "e514264"},
      {:dogstatsd, "~> 0.0.4"},
      {:google_maps, "~> 0.11"}
    ]
  end
end
