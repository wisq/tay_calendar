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
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
      {:goth, "~> 1.3"},
      {:req, "~> 0.4.0"},
      {:timex, "~> 3.7.11"},
      {:nimble_parsec, "~> 1.4.0"},
      {:porsche_conn_ex, github: "wisq/porsche_conn_ex", tag: "e9342825"},
      {:dogstatsd, "~> 0.0.4"}
    ]
  end
end
